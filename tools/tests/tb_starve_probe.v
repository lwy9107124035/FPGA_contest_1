`timescale 1ns/1ps
// ????img_scaler ???(b19 B/C)??"??????"??
// ????????? 1 ????(a_go=in_en) ? ???? <307200 ???????
module tb_starve;
reg clk=0, rst_n=0; always #5 clk=~clk;
reg in_sov=0,in_eov=0,in_en=0; reg [23:0] in_data=0;
reg [11:0] iw,ih;
wire out_en; wire [23:0] out_data; wire fd;
img_scaler u(.clk(clk),.rst_n(rst_n),.in_sov(in_sov),.in_en(in_en),.in_eov(in_eov),
  .in_data(in_data),.src_w(iw),.src_h(ih),.out_en(out_en),.out_data(out_data),.frame_done(fd));
integer cnt=0, i=0, W, H, tmo; reg mon=0;
always @(posedge clk) if (mon && out_en) cnt=cnt+1;
task feed; input [31:0] n; begin
  @(posedge clk); rst_n=1; iw<=n[31:16]; ih<=n[15:0];
  W=n[31:16]; H=n[15:0];
  @(posedge clk); in_sov<=1; @(posedge clk); in_sov<=0;
  mon=1;
  for (i=0;i<W*H;i=i+1) begin @(posedge clk); in_en<=1; in_data<=i[23:0]; end
  @(posedge clk); in_en<=0; in_eov<=1; @(posedge clk); in_eov<=0;
  // ???? 2 ???????????
  tmo=0; while (cnt < 307200 && tmo < 2000000) begin @(posedge clk); tmo=tmo+1; end
  $display("SIZE %0dx%0d in_px=%0d => out_en=%0d (want 307200) frame_done_seen=%0s wait_extra=%0d",
            W,H,W*H,cnt,fd,cnt>=307200?"(n/a)":(tmo>=2000000?"TIMEOUT":tmo));
  // ????
  mon=0; @(posedge clk); rst_n=0; @(posedge clk); @(posedge clk);
end endtask
initial begin
  cnt=0; feed({16'd640,16'd480});  cnt=0; feed({16'd640,16'd200});
  cnt=0; feed({16'd1280,16'd360}); cnt=0; feed({16'd400,16'd800});
  cnt=0; feed({16'd320,16'd240});  cnt=0; feed({16'd1280,16'd720});
  $display("done"); $finish;
end
endmodule
