//=============================================================================
// tb_scaler_golden_A2.v — 标准 ready/valid 握手的像素级 golden 验证台
//
// 与上一版 tb_scaler_golden_A.v 的差别：修正了 TB 自身的握手协议缺陷。
// 旧版在 while(!in_ready) 循环体内才拉低 in_en，滞后一拍 -> 每行开头丢像素，
// 造成了「列方向漂移」的假象。本版遵循标准 AXI-S 握手：
//   * data/valid 在 negedge 摆放，保证 posedge 前已稳定
//   * 在 posedge 采样 in_ready 判定「本拍是否被接受」
//   * 只有被接受才推进到下一个像素
//
// 用法：
//   iverilog -o tb_A2.out -s tb_scaler_golden_A2 tb_scaler_golden_A2.v img_scaler_A.v
//   vvp tb_A2.out
//   => scaler_out_A2.txt
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_scaler_golden_A2;

    localparam SRC_W = 800;
    localparam SRC_H = 600;

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
    wire        in_ready;

    img_scaler_A u_dut (
        .clk(clk), .rst_n(rst_n), .in_en(in_en), .in_data(in_data),
        .src_w(src_w), .src_h(src_h), .in_sov(in_sov), .in_eov(in_eov),
        .out_en(out_en), .out_data(out_data), .frame_done(frame_done),
        .in_ready(in_ready)
    );

    always #5 clk = ~clk;

    integer fp, n_out, stall_cycles, sent;
    reg [23:0] pix_hold;
    reg        accepted;
    integer    xi, yi;
    integer    timeout, dwait;
    reg        feeding;

    function [23:0] pix_at;
        input [15:0] x, y;
        reg [7:0] r8, g8, b8;
        begin
            r8 = x[7:0]; g8 = y[7:0]; b8 = x[7:0] + y[7:0];
            pix_at = {r8, g8, b8};
        end
    endfunction

    initial fp = $fopen("scaler_out_A2.txt", "w");

    // ---- 在 posedge 判定本拍是否被接受 ----
    always @(posedge clk) begin
        if (!rst_n) accepted <= 1'b0;
        else if (feeding && u_dut.st && u_dut.in_ready && in_en)
            accepted <= 1'b1;
        else
            accepted <= 1'b0;
    end

    // ---- 在 negedge 摆放数据；只有被接受才推进像素索引 ----
    always @(negedge clk) begin
        if (feeding) begin
            if (accepted) begin
                if (xi == SRC_W - 1) begin
                    xi <= 0;
                    yi <= yi + 1;
                    if (yi == SRC_H - 1) begin
                        feeding <= 1'b0;      // 最后一个像素已发出
                    end
                end else begin
                    xi <= xi + 1;
                end
            end
        end
    end

    always @(negedge clk) begin
        if (feeding) begin
            in_en   <= 1'b1;
            in_data <= {pix_at(xi[15:0], yi[15:0]), 8'h00};
            // eov 随最后一个像素同拍给出（该像素被接受的那一拍）
            in_eov  <= (((xi == SRC_W - 1) && (yi == SRC_H - 1))) ? 1'b1 : 1'b0;
        end else begin
            in_en   <= 1'b0;
            in_data <= 32'd0;
            in_eov  <= 1'b0;
        end
    end

    initial begin
        n_out = 0; stall_cycles = 0; sent = 0; accepted = 0; feeding = 0;
        xi = 0; yi = 0; pix_hold = 0;
        rst_n = 0; in_en = 0; in_sov = 0; in_eov = 0; in_data = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // ---- 帧启动 ----
        @(negedge clk);
        in_sov <= 1'b1;
        @(negedge clk);
        in_sov <= 1'b0;

        // ---- 开始喂数据（阻塞赋值，确保紧随的判断能立刻看到）----
        @(negedge clk);
        feeding = 1'b1;
        xi = 0; yi = 0;

        dwait = 0;
        while (feeding && dwait < 80_000_000) begin
            @(posedge clk);
            dwait = dwait + 1;
        end

        timeout = 0;
        while (!frame_done && timeout < 80_000_000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        @(posedge clk);

        $display("=== IMG_SCALER fix-A PIXEL RUN (standard handshake) ===");
        $display("src = %0d x %0d", SRC_W, SRC_H);
        $display("out pixels captured = %0d (expect %0d)", n_out, 640*480);
        $display("feed cycles = %0d, frame_done wait = %0d", dwait, timeout);
        if (n_out != 640*480) $display("### PIXEL COUNT MISMATCH: %0d", n_out);
        else                  $display("### pixel count OK");
        $fclose(fp);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && out_en) begin
            $fwrite(fp, "%06h\n", out_data[31:8]);
            n_out = n_out + 1;
        end
    end

endmodule
`default_nettype wire
