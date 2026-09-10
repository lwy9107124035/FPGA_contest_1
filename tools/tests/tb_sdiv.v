`timescale 1ns/1ps
module tb_sdiv;
    reg clk=0, rst_n=0, start=0; reg [23:0] num=0; reg [15:0] den=0;
    wire done; wire [23:0] quo; wire [15:0] rem;
    always #5 clk=~clk;
    sdiv24 dut(.clk(clk),.rst_n(rst_n),.start(start),.num(num),.den(den),
               .done(done),.quo(quo),.rem(rem));
    integer checks=0, fails=0;
    task chk(input [23:0] q, input [15:0] r);
        begin checks=checks+1;
            if(quo!==q||rem!==r) begin fails=fails+1; $display("FAIL got q=%0d r=%0d exp q=%0d r=%0d",quo,rem,q,r); end
        end
    endtask
    task rundiv(input [23:0] nn, input [15:0] dd, input [23:0] q, input [15:0] r);
        begin @(negedge clk) num=nn; den=dd; start=1; @(negedge clk) start=0;
              wait(done===1'b1); @(negedge clk); chk(q, r); end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1; repeat(2) @(negedge clk);
        rundiv(24'd100, 16'd7,   24'd14,  16'd2);
        rundiv(24'd0,   16'd5,   24'd0,   16'd0);
        rundiv(24'd63999,16'd100, 24'd639, 16'd99);
        rundiv(24'd65536,16'd1,  24'd65536,16'd0);
        rundiv(24'd819200,16'd1280, 24'd640, 16'd0); // 1280*640/1280=640 (720p fit)
        rundiv(24'd1280*480,16'd720, 24'd853, 16'd240); // 614400/720=853 r240
        rundiv(24'd16777215,16'd65535,24'd256, 16'd255); // 256*65535=16776960, 余 255
        $display("--- ref 0xFFFFFF/65535 = %0d r%0d", 16777215/65535, 16777215%65535);
        rundiv(24'd1,   16'd65535, 24'd0, 16'd1);
        rundiv(24'd640*256,16'd640, 24'd256,16'd0);
        rundiv(24'd480*4096,16'd480, 24'd4096,16'd0);
        $display("=== SUMMARY: %0d checks, %0d FAIL ===", checks, fails);
        if(fails==0) $display("=== SDIV PASS ==="); else $display("=== SDIV FAIL ===");
        $finish;
    end
    // watchdog
    initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule
