`timescale 1ns/1ps
`default_nettype none
module tb_dbg;
    reg clk=0, rst_n=0, in_en=0, in_sov=0, in_eov=0;
    reg [31:0] in_data=0;
    reg [15:0] src_w=800, src_h=600;
    wire out_en, frame_done, in_ready; wire [31:0] out_data;
    img_scaler u_dut(.clk(clk),.rst_n(rst_n),.in_en(in_en),.in_data(in_data),
        .src_w(src_w),.src_h(src_h),.in_sov(in_sov),.in_eov(in_eov),
        .out_en(out_en),.out_data(out_data),.frame_done(frame_done));
    always #5 clk=~clk;
    integer sc=0, sr=0, brem=8000, grem=0, t=0, pushed=0, ready_hi=0, en_hi=0, ready_but_en=0;
    reg feeding=0;
    always @(negedge clk) begin
        if(feeding) begin
            if(grem>0) begin grem<=grem-1; in_en<=0; in_eov<=0; end
            else if(brem>0) begin
                if(sr>=600) begin feeding<=0; in_en<=0; in_eov<=0; end
                else begin
                    brem<=brem-1; in_en<=1; in_eov<=0;
                    in_data<={sc[7:0],sr[7:0],sc[7:0]+sr[7:0],8'h00};
                    if(sc==799) begin sc<=0; sr<=sr+1; end else sc<=sc+1;
                    if(brem==1) grem<=4500;
                end
            end else brem<=8000;
        end else begin in_en<=0; end
    end
    always @(posedge clk) if(feeding) begin
        pushed=pushed+1;
        if(in_ready) ready_hi=ready_hi+1;
        if(in_en)    en_hi=en_hi+1;
        if(in_ready && !in_en) ready_but_en=ready_but_en+1;
        if(pushed % 100000 == 0)
          $display("  t=%0d pushed=%0d wr_i=%0d rows_done=%0d ready=%b in_en=%b out_px=%0d",
             t,pushed,u_dut.wr_i,u_dut.rows_done,in_ready,in_en,out_px_ct);
    end
    integer out_px_ct=0;
    always @(posedge clk) if(rst_n&&out_en) out_px_ct=out_px_ct+1;
    initial begin
        repeat(10) @(posedge clk); rst_n=1; repeat(10) @(posedge clk);
        @(negedge clk) in_sov=1; @(negedge clk) in_sov=0; @(negedge clk);
        feeding=1; in_en=1; in_data={8'h00,8'h00,8'h00,8'h00};
        for(t=0;t<8000000;t=t+1) @(posedge clk);
        $display("=== SUMMARY ===");
        $display("TB negedge supply beats : %0d", pushed);
        $display("  of which in_ready=1   : %0d", ready_hi);
        $display("  of which in_en=1      : %0d", en_hi);
        $display("  ready=1 but in_en=0   : %0d   <-- TB拒绝点", ready_but_en);
        $display("DUT rows_done=%0d  (expect 600)", u_dut.rows_done);
        $display("DUT out pixels=%0d (expect 307200)", out_px_ct);
        $finish;
    end
endmodule
`default_nettype wire
