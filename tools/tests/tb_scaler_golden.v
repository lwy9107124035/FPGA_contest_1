//=============================================================================
// tb_scaler_golden.v — 像素级花屏复现台
//
// 目的：不碰板、不烧写，纯仿真证明 img_scaler.v 缩放路径的 4 行环形行缓冲
//       在「写侧无背压 + 读侧四分频」下必然 overrun。
//
// 手法：
//   源图用「位置可寻址」合成图 —— 每像素 R=列号低8位, G=行号低8位, B=(列+行)低8位。
//   若输出像素的 G/B 与它所在的目标坐标不符，即可确证读到了错误的源行。
//
//   同时把 G 分量单独抽出来做「行号轨迹」检查：理想情况下 640x480 输出的
//   每一行 dy，其像素 G 值应恒等于目标源行 syc=GOLDEN_SYC[dy]。
//
// 用法：
//   iverilog -o tb.out -s tb_scaler_golden tb_scaler_golden.v ../user_source/hdl_source/img_scaler.v
//   vvp tb.out
//   产出 scaler_out.txt（每行一个 24bit 像素 hex）供 Python golden 比对
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_scaler_golden;

    // ---------------- 可调：被测源图尺寸（走缩放路径，必须非 640x480） ----------
    localparam SRC_W = 800;
    localparam SRC_H = 600;
    localparam DST_W = 640;
    localparam DST_H = 480;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg        in_en = 1'b0;
    reg [31:0] in_data = 32'd0;
    reg        in_sov = 1'b0;
    reg        in_eov = 1'b0;
    reg [15:0] src_w = SRC_W[15:0];
    reg [15:0] src_h = SRC_H[15:0];

    wire        out_en;
    wire [31:0] out_data;
    wire        frame_done;

    img_scaler u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_en      (in_en),
        .in_data    (in_data),
        .src_w      (src_w),
        .src_h      (src_h),
        .in_sov     (in_sov),
        .in_eov     (in_eov),
        .out_en     (out_en),
        .out_data   (out_data),
        .frame_done (frame_done)
    );

    always #5 clk = ~clk;   // 100MHz

    // ---------------- 输出采集 ----------------
    integer fp, n_out, n_bad, timeout;
    reg [31:0] cap_cnt;

    initial begin
        fp = $fopen("scaler_out.txt", "w");
        if (fp == 0) begin
            $display("ERROR: cannot open scaler_out.txt");
            $finish;
        end
    end

    // ---------------- 合成源图：位置可寻址 ----------------
    function [23:0] pix_at;
        input [15:0] x, y;
        reg [7:0] r8, g8, b8;
        begin
            r8 = x[7:0];
            g8 = y[7:0];
            b8 = x[7:0] + y[7:0];   // 避免表达式位选（Verilog-2001 不合法）
            pix_at = {r8, g8, b8};  // {R,G,B}
        end
    endfunction

    integer x, y;
    integer total_px;

    initial begin
        rst_n = 0; in_en = 0; in_sov = 0; in_eov = 0; in_data = 0;
        n_out = 0; cap_cnt = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // ---- 帧启动：sov 单独一拍（与 img_scaler L141 `if (in_sov)` 语义一致）----
        @(posedge clk);
        in_sov <= 1'b1;
        @(posedge clk);
        in_sov <= 1'b0;

        // ---- 源像素流：in_en 每拍有效，模拟 SD 侧无背压灌数据 ----
        total_px = SRC_W * SRC_H;
        for (y = 0; y < SRC_H; y = y + 1) begin
            for (x = 0; x < SRC_W; x = x + 1) begin
                @(posedge clk);
                in_en   <= 1'b1;
                in_data <= {pix_at(x[15:0], y[15:0]), 8'h00};
                in_eov  <= ((x == SRC_W - 1) && (y == SRC_H - 1)) ? 1'b1 : 1'b0;
            end
        end
        @(posedge clk);
        in_en  <= 1'b0;
        in_eov <= 1'b0;

        // ---- 等出货完成（frame_done）----
        timeout = 0;
        while (!frame_done && timeout < 20_000_000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        @(posedge clk);

        $display("=== IMG_SCALER PIXEL RUN ===");
        $display("src = %0d x %0d   dst = %0d x %0d", SRC_W, SRC_H, DST_W, DST_H);
        $display("out pixels captured = %0d (expect %0d)", n_out, DST_W * DST_H);
        $display("timeout cycles waited = %0d", timeout);
        if (n_out != DST_W * DST_H)
            $display("### PIXEL COUNT MISMATCH: got %0d, expect %0d", n_out, DST_W*DST_H);
        else
            $display("### pixel count OK");
        $fclose(fp);
        $finish;
    end

    // 出货采样：out_en 有效即落盘
    always @(posedge clk) begin
        if (rst_n && out_en) begin
            $fwrite(fp, "%06h\n", out_data[31:8]);
            n_out = n_out + 1;
        end
    end

endmodule
`default_nettype wire
