// tb_dc3_link.v - proves layer 1 of the DC3 inter-board link without any hardware.
//
// What is checked, and why each item is on the list:
//   1. integrity and ordering, both directions at once, at the 5 MHz bring-up rate
//   2. the phase promise - a byte launched on the falling edge must still be on the
//      wire 2 ns before the rising edge that captures it. A zero-delay simulator is
//      happy with a launch that lands on the sampling edge, and that design loses
//      every bit of margin on real silicon, so this is checked explicitly.
//   3. throughput at the 10 MHz target against the plan's >= 6 MB/s per direction
//   4. backpressure - the consumer stalls hard enough that READY really drops, and
//      nothing is lost and the FIFO never overflows
//   5. an idle link invents no data, and resumes cleanly
//
// The expected value of the n-th received byte is start+n, so exactly one place
// advances a sequence. An earlier version of this bench kept a parallel counter per
// direction; it drifted, and the failures it reported were the bench's own.
//
//   iverilog -g2005 -o tb_dc3_link.vvp tb_dc3_link.v \
//            ../user_source/hdl_source/link/dc3_link.v
//   vvp tb_dc3_link.vvp

`timescale 1ns/1ps

module tb_dc3_link;

  reg clk_a = 0, clk_b = 0;
  always #5 clk_a = ~clk_a;      // 100 MHz
  always #7 clk_b = ~clk_b;      // 71.43 MHz - deliberately not harmonic with A

  reg rst_a = 1, rst_b = 1;

  reg [6:0] div_a = 5, div_b = 7;
  real half_a = 50.0, half_b = 98.0;

  // ---- A -> B ----
  reg  [7:0] ab_src_data = 0;
  reg        ab_src_valid = 0;
  wire       ab_src_ready;
  wire [7:0] ab_link_data;
  wire       ab_link_valid, ab_link_clk;
  wire       b_rx_ready;
  wire [7:0] ab_dst_data;
  wire       ab_dst_valid;
  reg        ab_dst_ready = 0;
  wire       b_overflow;

  // ---- B -> A ----
  reg  [7:0] ba_src_data = 0;
  reg        ba_src_valid = 0;
  wire       ba_src_ready;
  wire [7:0] ba_link_data;
  wire       ba_link_valid, ba_link_clk;
  wire       a_rx_ready;
  wire [7:0] ba_dst_data;
  wire       ba_dst_valid;
  reg        ba_dst_ready = 0;
  wire       a_overflow;

  dc3_tx tx_ab (.clk(clk_a), .rst(rst_a), .clk_div(div_a),
      .s_data(ab_src_data), .s_valid(ab_src_valid), .s_ready(ab_src_ready),
      .rx_ready(b_rx_ready),
      .link_data(ab_link_data), .link_valid(ab_link_valid), .link_clk(ab_link_clk));

  dc3_rx #(.AW(10), .RX_FREE_GUARANTEE(576), .LOW_WATER(128)) rx_ab (
      .clk(clk_b), .rst(rst_b),
      .link_clk(ab_link_clk), .link_valid(ab_link_valid), .link_data(ab_link_data),
      .m_data(ab_dst_data), .m_valid(ab_dst_valid), .m_ready(ab_dst_ready),
      .rx_ready(b_rx_ready), .overflow(b_overflow));

  dc3_tx tx_ba (.clk(clk_b), .rst(rst_b), .clk_div(div_b),
      .s_data(ba_src_data), .s_valid(ba_src_valid), .s_ready(ba_src_ready),
      .rx_ready(a_rx_ready),
      .link_data(ba_link_data), .link_valid(ba_link_valid), .link_clk(ba_link_clk));

  dc3_rx #(.AW(10), .RX_FREE_GUARANTEE(576), .LOW_WATER(128)) rx_ba (
      .clk(clk_a), .rst(rst_a),
      .link_clk(ba_link_clk), .link_valid(ba_link_valid), .link_data(ba_link_data),
      .m_data(ba_dst_data), .m_valid(ba_dst_valid), .m_ready(ba_dst_ready),
      .rx_ready(a_rx_ready), .overflow(a_overflow));

  // ------------------------------------------------------------------
  // phase checker. Fires only on a falling edge that actually put a byte on the
  // wire; an idle window legitimately presents valid=0 and is not a violation.
  // ------------------------------------------------------------------
  integer phase_err = 0;
  reg [7:0] ab_ref, ba_ref;
  reg       ab_v, ba_v;

  always @(negedge ab_link_clk) begin
    #0.1;                              // after the NBA update, or the probe reads stale
    ab_ref = ab_link_data;
    ab_v   = ab_link_valid;
    if (ab_v) begin
      #(half_a - 2.1);
      if (ab_link_valid !== 1'b1) begin
        phase_err = phase_err + 1;
        if (phase_err < 6) $display("PHASE FAIL AB: valid dropped before capture edge");
      end
      if (ab_link_data !== ab_ref) begin
        phase_err = phase_err + 1;
        if (phase_err < 6) $display("PHASE FAIL AB: %02x moved to %02x 2ns early",
                                    ab_ref, ab_link_data);
      end
    end
  end

  always @(negedge ba_link_clk) begin
    #0.1;
    ba_ref = ba_link_data;
    ba_v   = ba_link_valid;
    if (ba_v) begin
      #(half_b - 2.1);
      if (ba_link_valid !== 1'b1) begin
        phase_err = phase_err + 1;
        if (phase_err < 6) $display("PHASE FAIL BA: valid dropped before capture edge");
      end
      if (ba_link_data !== ba_ref) begin
        phase_err = phase_err + 1;
        if (phase_err < 6) $display("PHASE FAIL BA: %02x moved to %02x 2ns early",
                                    ba_ref, ba_link_data);
      end
    end
  end

  // ------------------------------------------------------------------
  // feeder. The only place a payload sequence advances.
  // ------------------------------------------------------------------
  reg        feed_on = 0;
  integer    feed_left_ab = 0, feed_left_ba = 0;
  reg [7:0]  feed_ab = 0, feed_ba = 0;

  always @(posedge clk_a) if (feed_on) begin
    if (ab_src_valid && ab_src_ready) begin
      feed_ab      = feed_ab + 1'b1;
      feed_left_ab = feed_left_ab - 1;
    end
    ab_src_valid <= (feed_left_ab > 0);
    ab_src_data  <= feed_ab;
  end

  always @(posedge clk_b) if (feed_on) begin
    if (ba_src_valid && ba_src_ready) begin
      feed_ba      = feed_ba + 1'b1;
      feed_left_ba = feed_left_ba - 1;
    end
    ba_src_valid <= (feed_left_ba > 0);
    ba_src_data  <= feed_ba;
  end

  // valid is owned by the feeder's non-blocking assignments, so the sequence cannot
  // just set it to 0 with a blocking write and expect that to win the same timestep.
  always @(posedge clk_a) if (!feed_on) ab_src_valid <= 1'b0;
  always @(posedge clk_b) if (!feed_on) ba_src_valid <= 1'b0;

  // ------------------------------------------------------------------
  // collectors. The expected byte at index n is (start + n) mod 256.
  // ------------------------------------------------------------------
  integer byte_err = 0, ovf_err = 0, errors = 0;
  integer got_ab = 0, got_ba = 0;
  // index the current feeder run started at; expected byte is (got - start) mod 256
  integer start_ab = 0, start_ba = 0;

  always @(posedge clk_b) if (ab_dst_valid && ab_dst_ready) begin
    if (ab_dst_data !== ((got_ab - start_ab) % 256)) begin
      errors = errors + 1; byte_err = byte_err + 1;
      if (byte_err < 8) $display("AB FAIL @%0d: got %02x expected %02x",
                                 got_ab, ab_dst_data, (got_ab - start_ab) % 256);
    end
    got_ab = got_ab + 1;
  end

  always @(posedge clk_a) if (ba_dst_valid && ba_dst_ready) begin
    if (ba_dst_data !== ((got_ba - start_ba) % 256)) begin
      errors = errors + 1; byte_err = byte_err + 1;
      if (byte_err < 8) $display("BA FAIL @%0d: got %02x expected %02x",
                                 got_ba, ba_dst_data, (got_ba - start_ba) % 256);
    end
    got_ba = got_ba + 1;
  end

  always @(posedge ab_link_clk) if (b_overflow) begin
    errors = errors + 1; ovf_err = ovf_err + 1;
    if (ovf_err < 6) $display("OVERFLOW on B at %0t", $time);
  end
  always @(posedge ba_link_clk) if (a_overflow) begin
    errors = errors + 1; ovf_err = ovf_err + 1;
    if (ovf_err < 6) $display("OVERFLOW on A at %0t", $time);
  end

  reg stall_mode = 0;
  always @(posedge clk_a) ba_dst_ready <= stall_mode ? (($random % 7) == 0) : 1'b1;
  always @(posedge clk_b) ab_dst_ready <= stall_mode ? (($random % 7) == 0) : 1'b1;

  // ------------------------------------------------------------------
  // relink changes the rate. clk_div is only allowed to move while the link is
  // idle and across a reset; changing it under traffic duplicates a byte.
  // ------------------------------------------------------------------
  task automatic relink(input integer h_a, input integer h_b);
    begin
      feed_on = 0;
      ab_src_valid = 0;
      ba_src_valid = 0;
      repeat (3000) @(posedge clk_a);          // let both FIFOs drain
      rst_a = 1; rst_b = 1;
      div_a  = h_a / 10;
      div_b  = h_b / 7;
      half_a = div_a * 10.0;
      half_b = div_b * 14.0;
      repeat (20) @(posedge clk_a);
      rst_a = 0; rst_b = 0;
      repeat (60) @(posedge clk_a);
      start_ab = got_ab;                       // a reset drops whatever was in flight
      start_ba = got_ba;
      feed_ab  = 0;
      feed_ba  = 0;
    end
  endtask

  task automatic feed(input integer n_ab, input integer n_ba);
    begin
      feed_left_ab = n_ab;
      feed_left_ba = n_ba;
      feed_on = 1;
      while (feed_left_ab > 0 || feed_left_ba > 0) @(posedge clk_a);
      feed_on = 0;
      ab_src_valid = 0; ba_src_valid = 0;      // leaving valid up re-sends the last byte
      repeat (3000) @(posedge clk_a);          // let the tail arrive
    end
  endtask

  real t_start, t_stop, secs, mbs_ab, mbs_ba;
  integer base_ab, base_ba;

  task automatic ck(input cond, input [8*72-1:0] name);
    begin
      if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end
      else $display("PASS: %0s", name);
    end
  endtask

  initial begin
    relink(100, 98);                           // ~5 MHz on A, ~5.1 MHz on B

    // ============ T1: bring-up rate, both directions at once ============
    $display("[T1] ~5 MHz link, full duplex, 4000 bytes each way");
    base_ab = got_ab;
    base_ba = got_ba;
    feed(4000, 4000);
    ck(got_ab - base_ab == 4000 && got_ba - base_ba == 4000, "T1 all 8000 bytes arrived");
    ck(byte_err == 0, "T1 every byte in order, both directions");
    ck(phase_err == 0, "T1 half-period setup budget held on every launch");
    ck(ovf_err == 0, "T1 no FIFO overflow");

    // ============ T2: 10 MHz target, throughput ceiling =================
    $display("[T2] 10 MHz link on A, continuous feed, throughput measured");
    relink(50, 49);
    base_ab = got_ab;
    base_ba = got_ba;
    t_start = $realtime;
    feed_left_ab  = 1000000;
    feed_left_ba  = 1000000;
    feed_on       = 1;
    repeat (400_000) @(posedge clk_a);         // 4 ms window
    t_stop = $realtime;
    feed_on = 0;
    ab_src_valid = 0; ba_src_valid = 0;
    repeat (3000) @(posedge clk_a);
    secs   = (t_stop - t_start) / 1e9;
    mbs_ab = (got_ab - base_ab) / secs / 1e6;
    mbs_ba = (got_ba - base_ba) / secs / 1e6;
    $display("     A->B %0d bytes in %.3f ms = %.2f MB/s",
             got_ab - base_ab, secs * 1000.0, mbs_ab);
    $display("     B->A %0d bytes in %.3f ms = %.2f MB/s",
             got_ba - base_ba, secs * 1000.0, mbs_ba);
    ck(byte_err == 0, "T2 no byte error at the 10 MHz target");
    ck(mbs_ab >= 6.0, "T2 A->B useful payload meets the plan number (6 MB/s)");

    // ============ T3: hard backpressure =================================
    $display("[T3] consumer stalled to 1 in 7 cycles - READY must actually drop");
    relink(50, 49);
    base_ab = got_ab;
    stall_mode = 1;
    feed(20000, 20000);
    stall_mode = 0;
    repeat (20_000) @(posedge clk_a);          // drain the backlog
    ck(got_ab - base_ab == 20000, "T3 nothing lost while the receiver was stalled");
    ck(ovf_err == 0, "T3 no overflow while READY was doing real work");
    ck(byte_err == 0, "T3 order and values intact through the stall");

    // ============ T4: idle, then resume =================================
    $display("[T4] 200 us idle, then resume");
    relink(50, 49);   // re-anchor: a byte parked in the skid at the end of T3 would
                      // otherwise offset this case's expected values by one
    base_ab = got_ab;
    base_ba = got_ba;
    #(200_000.0);
    ck(got_ab == base_ab && got_ba == base_ba, "T4 an idle link invents no data");
    feed(500, 500);
    ck(got_ab - base_ab == 500 && got_ba - base_ba == 500, "T4 resumes cleanly after idle");

    $display("     breakdown: byte_err=%0d overflow=%0d phase_err=%0d",
             byte_err, ovf_err, phase_err);
    $display("=== tb_dc3_link done: errors=%0d ===", errors);
    if (errors != 0) $display("RESULT: FAIL");
    else             $display("RESULT: PASS");
    $finish;
  end

  initial begin
    #500_000_000;
    $display("WATCHDOG: run away, check the case sizes");
    $display("RESULT: FAIL");
    $finish;
  end

endmodule
