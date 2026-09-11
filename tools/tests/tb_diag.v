`timescale 1ns/1ps
// tb_diag.v — 逐周期诊断 img_scaler 读侧门控
// 目的：4096 突发下，读侧到底卡在哪一拍、wr/rd 行号相对关系如何
`default_nettype none
module tb_diag;
    localparam SRC_W = 800, SRC_H = 600;
    localparam BURST_LEN = 4096, BURST_GAP = 6000;

    reg clk=0, rst_n=0, in_en=0, in_sov=0, in_eov=0;
    reg [31:0] in_data=0;
    reg [15:0] src_w=SRC_W, src_h=SRC_H;
    wire out_en, frame_done;
    wire [31:0] out_data;

    img_scaler u_dut(.clk(clk),.rst_n(rst_n),.in_en(in_en),.in_data(in_data),
        .src_w(src_w),.src_h(src_h),.in_sov(in_sov),.in_eov(in_eov),
        .out_en(out_en),.out_data(out_data),.frame_done(frame_done));

    always #5 clk=~clk;

    function [23:0] pix_at; input [15:0] x,y; reg [7:0] r8,g8,b8;
        begin r8=x[7:0]; g8=y[7:0]; b8=x[7:0]+y[7:0]; pix_at={r8,g8,b8}; end
    endfunction

    integer src_col=0, src_row=0, burst_rem=BURST_LEN, gap_rem=0;
    reg feeding=0;
    integer n_out=0, cyc=0;
    integer last_print=0;

    always @(negedge clk) begin
        if (feeding) begin
            if (gap_rem>0) begin gap_rem<=gap_rem-1; in_en<=0; in_eov<=0; end
            else if (burst_rem>0) begin
                if (src_row>=SRC_H) begin feeding<=0; in_en<=0; in_eov<=0; end
                else begin
                    burst_rem<=burst_rem-1; in_en<=1;
                    in_data<={pix_at(src_col[15:0],src_row[15:0]),8'h00};
                    in_eov<=((src_col==SRC_W-1)&&(src_row==SRC_H-1))?1'b1:1'b0;
                    if (src_col==SRC_W-1) begin src_col<=0; src_row<=src_row+1; end
                    else src_col<=src_col+1;
                    if (burst_rem==1) gap_rem<=BURST_GAP;
                end
            end else begin burst_rem<=BURST_LEN; end
        end else begin in_en<=0; in_data<=0; in_eov<=0; end
    end

    // 每 5000 拍打印一次内部状态
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (out_en) n_out = n_out + 1;
        if (cyc - last_print >= 5000) begin
            last_print = cyc;
            $display("t=%0d rows_done=%0d rd_row=%0d dy=%0d dx=%0d syc=%0d sxc=%0d row_rdy=%b frame_tail=%b eovr=%b out=%0d",
                cyc, u_dut.rows_done, u_dut.rd_row, u_dut.dy, u_dut.dx,
                u_dut.syc, u_dut.sxc, u_dut.row_rdy, u_dut.rd_slot, u_dut.slot_gen[0], n_out);
        end
    end

    integer timeout=0;
    initial begin
        repeat(10) @(posedge clk); rst_n=1; repeat(10) @(posedge clk);
        @(negedge clk); in_sov=1; @(negedge clk); in_sov=0;
        @(negedge clk); feeding=1; in_en=1; in_data={pix_at(0,0),8'h00};
        while (feeding && timeout<80_000_000) begin @(posedge clk); timeout=timeout+1; end
        timeout=0;
        while (!frame_done && timeout<80_000_000) begin @(posedge clk); timeout=timeout+1; end
        $display("FINAL out=%0d frame_done=%b rows_done=%0d", n_out, frame_done, u_dut.rows_done);
        $finish;
    end
endmodule
`default_nettype wire
