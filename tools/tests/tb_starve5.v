`timescale 1ns/1ps
// ??????? 512B(=w0/3... ???? 512B=170.67px???? 170 ?+2????)
// ???? SECTOR=170 ??? 1 ?/???? idle 27000 ??Tpx163 ??????
module tb_starve5;
reg clk=0, rst_n=0; always #5 clk=~clk;
reg in_sov=0,in_eov=0,in_en=0; reg [23:0] in_data=0;
reg [15:0] iw,ih; wire out_en; wire [31:0] out_data; wire fd;
integer out_in_burst=0, out_in_idle=0;   // ????????????????
reg busywin=0;
img_scaler u(.clk(clk),.rst_n(rst_n),.in_sov(in_sov),.in_en(in_en),.in_eov(in_eov),
  .in_data(in_data),.src_w(iw),.src_h(ih),.out_en(out_en),.out_data(out_data),.frame_done(fd));
integer cnt=0, fds=0, i=0, j=0, k=0, W, H, tmo, npx; reg mon=0;
always @(posedge clk) begin
  if (mon && out_en) begin cnt=cnt+1; if (busywin) out_in_burst=out_in_burst+1; else out_in_idle=out_in_idle+1; end
  if (mon && fd) fds=fds+1;
end
task feed; input [31:0] wh; begin
  @(posedge clk); rst_n=1; iw<=wh[31:16]; ih<=wh[15:0];
  W=wh[31:16]; H=wh[15:0];
  @(posedge clk); in_sov<=1; @(posedge clk); in_sov<=0; mon=1;
  npx=0;
  while (npx < W*H) begin
    busywin=1;
    for (k=0;k<170;k=k+1) begin
      if (npx < W*H) begin
        @(posedge clk); in_en<=1; in_data<=npx[23:0]; npx=npx+1;
      end
    end
    @(posedge clk); in_en<=0;
    busywin=0;
    for (j=0;j<27000;j=j+1) @(posedge clk);   // ?? SPI ???
  end
  @(posedge clk); in_eov<=1; @(posedge clk); in_eov<=0;
  tmo=0; while ((cnt < 307200 || fds==0) && tmo < 1200000) begin @(posedge clk); tmo=tmo+1; end
  $display("SECTORMODEL %0dx%0d => out=%0d fd=%0d tail=%0d (burst???=%0d idle?=%0d) %s",
    W,H,cnt,fds,tmo,out_in_burst,out_in_idle,(cnt>=307200 && fds>0)?"PASS":"*** FAIL ***");
  mon=0; cnt=0; fds=0; out_in_burst=0; out_in_idle=0;
  @(posedge clk); rst_n=0; @(posedge clk); @(posedge clk);
end endtask
initial begin
  feed({16'd320,16'd240});
  feed({16'd400,16'd800});
  $display("all-done"); $finish;
end
endmodule
