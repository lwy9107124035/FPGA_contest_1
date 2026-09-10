//=============================================================================
// tb_ring_dump2.v — 可靠握手下的 ring 写侧 dump
//
// 复用 tb_scaler_golden_A3.v 的「监视写指针」握手：只有 DUT 真的推进了
// wr_i/wr_slot/rows_done 才摆下一个像素，杜绝重复报价。
// 只喂第 0 行前 6 个像素后停机，dump ring[0..7] 判定是否存在 index 偏移。
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_ring_dump2;

    localparam SRC_W = 800;
    localparam SRC_H = 600;
    localparam NPUSH = 6;

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

    reg [15:0] wi_d1, wi_d2, rd_d1, rd_d2;
    reg [1:0]  ws_d1, ws_d2;
    wire consumed = (wi_d1 !== wi_d2) || (ws_d1 !== ws_d2) || (rd_d1 !== rd_d2);

    always @(posedge clk) begin
        wi_d2 <= wi_d1; wi_d1 <= u_dut.wr_i;
        ws_d2 <= ws_d1; ws_d1 <= u_dut.wr_slot;
        rd_d2 <= rd_d1; rd_d1 <= u_dut.rows_done;
    end

    function [23:0] pix_at;
        input [15:0] x, y;
        reg [7:0] r8, g8, b8;
        begin
            r8 = x[7:0]; g8 = y[7:0]; b8 = x[7:0] + y[7:0];
            pix_at = {r8, g8, b8};
        end
    endfunction

    integer xi;
    reg feeding;
    integer pushes;

    always @(negedge clk) begin
        if (feeding) begin
            if (consumed) xi = xi + 1;
            if (xi >= NPUSH) feeding = 1'b0;
            else begin
                in_en   <= 1'b1;
                in_data <= {pix_at(xi[15:0], 0), 8'h00};
            end
        end else begin
            in_en <= 1'b0;
        end
    end

    always @(posedge clk) if (feeding && consumed) pushes = pushes + 1;

    integer k;
    initial begin
        xi = 0; feeding = 0; pushes = 0;
        rst_n = 0; in_en = 0; in_sov = 0; in_eov = 0; in_data = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (8) @(posedge clk);
        @(negedge clk); in_sov = 1'b1;
        @(negedge clk); in_sov = 1'b0;
        @(negedge clk);
        feeding = 1'b1; xi = 0;
        in_en   = 1'b1;
        in_data = {pix_at(0, 0), 8'h00};

        wait (feeding == 1'b0);
        @(posedge clk);
        @(posedge clk);

        $display("=== RING WRITE-SIDE DUMP (reliable handshake) ===");
        $display("pushed %0d pixels -> DUT write-pointer advanced %0d times", NPUSH, pushes);
        $display("wr_i=%0d wr_slot=%0d rows_done=%0d", u_dut.wr_i, u_dut.wr_slot, u_dut.rows_done);
        for (k = 0; k < NPUSH + 2; k = k + 1) begin
            $display("  ring[%0d] = %06h   expect src(%0d,0)=%06h  %s",
                     k, u_dut.ring[k], k, pix_at(k[15:0], 0),
                     (u_dut.ring[k] === pix_at(k[15:0], 0)) ? "OK" : "MISMATCH");
        end
        $finish;
    end

endmodule
`default_nettype wire
