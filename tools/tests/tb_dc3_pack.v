// tb_dc3_pack.v - layers 1 and 2 together: packets through the real byte pipe.
//
// What this is meant to catch, in order of how much it would have cost on the bench:
//   P1 a packet's fields and payload survive framing
//   P2 a single flipped bit on the wire is DETECTED (not delivered), and the next packet
//      still gets through - a CRC that rejects but cannot re-sync is as bad as no CRC
//   P3 a packet from a previous session is dropped as stale, and the same packet is
//      accepted once the expected session moves to it - which proves the rule is the
//      session byte and not something stuck
//   P4 sustained framed throughput with back-to-back 512-byte blocks
//   P5 one whole 640x480 RGB888 frame, so the plan's "0.154 s per image" bandwidth line
//      becomes a measured number instead of an estimate
//
//   iverilog -g2005 -o tb_dc3_pack.vvp tb_dc3_pack.v \
//     ../../user_source/hdl_source/link/dc3_pack.v ../../user_source/hdl_source/link/dc3_link.v
//   vvp tb_dc3_pack.vvp

`timescale 1ns/1ps

module tb_dc3_pack;

  localparam integer HDRB   = 9;
  localparam integer MAXPAY = 512;

  reg clk_a = 0, clk_b = 0;
  always #5 clk_a = ~clk_a;
  always #7 clk_b = ~clk_b;
  reg rst_a = 1, rst_b = 1;

  reg [6:0] div_a = 5;                      // 10 MHz link out of A's 100 MHz
  reg [7:0] session = 8'h2A;

  // ---- A -> B, layer 1 ----
  // a_src_* is driven by the packetiser, so it is a wire here
  wire [7:0] a_src_data;
  wire       a_src_valid;
  wire       a_src_ready;
  wire [7:0] a_link_data_raw;
  wire       a_link_valid, a_link_clk;
  wire       b_rx_ready;

  // error injection: flip bits on the wire for exactly one byte
  reg  [7:0] inj_mask = 8'h00;
  reg        inj_arm  = 0;
  reg        inj_done = 0;
  integer    inj_ctr  = 0;
  localparam integer INJ_AT = 12;              // inside the payload of a 512-byte block
  // The old form flipped the first falling edge after arming, which was an IDLE byte
  // outside any packet: the corruption never reached a byte the CRC covered, and the
  // "rejected by CRC" assertion could not have failed for the wrong reason.
  wire [7:0] a_link_data = a_link_data_raw ^
                           ((inj_arm && inj_ctr == INJ_AT) ? inj_mask : 8'h00);
  always @(negedge a_link_clk) begin
    if (inj_arm && a_link_valid) begin
      if (inj_ctr == INJ_AT) inj_done <= 1'b1;
      inj_ctr = inj_ctr + 1;
    end
  end

  wire [7:0] b_src_data;
  wire       b_src_valid;
  reg        b_src_ready = 1;
  wire       b_overflow;

  dc3_tx tx_a (.clk(clk_a), .rst(rst_a), .clk_div(div_a),
      .s_data(a_src_data), .s_valid(a_src_valid), .s_ready(a_src_ready),
      .rx_ready(b_rx_ready),
      .link_data(a_link_data_raw), .link_valid(a_link_valid), .link_clk(a_link_clk));

  dc3_rx #(.AW(10), .RX_FREE_GUARANTEE(576), .LOW_WATER(128)) rx_a (
      .clk(clk_b), .rst(rst_b),
      .link_clk(a_link_clk), .link_valid(a_link_valid), .link_data(a_link_data),
      .m_data(b_src_data), .m_valid(b_src_valid), .m_ready(b_src_ready),
      .rx_ready(b_rx_ready), .overflow(b_overflow));

  // ---- layer 2 on the far end ----
  wire [7:0]  pm_data;
  wire        pm_valid;
  reg         pm_ready = 1;
  wire [7:0]  pm_type, pm_task;
  wire [15:0] pm_seq, pm_len;
  wire        pm_sof, pm_eof;
  wire [2:0]  pm_err;
  wire [15:0] cnt_ok, cnt_crc, cnt_stale, cnt_resync;

  dc3_pkt_rx pkt_rx (
      .clk(clk_b), .rst(rst_b),
      .s_data(b_src_data), .s_valid(b_src_valid),
      .m_data(pm_data), .m_valid(pm_valid), .m_ready(pm_ready),
      .m_type(pm_type), .m_task(pm_task), .m_seq(pm_seq), .m_len(pm_len),
      .m_sof(pm_sof), .m_eof(pm_eof), .m_err(pm_err),
      .expect_session(session),
      .cnt_ok(cnt_ok), .cnt_crc(cnt_crc), .cnt_stale(cnt_stale), .cnt_resync(cnt_resync));

  // ---- layer 2 near end, driving layer 1 ----
  reg        p_start = 0;
  reg  [7:0] p_type = 0, p_session = 0, p_task = 0;
  reg  [15:0] p_seq = 0, p_len = 0;
  reg  [7:0] p_data = 0;
  reg        p_valid = 0;
  wire       p_ready;
  wire [7:0] err_short;

  dc3_pkt_tx pkt_tx (
      .clk(clk_a), .rst(rst_a),
      .p_start(p_start), .p_type(p_type), .p_session(p_session), .p_task(p_task),
      .p_seq(p_seq), .p_len(p_len), .p_data(p_data), .p_valid(p_valid), .p_ready(p_ready),
      .s_data(a_src_data), .s_valid(a_src_valid), .s_ready(a_src_ready),
      .err_short(err_short));

`ifdef TRACE
  // one line per receiver state change, plus the byte that caused it
  reg [2:0] rx_prev = 3'd0;
  reg [3:0] h_prev  = 4'd0;
  always @(posedge clk_b) begin
    if (pkt_rx.state !== rx_prev) begin
      $display("[%0t] RX state %0d -> %0d  (hidx=%0d pidx=%0d len=%0d s_valid=%b)",
               $time, rx_prev, pkt_rx.state, pkt_rx.hidx, pkt_rx.pidx, pkt_rx.len_r,
               b_src_valid);
      rx_prev <= pkt_rx.state;
    end
    if (pkt_rx.hidx !== h_prev && pkt_rx.state === 3'd1)
      $display("        hdr[%0d] = %02x", h_prev, pkt_rx.hdr[h_prev]);
    h_prev <= pkt_rx.hidx;
  end
  integer rxbytes = 0;
  always @(posedge clk_b) if (b_src_valid) begin
    $display("[%0t] RX sees byte %02d of hdr/payload: %02x  (rx state=%0d hidx=%0d)",
             $time, rxbytes, b_src_data, pkt_rx.state, pkt_rx.hidx);
    rxbytes = rxbytes + 1;
    if (rxbytes > 26) $finish;
  end
`endif

  // ------------------------------------------------------------------
  // consumer: stage a block, commit it only when the CRC said so
  // ------------------------------------------------------------------
  reg [7:0] stage [0:MAXPAY-1];
  reg [7:0] got   [0:MAXPAY-1];
  integer   sidx = 0;
  integer   committed = 0, committed_len = 0;
  reg [7:0] committed_type, committed_task;
  reg [15:0] committed_seq;
  integer   rejected = 0;

  // m_sof pulses one cycle AFTER the first payload byte has already been taken, so
  // gating capture on it drops byte zero and shifts the whole block - which is what
  // this bench's first "payload mismatch" actually was, a bench bug not an RTL bug.
  // Capture on the stream itself and reset the index at end-of-packet instead.
  always @(posedge clk_b) begin
    if (pm_valid && pm_ready) begin
      stage[sidx] <= pm_data;
      sidx        <= sidx + 1;
    end
    if (pm_eof) begin
      if (pm_err === 3'd0) begin
        committed      <= committed + 1;
        committed_len  <= sidx;
        committed_type <= pm_type;
        committed_task <= pm_task;
        committed_seq  <= pm_seq;
      end else begin
        rejected <= rejected + 1;
      end
      sidx <= 0;
    end
  end

  integer errors = 0;
  task automatic ck(input cond, input [8*72-1:0] name);
    begin
      if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end
      else $display("PASS: %0s", name);
    end
  endtask

  // ------------------------------------------------------------------
  // send one packet; payload byte i is (task + seq + i) mod 256
  // ------------------------------------------------------------------
  task automatic send_pkt(input [7:0] ty, input [7:0] se, input [7:0] tk,
                          input [15:0] sq, input [15:0] ln);
    integer i;
    begin
      @(negedge clk_a);
      p_type = ty; p_session = se; p_task = tk; p_seq = sq; p_len = ln;
      p_start = 1;
      @(negedge clk_a);
      p_start = 0;
      for (i = 0; i < ln; i = i + 1) begin
        p_data  = (tk + sq[7:0] + i) & 8'hFF;
        p_valid = 1'b1;
        @(negedge clk_a);
        while (p_ready !== 1'b1) @(negedge clk_a);
        // p_ready high at this negedge means the byte is taken at the POSEDGE that
        // follows it. Leaving the loop does not advance time, so without this step the
        // next iteration overwrites p_data in the same delta and byte zero of every
        // packet silently never goes out (the tail then repeats one byte).
        @(negedge clk_a);
      end
      @(negedge clk_a);
      p_valid = 1'b0;
      // wait for the packetiser to return to idle before the next one
      @(negedge clk_a);
    end
  endtask

  // wait until the receiver has committed n packets, or give up loudly. A fixed
  // drain window is how a bench either wastes an hour of sim or reports a false
  // failure because the transfer was still in flight.
  // Waits on `committed`, the consumer's own view. Waiting on the receiver's cnt_ok
  // returned on the same clock edge that raised m_eof, so the assertions read
  // `committed` one NBA late and saw a packet that had not been committed yet -
  // a bench race that looked like an RTL defect.
  task automatic wait_for_ok(input integer n);
    integer guard;
    begin
      guard = 0;
      while ((committed < n) && (guard < 300_000)) begin
        @(posedge clk_b);
        guard = guard + 1;
      end
      repeat (20) @(posedge clk_b);            // let the consumer's own registers land
      if (committed < n) begin
        errors = errors + 1;
        $display("TIMEOUT waiting for %0d committed packets, have %0d", n, committed);
        $display("   rx state=%0d hidx=%0d pidx=%0d len_r=%0d pay_lost=%b",
                 pkt_rx.state, pkt_rx.hidx, pkt_rx.pidx, pkt_rx.len_r, pkt_rx.pay_lost);
        $display("   tx state=%0d hidx=%0d pidx=%0d len_r=%0d err_short=%0d",
                 pkt_tx.state, pkt_tx.hidx, pkt_tx.pidx, pkt_tx.len_r, err_short);
        $display("   counters ok=%0d crc=%0d stale=%0d resync=%0d",
                 cnt_ok, cnt_crc, cnt_stale, cnt_resync);
        $display("   bytes seen on the link: %0d, fifo overflow events: %0d",
                 seen_link_bytes, b_overflow_cnt);
        $display("   first bytes off the link: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
                 first_link_bytes[0], first_link_bytes[1], first_link_bytes[2],
                 first_link_bytes[3], first_link_bytes[4], first_link_bytes[5],
                 first_link_bytes[6], first_link_bytes[7], first_link_bytes[8],
                 first_link_bytes[9]);
        $display("   hdr[0..8]: %02x %02x %02x %02x %02x %02x %02x %02x %02x",
                 pkt_rx.hdr[0], pkt_rx.hdr[1], pkt_rx.hdr[2], pkt_rx.hdr[3], pkt_rx.hdr[4],
                 pkt_rx.hdr[5], pkt_rx.hdr[6], pkt_rx.hdr[7], pkt_rx.hdr[8]);
      end
    end
  endtask

  integer seen_link_bytes = 0, b_overflow_cnt = 0;
  always @(posedge clk_b) if (b_src_valid && b_src_ready) seen_link_bytes = seen_link_bytes + 1;
  always @(posedge a_link_clk) if (b_overflow) b_overflow_cnt = b_overflow_cnt + 1;

  always @(posedge clk_a) if (pkt_tx.state === 3'd2 && pkt_tx.take &&
                              pkt_tx.len_r == 16'd512 &&
                              (pkt_tx.pidx < 3 || pkt_tx.pidx > 16'd508))
    $display("        TX 512-pkt pidx=%0d takes %02x (p_data=%02x)",
             pkt_tx.pidx, pkt_tx.s_data, p_data);

  reg [7:0] first_link_bytes [0:15];
  integer nfb = 0;
  always @(posedge clk_b) if (nfb < 16 && b_src_valid && b_src_ready) begin
    first_link_bytes[nfb] = b_src_data;
    nfb = nfb + 1;
  end

  integer base_ok, base_crc, base_stale, base_resync;
  real t0, t1, secs;
  integer total_bytes, i, bad;

  initial begin
    repeat (10) @(posedge clk_a);
    rst_a = 0; rst_b = 0;
    repeat (20) @(posedge clk_a);

    // ================= P1: fields and payload survive =================
    $display("[P1] three packets: empty, 5 bytes, 512 bytes");
    send_pkt(8'h11, session, 8'h03, 16'h1234, 16'd0);
    wait_for_ok(1);
    send_pkt(8'h22, session, 8'h05, 16'h0007, 16'd5);
    wait_for_ok(2);
    send_pkt(8'h33, session, 8'h07, 16'hABCD, 16'd512);
    wait_for_ok(3);
    $display("     DIAG committed=%0d rejected=%0d len=%0d task=%02x seq=%04x | rx ok=%0d crc=%0d",
             committed, rejected, committed_len, committed_task, committed_seq, cnt_ok, cnt_crc);
    ck(committed == 3, "P1 all three packets committed by the consumer");
    ck(cnt_ok == 3 && cnt_crc == 0 && cnt_stale == 0, "P1 receiver counters agree");
    ck(committed_task == 8'h07 && committed_seq == 16'hABCD, "P1 task and seq fields round-trip");
    bad = 0;
    for (i = 0; i < 512; i = i + 1)
      if (stage[i] !== ((8'h07 + 8'hCD + i) & 8'hFF)) bad = bad + 1;
    $display("     staged: %02x %02x %02x %02x %02x %02x %02x %02x %02x | expect %02x %02x %02x",
             stage[0],stage[1],stage[2],stage[3],stage[4],stage[5],stage[6],stage[7],stage[8],
             (8'h07+8'hCD+0)&8'hFF,(8'h07+8'hCD+1)&8'hFF,(8'h07+8'hCD+2)&8'hFF);
    ck(bad == 0, "P1 512-byte payload byte-for-byte correct");

    // ================= P2: one flipped bit is caught, then re-sync =====
    $display("[P2] flip one bit on the wire inside a 512-byte packet");
    base_ok = cnt_ok; base_crc = cnt_crc;
    inj_mask = 8'h01; inj_done = 0; inj_arm = 1; inj_ctr = 0;
    send_pkt(8'h33, session, 8'h08, 16'h0001, 16'd512);
    inj_arm = 0;
    #200_000;   // a corrupted packet never commits, so this one is waited on time
    ck(cnt_crc >= base_crc + 1, "P2 the corrupted packet was rejected by CRC");
    ck(inj_done == 1, "P2 the injection actually reached the wire");
    send_pkt(8'h33, session, 8'h09, 16'h0002, 16'd512);
    wait_for_ok(base_ok+1);
    ck(cnt_ok == base_ok + 1, "P2 the packet after the corruption still gets through");
    bad = 0;
    for (i = 0; i < 512; i = i + 1)
      if (stage[i] !== ((8'h09 + 8'h02 + i) & 8'hFF)) bad = bad + 1;
    ck(bad == 0, "P2 post-corruption payload is clean, not merely accepted");

    // ================= P3: stale session ==============================
    $display("[P3] a packet from another session must not take effect");
    base_stale = cnt_stale; base_ok = cnt_ok;
    send_pkt(8'h44, session ^ 8'hFF, 8'h0A, 16'h0003, 16'd16);
    #100_000;   // a stale packet is dropped at the header, so nothing commits
    ck(cnt_stale == base_stale + 1, "P3 wrong-session packet counted as stale");
    ck(cnt_ok == base_ok, "P3 wrong-session packet was not delivered");
    session = session ^ 8'hFF;
    send_pkt(8'h44, session, 8'h0B, 16'h0004, 16'd16);
    wait_for_ok(base_ok+1);
    $display("     P3 DIAG session=%02x base_ok=%0d cnt_ok=%0d cnt_stale=%0d committed=%0d rx_state=%0d",
             session, base_ok, cnt_ok, cnt_stale, committed, pkt_rx.state);
    ck(cnt_ok == base_ok + 1, "P3 same packet accepted once the session moves");

    // ================= P4: sustained framed throughput ================
    $display("[P4] 200 back-to-back 512-byte blocks");
    base_ok = cnt_ok;
    t0 = $realtime;
    for (i = 0; i < 200; i = i + 1)
      send_pkt(8'h55, session, 8'h0C, i[15:0], 16'd512);
    wait_for_ok(base_ok + 200);
    t1 = $realtime;
    secs = (t1 - t0) / 1e9;
    total_bytes = (cnt_ok - base_ok) * 512;
    $display("     %0d payload bytes in %.3f ms = %.2f MB/s useful",
             total_bytes, secs * 1000.0, total_bytes / secs / 1e6);
    ck(cnt_ok - base_ok == 200, "P4 all 200 blocks delivered");
    ck((total_bytes / secs / 1e6) >= 6.0, "P4 framed link still clears 6 MB/s");

    // ================= P5: one whole image frame ======================
    $display("[P5] 640x480 RGB888 = 921600 bytes as 1800 blocks");
    base_ok = cnt_ok;
    base_crc = cnt_crc;   // P2 injected one corruption on purpose; measuring P5 against
                          // a baseline taken before it charged that error to this case
    t0 = $realtime;
    for (i = 0; i < 1800; i = i + 1)
      send_pkt(8'h66, session, 8'h0D, i[15:0], 16'd512);
    wait_for_ok(base_ok + 1800);
    t1 = $realtime;
    secs = (t1 - t0) / 1e9;
    $display("     %.1f ms for the frame, %.2f MB/s useful", secs * 1000.0,
             (cnt_ok - base_ok) * 512 / secs / 1e6);
    $display("     plan estimate for one way was 0.154 s at 6 MB/s");
    ck(cnt_ok - base_ok == 1800, "P5 all 1800 blocks of the frame delivered");
    ck(cnt_crc == base_crc, "P5 zero corruption over 921600 bytes");

    $display("     counters: ok=%0d crc=%0d stale=%0d resync=%0d tx_underrun=%0d",
             cnt_ok, cnt_crc, cnt_stale, cnt_resync, err_short);
    $display("=== tb_dc3_pack done: errors=%0d ===", errors);
    if (errors != 0) $display("RESULT: FAIL");
    else             $display("RESULT: PASS");
    $finish;
  end

  initial begin
    #400_000_000;
    $display("WATCHDOG");
    $display("RESULT: FAIL");
    $finish;
  end

endmodule
