`timescale 1ns/1ps
module tb_starve4;
reg clk=0, rst_n=0; always #5 clk=~clk;
reg in_sov=0,in_eov=0,in_en=0; reg [23:0] in_data=0;
reg [15:0] iw,ih; wire out_en; wire [31:0] out_data; wire fd;
img_scaler u(.clk(clk),.rst_n(rst_n),.in_sov(in_sov),.in_en(in_en),.in_eov(in_eov),
  .in_data(in_data),.src_w(iw),.src_h(ih),.out_en(out_en),.out_data(out_data),.frame_done(fd));
integer cnt=0, fds=0, i=0, j=0, W, H, tmo; reg mon=0;
always @(posedge clk) begin
  if (mon && out_en) cnt=cnt+1;
  if (mon && fd) fds=fds+1;
end
task feed; input [31:0] wh; input integer gap; begin
  @(posedge clk); rst_n=1; iw<=wh[31:16]; ih<=wh[15:0];
  W=wh[31:16]; H=wh[15:0];
  @(posedge clk); in_sov<=1; @(posedge clk); in_sov<=0; mon=1;
  for (i=0;i<W*H;i=i+1) begin
    for (j=0;j<gap;j=j+1) @(posedge clk);
    @(posedge clk); in_en<=1; in_data<=i[23:0]; @(posedge clk); in_en<=0;
  end
  @(posedge clk); in_eov<=1; @(posedge clk); in_eov<=0;
  tmo=0; while ((cnt < 307200 || fds==0) && tmo < 1200000) begin @(posedge clk); tmo=tmo+1; end
  $display("GAP%0d %0dx%0d => out=%0d fd=%0d tail=%0d %s",
    gap,W,H,cnt,fds,tmo,(cnt>=307200 && fds>0)?"PASS":"*** FAIL ***");
  mon=0; cnt=0; fds=0; @(posedge clk); rst_n=0; @(posedge clk); @(posedge clk);
end endtask
initial begin
  feed({16'd320,16'd240}, 60);
  feed({16'd640,16'd200}, 60);
  feed({16'd1280,16'd720}, 60);
  $display("all-done"); $finish;
end
endmodule
