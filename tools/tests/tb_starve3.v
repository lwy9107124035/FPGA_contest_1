`timescale 1ns/1ps
// b20 单元探针 v3：真实卡几何表（BMP0005=320x240 起），1px/clk 满速喂 + 断流尾窗。
// 判据：out_en==307200 且 frame_done 在断流后 <2M 拍内出现。
module tb_starve3;
reg clk=0, rst_n=0; always #5 clk=~clk;
reg in_sov=0,in_eov=0,in_en=0; reg [23:0] in_data=0;
reg [15:0] iw,ih;
wire out_en; wire [31:0] out_data; wire fd;
img_scaler u(.clk(clk),.rst_n(rst_n),.in_sov(in_sov),.in_en(in_en),.in_eov(in_eov),
  .in_data(in_data),.src_w(iw),.src_h(ih),.out_en(out_en),.out_data(out_data),.frame_done(fd));
integer cnt=0, fd_seen=0, i=0, W, H, tmo; reg mon=0;
always @(posedge clk) if (mon && out_en) cnt=cnt+1;
always @(posedge clk) if (mon && fd) fd_seen=fd_seen+1;
task feed; input [31:0] wh; begin
  @(posedge clk); rst_n=1; iw<=wh[31:16]; ih<=wh[15:0];
  W=wh[31:16]; H=wh[15:0];
  @(posedge clk); in_sov<=1; @(posedge clk); in_sov<=0; mon=1;
  for (i=0;i<W*H;i=i+1) begin @(posedge clk); in_en<=1; in_data<=i[23:0]; end
  @(posedge clk); in_en<=0; in_eov<=1; @(posedge clk); in_eov<=0;
  tmo=0; while (cnt < 307200 && tmo < 2000000) begin @(posedge clk); tmo=tmo+1; end
  $display("SIZE %0dx%0d => out=%0d fd_seen=%0d tail_wait=%0d %s",
            W,H,cnt,fd_seen,tmo,(cnt>=307200 && fd_seen>0)?"PASS":"*** FAIL ***");
  mon=0; fd_seen=0; @(posedge clk); rst_n=0; @(posedge clk); @(posedge clk);
end endtask
initial begin
  cnt=0; feed({16'd320,16'd240});   // BMP0005 = 板上卡死槽 5 真身
  cnt=0; feed({16'd640,16'd200});   // BMP0006
  cnt=0; feed({16'd1280,16'd360});  // BMP0007
  cnt=0; feed({16'd1280,16'd720});  // BMP0001
  cnt=0; feed({16'd800,16'd600});   // BMP0002
  cnt=0; feed({16'd400,16'd800});   // BMP0003
  cnt=0; feed({16'd1024,16'd768});  // BMP0004
  cnt=0; feed({16'd640,16'd480});   // 锚
  $display("done"); $finish;
end
endmodule
