`timescale 1ns/1ps
// TB: drive msg_ink with a GB2312 MSG stream, dump every slot write.
module tb;
    reg clk = 0, rst_n = 0, de = 0;
    always #20 clk = ~clk;            // 25MHz-ish
    reg [7:0] b = 0; wire [7:0] rx = b;
    reg rx_vld = 0;
    wire msg_we; wire [4:0] msg_wslot; wire [15:0] msg_wcode; wire msg_commit;
    reg tx_done = 1; wire tx_start; wire [7:0] tx_byte;
    wire emg_mode; wire [1:0] emg_sel; wire [3:0] vol_lvl;
    wire next_pulse, auto_pulse, ls_tgl;

    msg_ink dut(.clk(clk), .rst_n(rst_n), .rx_byte(rx), .rx_vld(rx_vld), .de(de),
        .msg_we(msg_we), .msg_wslot(msg_wslot), .msg_wcode(msg_wcode), .msg_commit(msg_commit),
        .tx_start(tx_start), .tx_byte(tx_byte), .tx_done(tx_done),
        .emg_mode(emg_mode), .emg_sel(emg_sel), .vol_lvl(vol_lvl),
        .next_pulse(next_pulse), .auto_pulse(auto_pulse), .ls_tgl(ls_tgl), .dbg(8'h00));

    task sendb(input [7:0] v);
        begin b = v; @(posedge clk); rx_vld <= 1'b1; @(posedge clk); rx_vld <= 1'b0;
              repeat (40) @(posedge clk); end
    endtask

    integer i;
    reg [7:0] stream [0:15];
    initial begin
        for (i=0;i<16;i=i+1) stream[i]=0;
        // "MSG 台风蓝色预警\n": "台风蓝色预警" = CC A8 B7 E7 C0 B6 C9 AB D4 A4 BE AF
        stream[0]=8'h4D; stream[1]=8'h53; stream[2]=8'h47; stream[3]=8'h20;
        stream[4]=8'hCC; stream[5]=8'hA8; stream[6]=8'hB7; stream[7]=8'hE7;
        stream[8]=8'hC0; stream[9]=8'hB6; stream[10]=8'hC9; stream[11]=8'hAB;
        stream[12]=8'hD4; stream[13]=8'hA4; stream[14]=8'hBE; stream[15]=8'hAF;
        $monitor("t=%0t we=%b slot=%0d code=%h commit=%b", $time, msg_we, msg_wslot, msg_wcode, msg_commit);
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1;
        // collect works regardless of de; keep de=0 (all-blank) so engine runs freely
        for (i=0;i<16;i=i+1) sendb(stream[i]);
        sendb(8'h0A);
        repeat (400) @(posedge clk);
        $display("=== done, watch slot dump above ===");
        $finish;
    end
endmodule
