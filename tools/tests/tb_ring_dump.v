//=============================================================================
// tb_ring_dump.v — 最小实验：只喂第 0 行前 8 个像素，直接 dump ring 单元
//
// 目的：一次性判定写侧是否存在 index 偏移。
//   若 ring[k] == src(k, 0)      -> 写侧正确，错位在别处
//   若 ring[k] == src(k+d, 0)    -> 写侧存在 d 像素偏移
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_ring_dump;

    localparam SRC_W = 800;
    localparam SRC_H = 600;
    localparam NPUSH = 8;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg        in_en = 1'b0;
    reg [31:0] in_data = 32'd0;
    reg        in_sov = 1'b0;
    reg        in_eov = 1'b0;
    reg [15:0] src_w = SRC_W[15:0];
    reg [15:0] src_h = SRC_H[15:0];

    wire        out_en, frame_done, in_ready;
    wire [31:0] out_data;

    img_scaler_A u_dut (
        .clk(clk), .rst_n(rst_n), .in_en(in_en), .in_data(in_data),
        .src_w(src_w), .src_h(src_h), .in_sov(in_sov), .in_eov(in_eov),
        .out_en(out_en), .out_data(out_data), .frame_done(frame_done),
        .in_ready(in_ready)
    );

    always #5 clk = ~clk;

    function [23:0] pix_at;
        input [15:0] x, y;
        reg [7:0] r8, g8, b8;
        begin
            r8 = x[7:0]; g8 = y[7:0]; b8 = x[7:0] + y[7:0];
            pix_at = {r8, g8, b8};
        end
    endfunction

    integer k;
    initial begin
        rst_n = 0; in_en = 0; in_sov = 0; in_eov = 0; in_data = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (8) @(posedge clk);

        // 帧启动
        @(negedge clk); in_sov = 1'b1;
        @(negedge clk); in_sov = 1'b0;

        // 喂第 0 行前 NPUSH 个像素（用标准握手）
        for (k = 0; k < NPUSH; k = k + 1) begin
            // 等到 ready
            while (!(in_ready && in_en)) begin
                @(negedge clk);
                in_en   = 1'b1;
                in_data = {pix_at(k[15:0], 0), 8'h00};
                if (in_ready) @(negedge clk);   // 再稳定半拍
            end
            @(posedge clk);                     // 本拍被采样
            @(negedge clk);
            in_en = 1'b0;
        end
        @(posedge clk);
        @(posedge clk);

        $display("=== RING WRITE-SIDE DUMP ===");
        $display("after pushing %0d pixels of row 0", NPUSH);
        $display("wr_i=%0d wr_slot=%0d rows_done=%0d", u_dut.wr_i, u_dut.wr_slot, u_dut.rows_done);
        for (k = 0; k < NPUSH + 2; k = k + 1) begin
            $display("  ring[%0d] = %06h     expect src(%0d,0) = %06h",
                     k, u_dut.ring[k], k, pix_at(k[15:0], 0));
        end
        $finish;
    end

endmodule
`default_nettype wire
