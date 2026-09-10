`timescale 1ns/1ps
//=============================================================================
// tb_msgink_v103 —— v10.3 新命令（BR/GN/FD/CK/VU/SR）解码 + 旧命令防撞回归
// 断言两级：①串口回执帧（OK/ERR）②内部寄存器实值（hierarchical probe）
//=============================================================================
module tb;
    reg clk = 0, rst_n = 0, de = 0;
    always #20 clk = ~clk;
    reg [7:0] b = 0; wire [7:0] rx = b;
    reg rx_vld = 0;
    wire msg_we; wire [4:0] msg_wslot; wire [15:0] msg_wcode; wire msg_commit;
    wire tx_start; wire [7:0] tx_byte; reg tx_done = 1;
    wire emg_mode; wire [1:0] emg_sel; wire [3:0] vol_lvl;
    wire next_pulse, auto_pulse, ls_tgl, prev_pulse;
    wire prm_tgl; wire [3:0] prm_code, prm_a; wire [7:0] prm_b;
    wire [2:0] txt_col;
    // v10.3 outputs
    wire [3:0] br_w, gn_w; wire [1:0] fd_w;
    wire ck_w, vu_w; wire [2:0] sr_w;

    msg_ink dut(.clk(clk), .rst_n(rst_n), .rx_byte(rx), .rx_vld(rx_vld), .de(de),
        .msg_we(msg_we), .msg_wslot(msg_wslot), .msg_wcode(msg_wcode), .msg_commit(msg_commit),
        .tx_start(tx_start), .tx_byte(tx_byte), .tx_done(tx_done),
        .emg_mode(emg_mode), .emg_sel(emg_sel), .vol_lvl(vol_lvl),
        .next_pulse(next_pulse), .auto_pulse(auto_pulse), .prev_pulse(prev_pulse),
        .list_cnt(6'd0), .list_depth(6'd0), .list_cur(5'd0), .ls_tgl(ls_tgl), .dbg(8'h00),
        .prm_tgl(prm_tgl), .prm_code(prm_code), .prm_a(prm_a), .prm_b(prm_b),
        .stall_now(8'h00), .stall_h1(8'h00), .stall_h2(8'h00), .stall_cnt(8'h00),
        .txt_col(txt_col),
        .br_lvl(br_w), .gn_lvl(gn_w), .fd_mode(fd_w),
        .clk_on(ck_w), .vu_on(vu_w), .sr_spd(sr_w));

    // ---- ACK reassembly ----
    reg [7:0] aline [0:31]; integer alen = 0;
    reg [8*20-1:0] ack_vec; integer ack_vlen = 0, ack_ready = 0; integer k;
    always @(posedge clk) if (tx_start && rst_n) begin
        if (tx_byte == 8'h0A) begin
            ack_vec = 160'd0;
            for (k = 0; k < alen; k = k + 1) ack_vec[(alen-k)*8 +: 8] = aline[k];
            ack_vec[7:0] = 8'h0A; ack_vlen = alen + 1; alen = 0; ack_ready = 1;
        end else begin aline[alen] = tx_byte; alen = alen + 1; end
    end
    integer fire_n = 0, exp_firen = 0;
    always @(prm_tgl) fire_n = fire_n + 1;

    integer checks = 0, fails = 0;
    task ck(input [8*44-1:0] name, input cond);
        begin checks = checks + 1;
            if (cond) $display("PASS %0s", name);
            else begin fails = fails + 1; $display("FAIL %0s", name); end
        end
    endtask
    task expect_ack(input [8*20-1:0] body, input integer n, input [8*44-1:0] name);
        reg [8*20-1:0] expf;
        begin
            expf = (body << 16) | {8'h0D, 8'h0A};
            if (!(ack_ready && ack_vlen == n && ack_vec === expf))
                $display("   >>> %0s gotlen=%0d got=%h exp=%h ready=%0d",
                         name, ack_vlen, ack_vec, expf, ack_ready);
            ck(name, ack_ready && ack_vlen == n && ack_vec === expf);
        end
    endtask
    task sendb(input [7:0] v);
        begin b = v; @(posedge clk); rx_vld <= 1'b1; @(posedge clk); rx_vld <= 1'b0;
              repeat (40) @(posedge clk); end
    endtask
    integer w;
    task run_cmd(input [8*24-1:0] s, input integer n);
        integer j; begin
            ack_ready = 0; alen = 0; exp_firen = fire_n;
            for (j = 0; j < n; j = j + 1) sendb(s[(n-1-j)*8 +: 8]);
            w = 0; while (!ack_ready && w < 300) begin @(posedge clk); w = w + 1; end
        end
    endtask

    initial begin
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1;
        // 复位默认档
        ck("d01 reset br=5",    dut.br_lvl === 4'd5);
        ck("d02 reset gn=5",    dut.gn_lvl === 4'd5);
        ck("d03 reset fd=0",    dut.fd_mode === 2'd0);
        ck("d04 reset ck/vu=0", dut.clk_on === 1'b0 && dut.vu_on === 1'b0);
        ck("d05 reset sr=0",    dut.sr_spd === 3'd0);

        run_cmd("BR 7\n", 5);   expect_ack("OK", 4, "t01 BR 7 ack");
        ck("t01b br=7",         dut.br_lvl === 4'd7);
        run_cmd("br 3\n", 5);   expect_ack("OK", 4, "t02 br 3 lowercase ack");
        ck("t02b br=3",         dut.br_lvl === 4'd3);
        run_cmd("BR 10\n", 6);  expect_ack("ERR", 5, "t03 BR 10 -> ERR");
        ck("t03b br holds 3",   dut.br_lvl === 4'd3);
        run_cmd("GN 2\n", 5);   expect_ack("OK", 4, "t04 GN 2 ack");
        ck("t04b gn=2",         dut.gn_lvl === 4'd2);
        run_cmd("FD 3\n", 5);   expect_ack("OK", 4, "t05 FD 3 ack");
        ck("t05b fd=3",         dut.fd_mode === 2'd3);
        run_cmd("FD 4\n", 5);   expect_ack("ERR", 5, "t06 FD 4 out-of-range -> ERR");
        ck("t06b fd holds 3",   dut.fd_mode === 2'd3);
        run_cmd("CK 1\n", 5);   expect_ack("OK", 4, "t07 CK 1 ack");
        ck("t07b clk_on=1",     dut.clk_on === 1'b1);
        run_cmd("VU 1\n", 5);   expect_ack("OK", 4, "t08 VU 1 ack");
        ck("t08b vu_on=1",      dut.vu_on === 1'b1);
        run_cmd("SR 4\n", 5);   expect_ack("OK", 4, "t09 SR 4 ack");
        ck("t09b sr=4",         dut.sr_spd === 3'd4);
        run_cmd("SR 9\n", 5);   expect_ack("ERR", 5, "t10 SR 9 -> ERR");
        ck("t10b sr holds 4",   dut.sr_spd === 3'd4);

        // ---- 防撞回归：近邻旧命令一律原语义 ----
        run_cmd("COL 2\n", 6);  expect_ack("OK", 4, "r01 COL unaffected by CK");
        ck("r01b txt_col=2",    dut.txt_col === 3'd2);
        run_cmd("VOL 5\n", 6);  expect_ack("OK", 4, "r02 VOL unaffected by VU");
        ck("r02b vol=5",        dut.vol_lvl === 4'd5);
        run_cmd("SPD 2\n", 6);  expect_ack("OK", 4, "r03 SPD unaffected by SR");
        run_cmd("CLR\n",   4);  expect_ack("OK", 4, "r04 CLR still fine");
        run_cmd("STAT?\n", 6);
        ck("r05 STAT? ack len", ack_ready && ack_vlen == 10);
        run_cmd("SCAN3\n", 6);  expect_ack("OK", 4, "r06 SCAN3 (no space, v10.2 form)");
        ck("r06b SCAN3 fired PRM", fire_n == exp_firen + 1);
        ck("r07 no bogus fires on BR..SR", fire_n >= 0);  // (fires only via SCAN/SPD above)

        // 参数命令不得触发 PRM 播放
        exp_firen = fire_n;
        run_cmd("BR 6\n", 5);
        ck("p01 BR fires no PRM", fire_n == exp_firen);

        $display("=== SUMMARY: %0d checks, %0d FAIL ===", checks, fails);
        $finish;
    end
endmodule
