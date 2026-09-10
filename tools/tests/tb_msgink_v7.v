`timescale 1ns/1ps
// TB v7: exercise new playback commands through msg_ink.
// Monitors prm_tgl/prm_code/prm_a/prm_b on each accepted command + captures ACK strings.
module tb;
    reg clk = 0, rst_n = 0, de = 0;
    always #20 clk = ~clk;
    reg [7:0] b = 0; wire [7:0] rx = b;
    reg rx_vld = 0;
    wire msg_we; wire [4:0] msg_wslot; wire [15:0] msg_wcode; wire msg_commit;
    wire tx_start; wire [7:0] tx_byte;
    reg tx_done = 1;
    wire emg_mode; wire [1:0] emg_sel; wire [3:0] vol_lvl;
    wire next_pulse, auto_pulse, ls_tgl;
    wire prm_tgl; wire [3:0] prm_code, prm_a; wire [7:0] prm_b;
    wire [2:0] txt_col;
    always @(txt_col) $display("TXT-COL t=%0t col=%0d", $time, txt_col);
    // v9: payload capture — prove raw case survives into the glyph RAM writes
    reg [15:0] cap [0:21]; integer capn = 0;
    always @(posedge clk) if (msg_we && rst_n) begin cap[capn] = msg_wcode; capn = capn + 1; end
    always @(posedge clk) if (msg_commit) begin
        $display("MSG-CAP n=%0d first=%h %h %h %h %h %h %h", capn,
                 cap[0], cap[1], cap[2], cap[3], cap[4], cap[5], cap[6]);
        capn = 0;
    end

    msg_ink dut(.clk(clk), .rst_n(rst_n), .rx_byte(rx), .rx_vld(rx_vld), .de(de),
        .msg_we(msg_we), .msg_wslot(msg_wslot), .msg_wcode(msg_wcode), .msg_commit(msg_commit),
        .tx_start(tx_start), .tx_byte(tx_byte), .tx_done(tx_done),
        .emg_mode(emg_mode), .emg_sel(emg_sel), .vol_lvl(vol_lvl),
        .next_pulse(next_pulse), .auto_pulse(auto_pulse), .ls_tgl(ls_tgl), .dbg(8'h00),
        .prm_tgl(prm_tgl), .prm_code(prm_code), .prm_a(prm_a), .prm_b(prm_b),
        .txt_col(txt_col));

    // ---- ACK capture: reassemble tx byte stream into lines ----
    reg [7:0] ackbuf [0:15]; integer ackn = 0;
    always @(posedge clk) begin
        if (tx_start && tx_byte !== 8'hxx) begin
            ackbuf[ackn % 16] = tx_byte; ackn = ackn + 1;
        end
    end

    // persistent PRM event monitor — ANY change (toggle, not pulse!)
    always @(prm_tgl) begin
        #1; // let NBA on prm_* settle
        $display("PRM-FIRE t=%0t code=%0d a=%0d b=%02h", $time, prm_code, prm_a, prm_b);
    end
    // ack line printer: flush on \n
    reg [7:0] ackline [0:15]; integer acki = 0;
    always @(posedge clk) begin
        if (tx_start) begin
            ackline[acki % 16] = tx_byte;
            if (tx_byte == 8'h0A) begin
                $display("ACK< %s", packline(acki));
                acki = 0;
            end else acki = acki + 1;
        end
    end
    function [127:0] packline(input integer n);
        integer j; begin
            packline = {128{1'b0}};
            for (j=0;j<=n && j<8;j=j+1)
                packline[(7-j)*8 +: 8] = (ackline[j]==8'h0D)?8'h20:ackline[j];
        end
    endfunction

    task sendb(input [7:0] v);
        begin b = v; @(posedge clk); rx_vld <= 1'b1; @(posedge clk); rx_vld <= 1'b0;
              repeat (40) @(posedge clk); end
    endtask
    task sendstr(input [127:0] s, input integer n);
        integer j; begin
            for (j=0;j<n;j=j+1) sendb(s[(n-1-j)*8 +: 8]);
        end
    endtask

    integer i;
    initial begin
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1;
        de = 0;
        // ---- valid commands (PRM-FIRE + expected: 1/0/03 2/2/05 3/0/05 3/0/44 4 5 6) ----
        sendstr("SPD 3\n", 6);
        sendstr("T 2 5\n", 6);
        sendstr("PLY 05\n", 7);
        sendstr("PLY 44\n", 7);
        sendstr("PLYALL\n", 7);
        sendstr("SCAN4\n", 6);
        sendstr("SCAN7\n", 6);
        sendstr("COL 3\n", 6);   // v7.2 -> TXT-COL col=3
        sendstr("COL 7\n", 6);   // -> col=7
        // ---- invalid: must NOT fire prm_tgl, should ack ERR ----
        $display("--- now invalid commands (watch: no PRM-FIRE expected) ---");
        sendstr("COL 9\n", 6);   // palette out of range
        sendstr("SPD A\n", 6);   // n not 1..9
        sendstr("T 9 1\n", 6);   // i>6
        sendstr("PLY 00\n", 7);  // mask zero
        sendstr("SPD 10\n", 7);  // too long / n two-digit
        sendstr("SCAN5\n", 6);   // unsupported depth
        sendstr("NEXT\n", 5);    // old cmd still alive (no prm)
        // ---- v9: lowercase payload + case-insensitive commands ----
        $display("--- v9 case tests ---");
        sendstr("msg hi, Yo!\n", 12); // expect MSG-CAP 0068 0069 002c 0020 0059 006f 0021
        sendstr("spd 6\n", 6);    // lowercase cmd -> PRM-FIRE code=1 a=0 b=06
        sendstr("col 0\n", 6);    // -> TXT-COL col=0
        sendstr("ply 7f\n", 7);   // lowercase hex -> PRM-FIRE code=3 b=7f
        sendstr("NeXt\n", 5);     // mixed case -> ACK OK, no prm
        sendstr("msgg hi\n", 8);  // near-miss -> must ERR, no MSG-CAP
        repeat (600) @(posedge clk);
        $display("=== TB V7 END ===");
        $finish;
    end
endmodule
