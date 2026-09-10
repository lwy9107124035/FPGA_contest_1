`timescale 1ns/1ps
// TB v10 (WP-K work copy, derived from tools/tests/tb_msgink_v91.v — REPO FILE UNTOUCHED).
// Keeps EVERY v9.1 case (full regression: PLY decimal, hex path, INFO?, STAT?,
// msgcnt 000..255 + wrap, bin2bcd exhaustive, case-insensitive, COL, invalid).
// Adds v10 coverage:
//   * VID <0-32>: VID 0(exit OK) / VID 3 / VID 09 / VID 32 / VID 10 OK -> code8;
//     VID 33 / VID 032(len7) / VID 128(len7) -> ERR (no fire); lowercase "vid 5".
//   * SCAN32 -> code7 (delayed arm, needs s5='2').
//   * WHY? black-box query frame-shape (kind 3'd4): "W <2hex> <2hex> <2hex> <ddd>"
//     with drive-through stall_* inputs; query class = no msgcnt change, no fire.
// NOTE (iverilog): \r is not a Verilog-2005 string escape ("\r" parses as 'r'),
//   expected frames are plain bodies + CR/LF appended by expect_ack itself.
module tb;
    reg clk = 0, rst_n = 0, de = 0;
    always #20 clk = ~clk;
    reg [7:0] b = 0; wire [7:0] rx = b;
    reg rx_vld = 0;
    wire msg_we; wire [4:0] msg_wslot; wire [15:0] msg_wcode; wire msg_commit;
    wire tx_start; wire [7:0] tx_byte;
    reg tx_done = 1;
    wire emg_mode; wire [1:0] emg_sel; wire [3:0] vol_lvl;
    wire next_pulse, auto_pulse, ls_tgl;
    wire prev_pulse;                       // v10.2
    reg  [5:0] lc_r = 6'd0, ld_r = 6'd0;   // v10.2: LIST? 输入驱动
    reg  [4:0] li_r = 5'd0;
    wire prm_tgl; wire [3:0] prm_code, prm_a; wire [7:0] prm_b;
    wire [2:0] txt_col;
    reg  [7:0] dbg_r = 8'h00;          // v9.1: drive dbg so INFO? bits are visible
    // v10: drive the black-box stall inputs so WHY? reply is observable
    reg  [7:0] stall_now_r = 8'h00, stall_h1_r = 8'h00, stall_h2_r = 8'h00, stall_cnt_r = 8'h00;
    // v9: payload capture — prove raw case survives into the glyph RAM writes
    reg [15:0] cap [0:21]; integer capn = 0;
    integer capfire = 0;               // commit counter (MSG engine ran?)
    always @(posedge clk) if (msg_we && rst_n) begin cap[capn] = msg_wcode; capn = capn + 1; end
    always @(posedge clk) if (msg_commit && rst_n) begin
        $display("MSG-CAP n=%0d first=%h %h %h %h %h %h %h", capn,
                 cap[0], cap[1], cap[2], cap[3], cap[4], cap[5], cap[6]);
        capn = 0; capfire = capfire + 1;
    end

    msg_ink dut(.clk(clk), .rst_n(rst_n), .rx_byte(rx), .rx_vld(rx_vld), .de(de),
        .msg_we(msg_we), .msg_wslot(msg_wslot), .msg_wcode(msg_wcode), .msg_commit(msg_commit),
        .tx_start(tx_start), .tx_byte(tx_byte), .tx_done(tx_done),
        .emg_mode(emg_mode), .emg_sel(emg_sel), .vol_lvl(vol_lvl),
        .next_pulse(next_pulse), .auto_pulse(auto_pulse), .prev_pulse(prev_pulse),
        .list_cnt(lc_r), .list_depth(ld_r), .list_cur(li_r), .ls_tgl(ls_tgl), .dbg(dbg_r),
        .prm_tgl(prm_tgl), .prm_code(prm_code), .prm_a(prm_a), .prm_b(prm_b),
        .stall_now(stall_now_r), .stall_h1(stall_h1_r), .stall_h2(stall_h2_r), .stall_cnt(stall_cnt_r),
        .txt_col(txt_col));

    // v10.2: pulse activity monitors (1-cycle strobes)
    integer prev_seen = 0, next_seen = 0, prev_base = 0, next_base = 0;
    always @(posedge clk) if (prev_pulse && rst_n) prev_seen = prev_seen + 1;
    always @(posedge clk) if (next_pulse && rst_n) next_seen = next_seen + 1;

    // ---- ACK capture: reassemble tx byte stream into complete lines --------
    reg [7:0] aline [0:31]; integer alen = 0;
    reg [8*20-1:0] ack_vec;  integer ack_vlen = 0;
    reg [8*20-1:0] ack_disp; integer ack_ready = 0;
    integer k;
    always @(posedge clk) if (tx_start && rst_n) begin
        if (tx_byte == 8'h0A) begin
            ack_vec = 160'd0; ack_disp = 160'd0;
            for (k = 0; k < alen; k = k + 1) begin
                ack_vec [(alen-k)*8 +: 8]   = aline[k];
                ack_disp[(alen-k)*8 +: 8]   = aline[k];
            end
            ack_vec[7:0] = 8'h0A;  ack_disp[7:0] = 8'h0A;   // include the LF
            ack_vlen = alen + 1; alen = 0; ack_ready = 1;
        end else begin
            aline[alen] = tx_byte; alen = alen + 1;
        end
    end

    // persistent PRM event monitor — ANY change (toggle, not pulse!)
    integer fire_n = 0, exp_firen = 0;
    reg [3:0] fire_code, fire_a; reg [7:0] fire_b;
    always @(prm_tgl) begin
        #1; // let NBA on prm_* settle
        fire_code = prm_code; fire_a = prm_a; fire_b = prm_b; fire_n = fire_n + 1;
        $display("PRM-FIRE t=%0t code=%0d a=%0d b=%02h", $time, fire_code, fire_a, fire_b);
    end

    // ---- assertion plumbing -------------------------------------------------
    integer checks = 0, fails = 0;
    task pass(input [8*40-1:0] name);
        begin checks = checks + 1; $display("PASS %0s", name); end
    endtask
    task fail(input [8*40-1:0] name);
        begin checks = checks + 1; fails = fails + 1;
              $display("FAIL %0s", name); end
    endtask

    // body = line text WITHOUT the trailing CRLF; n = total bytes incl CRLF
    task expect_ack(input [8*20-1:0] body, input integer n, input [8*40-1:0] name);
        reg [8*20-1:0] expf;
        begin
            expf = (body << 16) | {8'h0D, 8'h0A};
            if (!ack_ready) begin
                $display("FAIL %0s  (no ack line received)", name);
                checks = checks + 1; fails = fails + 1;
            end else if (ack_vlen == n && ack_vec === expf) pass(name);
            else begin
                $display("FAIL %0s  exp<%0s> got<%0s> len=%0d", name, expf, ack_vec, ack_vlen);
                checks = checks + 1; fails = fails + 1;
            end
        end
    endtask

    task expect_fire(input integer code, input integer a, input integer hb,
                     input [8*40-1:0] name);
        begin
            if (fire_n != exp_firen + 1) begin
                $display("FAIL %0s  (expected exactly one PRM-FIRE, delta=%0d)",
                         name, fire_n - exp_firen);
                checks = checks + 1; fails = fails + 1;
            end
            else if (fire_code == code[3:0] && fire_a == a[3:0] && fire_b == hb[7:0])
                pass(name);
            else begin
                $display("FAIL %0s  exp code=%0d a=%0d b=%02h, got code=%0d a=%0d b=%02h",
                         name, code, a, hb, fire_code, fire_a, fire_b);
                checks = checks + 1; fails = fails + 1;
            end
            exp_firen = fire_n;                    // consume the observed fire
        end
    endtask
    task expect_nofire(input [8*40-1:0] name);
        begin
            if (fire_n == exp_firen) pass(name);
            else begin
                $display("FAIL %0s  (unexpected PRM-FIRE, delta=%0d)", name, fire_n-exp_firen);
                checks = checks + 1; fails = fails + 1;
                exp_firen = fire_n;
            end
        end
    endtask

    // ---- stimulus tasks (same byte timing as tb_msgink_v7) ------------------
    task sendb(input [7:0] v);
        begin b = v; @(posedge clk); rx_vld <= 1'b1; @(posedge clk); rx_vld <= 1'b0;
              repeat (40) @(posedge clk); end
    endtask
    integer w;
    task sendstr(input [8*24-1:0] s, input integer n);
        integer j; begin
            ack_ready = 0; alen = 0;
            for (j = 0; j < n; j = j + 1) sendb(s[(n-1-j)*8 +: 8]);
        end
    endtask
    task run_cmd(input [8*24-1:0] s, input integer n);
        begin
            exp_firen = fire_n;
            sendstr(s, n);
            w = 0;
            while (!ack_ready && w < 300) begin @(posedge clk); w = w + 1; end
        end
    endtask
    task quiet(input [8*24-1:0] s, input integer n);   // fire without checking
        begin sendstr(s, n); end
    endtask
    task show_ack(input [8*40-1:0] label);
        integer j; reg [7:0] bb; begin
            $write("%0s: ", label);
            for (j = 0; j < ack_vlen; j = j + 1) begin
                bb = ack_disp[(ack_vlen-1-j)*8 +: 8];
                if (bb == 8'h0D) $write("<CR>");
                else if (bb == 8'h0A) $write("<LF>");
                else $write("%c", bb);
            end
            $write("\n");
        end
    endtask

    integer i;
    initial begin
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1;
        de = 0;

        $display("========== OLD SEGMENT (v7 TB, expectations kept) ==========");
        run_cmd("SPD 3\n", 6);      expect_ack("OK", 4, "o01 SPD 3 -> OK");
                                   expect_fire(1, 0, 8'h03, "o01 SPD 3 -> code1 a0 b03");
        run_cmd("T 2 5\n", 6);      expect_ack("OK", 4, "o02 T 2 5 -> OK");
                                   expect_fire(2, 2, 8'h05, "o02 T 2 5 -> code2 a2 b05");
        run_cmd("PLY 05\n", 7);     expect_ack("OK", 4, "o03 PLY 05 -> OK");
                                   expect_fire(3, 0, 8'h05, "o03 PLY 05 -> b05 (dec5, value unchanged)");
        run_cmd("PLY 44\n", 7);     expect_ack("OK", 4, "o04 PLY 44 -> OK");
                                   expect_fire(3, 0, 8'h2c, "o04 PLY 44 -> b2c (BEHAVIOR CHANGE dec44)");
        run_cmd("PLYALL\n", 7);     expect_ack("OK", 4, "o05 PLYALL -> OK");
                                   expect_fire(4, 0, 8'h00, "o05 PLYALL -> code4");
        run_cmd("SCAN4\n", 6);      expect_ack("OK", 4, "o06 SCAN4 -> OK");
                                   expect_fire(5, 0, 8'h04, "o06 SCAN4 -> code5 (b携数字)");
        run_cmd("SCAN7\n", 6);      expect_ack("OK", 4, "o07 SCAN7 -> OK");
                                   expect_fire(6, 0, 8'h07, "o07 SCAN7 -> code6 (b携数字)");
        run_cmd("SCAN5\n", 6);      expect_ack("OK", 4, "n01 SCAN5 -> OK");
                                   expect_fire(9, 0, 8'h05, "n01 SCAN5 -> code9 b=05");
        run_cmd("SCAN12\n", 7);     expect_ack("OK", 4, "n02 SCAN12 -> OK");
                                   expect_fire(9, 0, 8'h0C, "n02 SCAN12 -> code9 b=12");
        run_cmd("SCAN31\n", 7);     expect_ack("OK", 4, "n03 SCAN31 -> OK");
                                   expect_fire(9, 0, 8'h1F, "n03 SCAN31 -> code9 b=31");
        run_cmd("SCAN33\n", 7);     expect_ack("ERR", 5, "n04 SCAN33 -> ERR (超 32)"); expect_nofire("n04 no fire");
        run_cmd("SCAN39\n", 7);     expect_ack("ERR", 5, "n05 SCAN39 -> ERR (超 32)"); expect_nofire("n05 no fire");
        run_cmd("RNG58\n", 6);      expect_ack("OK", 4, "n06 RNG58 -> OK");
                                   expect_fire(10, 0, 8'h58, "n06 RNG58 -> code10 b=58");
        run_cmd("RNG04\n", 6);      expect_ack("ERR", 5, "n07 RNG04 -> ERR (零起点)"); expect_nofire("n07 no fire");
        run_cmd("RNG510\n", 7);     expect_ack("ERR", 5, "n08 RNG510 -> ERR (只允许单数字)"); expect_nofire("n08 no fire");
        prev_base = prev_seen; next_base = next_seen;
        run_cmd("PREV\n", 5);       expect_ack("OK", 4, "n09 PREV -> OK");
                                    expect_nofire("n09 PREV no PRM-FIRE");
                                    if (prev_seen == prev_base + 1 && next_seen == next_base)
                                        pass("n09 PREV -> prev_pulse +1, next_pulse 不动");
                                    else begin
                                        $display("  prev %0d->%0d next %0d->%0d",
                                                 prev_base, prev_seen, next_base, next_seen);
                                        fail("n09 PREV -> prev_pulse +1, next_pulse 不动");
                                    end
        lc_r = 6'd32; li_r = 5'd3; ld_r = 6'd10;
        run_cmd("LIST?\n", 6);      expect_ack("L 20 03 0A", 12, "n10 LIST? -> L 20 03 0A");
                                     expect_nofire("n10 LIST? no PRM-FIRE");
        run_cmd("COL 3\n", 6);      expect_ack("OK", 4, "o08 COL 3 -> OK");
                                   expect_nofire("o08 COL 3 no PRM-FIRE");
        if (txt_col === 3'd3) pass("o08 COL 3 -> txt_col=3"); else fail("o08 COL 3 -> txt_col=3");
        run_cmd("COL 7\n", 6);      expect_ack("OK", 4, "o09 COL 7 -> OK");
                                   expect_nofire("o09 COL 7 no PRM-FIRE");
        if (txt_col === 3'd7) pass("o09 COL 7 -> txt_col=7"); else fail("o09 COL 7 -> txt_col=7");

        $display("--- invalid: no PRM-FIRE, ACK ERR ---");
        run_cmd("COL 9\n", 6);      expect_ack("ERR", 5, "o10 COL 9 -> ERR");   expect_nofire("o10 no fire");
        run_cmd("SPD A\n", 6);      expect_ack("ERR", 5, "o11 SPD A -> ERR");   expect_nofire("o11 no fire");
        run_cmd("T 9 1\n", 6);      expect_ack("ERR", 5, "o12 T 9 1 -> ERR");   expect_nofire("o12 no fire");
        run_cmd("PLY 00\n", 7);     expect_ack("ERR", 5, "o13 PLY 00 -> ERR");  expect_nofire("o13 no fire");
        run_cmd("SPD 10\n", 7);     expect_ack("ERR", 5, "o14 SPD 10 -> ERR");  expect_nofire("o14 no fire");
        run_cmd("SCAN0\n", 6);      expect_ack("ERR", 5, "o15 SCAN0 -> ERR (0 仍非法)");   expect_nofire("o15 no fire");
        run_cmd("NEXT\n", 5);       expect_ack("OK", 4, "o16 NEXT -> OK (old cmd alive)");
                                    expect_nofire("o16 NEXT no PRM-FIRE");

        $display("--- v9 case tests ---");
        i = capfire;
        run_cmd("msg hi, Yo!\n", 12);
        expect_ack("OK", 4, "o17 msg lowercase -> OK");
        repeat (80) @(posedge clk);
        if (capfire == i + 1) begin
            if (cap[0]===16'h0068 && cap[1]===16'h0069 && cap[2]===16'h002c &&
                cap[3]===16'h0020 && cap[4]===16'h0059 && cap[5]===16'h006f &&
                cap[6]===16'h0021) pass("o17 MSG-CAP raw case h i , sp Y o !");
            else fail("o17 MSG-CAP raw case h i , sp Y o !");
        end else fail("o17 MSG engine did not commit");
        run_cmd("spd 6\n", 6);       expect_ack("OK", 4, "o18 spd 6 -> OK");
                                     expect_fire(1, 0, 8'h06, "o18 spd 6 -> code1 b06");
        run_cmd("col 0\n", 6);       expect_ack("OK", 4, "o19 col 0 -> OK");
        if (txt_col === 3'd0) pass("o19 col 0 -> txt_col=0"); else fail("o19 col 0 -> txt_col=0");
        run_cmd("ply 7f\n", 7);      expect_ack("OK", 4, "o20 ply 7f -> OK (lowercase HEX kept)");
                                     expect_fire(3, 0, 8'h7f, "o20 ply 7f -> b7f hex path");
        run_cmd("NeXt\n", 5);        expect_ack("OK", 4, "o21 NeXt -> OK");
                                     expect_nofire("o21 NeXt no PRM-FIRE");
        i = capfire;
        run_cmd("msgg hi\n", 8);     expect_ack("ERR", 5, "o22 msgg hi -> ERR near-miss");
        if (capfire == i) pass("o22 msgg hi no MSG-CAP"); else fail("o22 msgg hi no MSG-CAP");

        $display("========== NEW SEGMENT (v9.1) ==========");
        run_cmd("PLY 3\n", 6);       expect_ack("OK", 4, "n01 PLY 3 -> OK");
                                     expect_fire(3, 0, 8'h07, "n01 PLY 3 -> first-3 mask b07");
        run_cmd("PLY 12\n", 7);      expect_ack("OK", 4, "n02 PLY 12 -> OK");
                                     expect_fire(3, 0, 8'h0c, "n02 PLY 12 -> dec12 b0c");
        run_cmd("PLY 0f\n", 7);      expect_ack("OK", 4, "n03 PLY 0f -> OK");
                                     expect_fire(3, 0, 8'h0f, "n03 PLY 0f -> hex b0f kept");
        run_cmd("PLY 7F\n", 7);      expect_ack("OK", 4, "n04 PLY 7F -> OK");
                                     expect_fire(3, 0, 8'h7f, "n04 PLY 7F -> hex b7f kept");
        run_cmd("PLY 0\n", 6);       expect_ack("ERR", 5, "n05 PLY 0 -> ERR");
                                     expect_nofire("n05 PLY 0 no PRM-FIRE");
        run_cmd("PLY 99\n", 7);      expect_ack("OK", 4, "n06 PLY 99 -> OK");
                                     expect_fire(3, 0, 8'h63, "n06 PLY 99 -> dec99 b63");
        run_cmd("PLY 100\n", 8);     expect_ack("ERR", 5, "n07 PLY 100 -> ERR (len7)");
                                     expect_nofire("n07 PLY 100 no PRM-FIRE");

        // ---- INFO?: fresh DUT, walk msgcnt to exactly 3 ---------------------
        $display("--- INFO? with msgcnt=3 ---");
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1;   // msgcnt back to 0
        repeat (4) @(posedge clk);
        dbg_r = 8'h00;
        run_cmd("COL 3\n", 6);       expect_ack("OK", 4, "n08 warm-up COL 3 -> OK");
        run_cmd("COL 4\n", 6);       expect_ack("OK", 4, "n09 warm-up COL 4 -> OK");
        run_cmd("NEXT\n", 5);        expect_ack("OK", 4, "n10 warm-up NEXT -> OK (msgcnt=3)");
        run_cmd("INFO?\n", 6);
        show_ack("INFO-GOT");
        expect_ack("V2 003 00000000", 17, "n11 INFO? -> 17B frame V2 003 00000000");
        dbg_r = 8'b1011_0011;
        run_cmd("INFO?\n", 6);
        show_ack("INFO-GOT");
        expect_ack("V2 003 10110011", 17, "n12 INFO? dbg=B3 -> V2 003 10110011");
        run_cmd("info?\n", 6);
        show_ack("INFO-GOT");
        expect_ack("V2 003 10110011", 17, "n13 info? lowercase same reply");
        run_cmd("STAT?\n", 6);       expect_ack("V2 03 B3", 10, "n14 STAT? still hex V2 03 B3");
        run_cmd("NEXT\n", 5);        expect_ack("OK", 4, "n15 NEXT -> msgcnt=4");
        run_cmd("INFO?\n", 6);
        show_ack("INFO-GOT");
        expect_ack("V2 004 10110011", 17, "n16 INFO? follows count -> V2 004");

        // ---- msgcnt decimal extremes: 255 and the 256->000 wrap -------------
        $display("--- walk msgcnt 4 -> 255 -> 0 (wrap) ---");
        for (i = 0; i < 251; i = i + 1) quiet("NEXT\n", 5);   // 4 + 251 = 255
        run_cmd("INFO?\n", 6);
        show_ack("INFO-GOT");
        expect_ack("V2 255 10110011", 17, "n17 INFO? cnt=255 -> V2 255");
        run_cmd("NEXT\n", 5);        expect_ack("OK", 4, "n18 NEXT wraps msgcnt to 0");
        run_cmd("INFO?\n", 6);
        show_ack("INFO-GOT");
        expect_ack("V2 000 10110011", 17, "n19 INFO? cnt=000 (256 wrap) -> V2 000");
        run_cmd("STAT?\n", 6);       expect_ack("V2 00 B3", 10, "n20 STAT? hex path intact at 00");

        // ---- exhaustive bin2bcd model check (hierarchical, sim-only) -------
        begin : b2b_selftest
            integer vv, bd_fail; reg [11:0] bcdv; reg [3:0] d0, d1, d2;
            bd_fail = 0;
            for (vv = 0; vv < 256; vv = vv + 1) begin
                bcdv = dut.bin2bcd(vv[7:0]);
                d0 = vv % 10; d1 = (vv / 10) % 10; d2 = (vv / 100) % 10;
                if (bcdv !== {d2, d1, d0}) begin
                    if (bd_fail < 5) $display("  B2B FAIL %0d -> %h exp %h", vv, bcdv, {d2,d1,d0});
                    bd_fail = bd_fail + 1;
                end
            end
            if (bd_fail == 0) pass("n21 bin2bcd exhaustive 0..255 (256/256)");
            else begin fail("n21 bin2bcd exhaustive 0..255");
                   $display("  %0d/256 mismatches", bd_fail); end
        end

        $display("========== NEW SEGMENT (v10: VID / SCAN32 / WHY?) ==========");
        // ---- VID 0..32 acceptance + boundaries ----
        run_cmd("VID 0\n", 6);       expect_ack("OK", 4, "v01 VID 0 -> OK (exit legal)");
                                     expect_fire(8, 0, 8'h00, "v01 VID 0 -> code8 b00");
        run_cmd("VID 3\n", 6);       expect_ack("OK", 4, "v02 VID 3 -> OK");
                                     expect_fire(8, 0, 8'h03, "v02 VID 3 -> code8 b03");
        run_cmd("VID 10\n", 7);      expect_ack("OK", 4, "v03 VID 10 -> OK");
                                     expect_fire(8, 0, 8'h0a, "v03 VID 10 -> code8 b0a");
        run_cmd("VID 09\n", 7);      expect_ack("OK", 4, "v04 VID 09 -> OK (leading zero)");
                                     expect_fire(8, 0, 8'h09, "v04 VID 09 -> code8 b09");
        run_cmd("VID 31\n", 7);      expect_ack("OK", 4, "v05 VID 31 -> OK");
                                     expect_fire(8, 0, 8'h1f, "v05 VID 31 -> code8 b1f");
        run_cmd("VID 32\n", 7);      expect_ack("OK", 4, "v06 VID 32 -> OK (max)");
                                     expect_fire(8, 0, 8'h20, "v06 VID 32 -> code8 b20");
        run_cmd("vid 5\n", 6);       expect_ack("OK", 4, "v07 vid 5 -> OK (lowercase)");
                                     expect_fire(8, 0, 8'h05, "v07 vid 5 -> code8 b05");
        // ---- VID over-range / bad-length -> ERR, no fire ----
        run_cmd("VID 33\n", 7);      expect_ack("ERR", 5, "v08 VID 33 -> ERR (>32)");
                                     expect_nofire("v08 no fire");
        run_cmd("VID 99\n", 7);      expect_ack("ERR", 5, "v09 VID 99 -> ERR (>32)");
                                     expect_nofire("v09 no fire");
        run_cmd("VID 032\n", 8);     expect_ack("ERR", 5, "v10 VID 032 -> ERR (len7)");
                                     expect_nofire("v10 no fire");
        run_cmd("VID 128\n", 8);     expect_ack("ERR", 5, "v11 VID 128 -> ERR (len7, >32)");
                                     expect_nofire("v11 no fire");
        run_cmd("VID A\n", 6);       expect_ack("ERR", 5, "v12 VID A -> ERR (non-digit)");
                                     expect_nofire("v12 no fire");

        // ---- SCAN32 (delayed arm, needs s5='2') ----
        run_cmd("SCAN32\n", 7);      expect_ack("OK", 4, "v13 SCAN32 -> OK");
                                     expect_fire(7, 0, 8'h00, "v13 SCAN32 -> code7");
        run_cmd("scan32\n", 7);      expect_ack("OK", 4, "v14 scan32 lowercase -> OK");
                                     expect_fire(7, 0, 8'h00, "v14 scan32 -> code7");

        // ---- WHY? black-box frame shape (kind 3'd4) ----
        //   "W <2hex now> <2hex h1> <2hex h2> <ddd cnt>\r\n" = 16 bytes.
        //   Query class: msgcnt unchanged, NO PRM-FIRE.
        stall_now_r = 8'hA1; stall_h1_r = 8'h02; stall_h2_r = 8'hF0; stall_cnt_r = 8'd7;
        run_cmd("WHY?\n", 5);
        show_ack("WHY-GOT");
        expect_ack("W A1 02 F0 007", 16, "v15 WHY? -> W A1 02 F0 007");
        expect_nofire("v15 WHY? no PRM-FIRE");
        stall_now_r = 8'h00; stall_h1_r = 8'h1B; stall_h2_r = 8'h2C; stall_cnt_r = 8'd255;
        run_cmd("WHY?\n", 5);
        show_ack("WHY-GOT");
        expect_ack("W 00 1B 2C 255", 16, "v16 WHY? -> W 00 1B 2C 255 (cnt saturate)");
        stall_now_r = 8'hFF; stall_h1_r = 8'h0D; stall_h2_r = 8'h0E; stall_cnt_r = 8'd0;
        run_cmd("why?\n", 5);   // lowercase: u-shadow uppercases W,H,Y
        show_ack("WHY-GOT");
        expect_ack("W FF 0D 0E 000", 16, "v17 why? lowercase -> same frame");
        // WHY? must NOT change msgcnt (query class): confirm STAT? hex path
        run_cmd("VID 4\n", 6);       expect_ack("OK", 4, "v18 VID 4 -> OK");
        run_cmd("WHY?\n", 5);        expect_nofire("v19 WHY? still query, no fire after count cmd");

        $display("=== SUMMARY: %0d checks, %0d FAIL ===", checks, fails);
        $display("=== TB V10 END ===");
        $finish;
    end
endmodule
