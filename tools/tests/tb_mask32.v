`timescale 1ns/1ps
// WP-K self-check #3b (work copy; repo untouched):
//   Exhaustive/random cross-check of the v10 WIDENED (32-bit) player mask
//   functions against INDEPENDENT reference models.  The functions under test
//   are the REAL ones instantiated inside sd_card_bmp (dut.next_masked /
//   dut.first_masked / dut.count_to_bits), reached hierarchically — pure
//   combinational, no clk needed.  Reference uses a different algorithm
//   (arithmetic mask, ascending-distance early-exit, LSB priority) so a bug in
//   one is not mirrored by the other.
//   Directed corners + 4000 pseudo-random avail/cur groups.
module tb_mask32;
    // ---- DUT (the real player, functions reached via hierarchy) ----
    reg clk=0, rst=1;
    always #10 clk = ~clk;
    wire        display_valid; wire [3:0] state_code;
    wire [1:0]  write_buf_idx, disp_buf_idx;
    wire        write_req, write_en; wire [31:0] write_data;
    wire        SD_nCS, SD_DCLK, SD_MOSI; wire [7:0] dbg_o;
    wire [7:0]  stall_sig_now, stall_hist1, stall_hist2, stall_cnt;
    reg         write_finish_toggle=0, write_req_ack=0, prm_tgl=0, SD_MISO=0,
                key_next=0, key_auto=0, soft_next_btn=0, soft_auto_btn=0;
    reg  [3:0]  prm_code=0, prm_a=0; reg [7:0] prm_b=0;

    sd_card_bmp dut(
        .clk(clk), .rst(rst), .key_next(key_next), .key_auto(key_auto),
        .soft_next_btn(soft_next_btn), .soft_auto_btn(soft_auto_btn),
        .prm_tgl(prm_tgl), .prm_code(prm_code), .prm_a(prm_a), .prm_b(prm_b),
        .bmp_width(16'd640), .bmp_height(16'd480),
        .display_valid(display_valid), .state_code(state_code),
        .write_finish_toggle(write_finish_toggle), .write_buf_idx(write_buf_idx),
        .disp_buf_idx(disp_buf_idx), .write_req(write_req), .write_req_ack(write_req_ack),
        .write_en(write_en), .write_data(write_data),
        .multi_res(1'b0),                       // v10.3 严格模式（real_w 等未列端口=悬空容忍）
        .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK), .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO),
        .dbg_o(dbg_o), .stall_sig_now(stall_sig_now), .stall_hist1(stall_hist1),
        .stall_hist2(stall_hist2), .stall_cnt(stall_cnt));

    // ---- INDEPENDENT reference models ----
    function [31:0] ref_count; input [5:0] c; begin
        // distinct method: arithmetic (ALL_ONES >> (32-c)); c=0 -> 0, c=32 -> all
        ref_count = 32'hFFFF_FFFF >> (32 - {1'b0,c});
    end endfunction
    function [4:0] ref_first; input [31:0] a; integer k; reg found; reg [4:0] r; begin
        found=0; r=0;
        for(k=0;k<32 && !found;k=k+1) if(a[k]) begin r=k[4:0]; found=1; end
        ref_first = r;
    end endfunction
    function [4:0] ref_next; input [4:0] cur; input [31:0] a; integer d; reg [5:0] p; reg found; reg [4:0] r; begin
        found=0; r=cur;
        for(d=1; d<=31 && !found; d=d+1) begin
            p = {1'b0,cur} + d[5:0];
            if (p >= 6'd32) p = p - 6'd32;
            if (a[p[4:0]]) begin r = p[4:0]; found=1; end
        end
        ref_next = r;
    end endfunction

    integer checks=0, fails=0, i, seed;
    reg [4:0]  cur;
    reg [31:0] avail, g1, g2, gc;
    reg [4:0]  dn, rn, df, rf;
    reg [5:0]  c;

    task ck(input [8*48-1:0] nm, input ok);
        begin checks=checks+1; if(!ok) begin fails=fails+1; $display("FAIL %0s", nm); end end
    endtask

    integer t;
    initial begin
        seed = 32'h1357_2468;
        // ---- directed corners for count_to_bits (0..32, all) ----
        for (c=0; c<=6'd32; c=c+6'd1) begin
            g1 = dut.count_to_bits(c); g2 = ref_count(c);
            if (g1===g2) checks=checks+1; else ck("count_to_bits corner mismatch", 0);
        end
        // ---- directed corners: first_masked single-bit every position ----
        for (t=0; t<32; t=t+1) begin
            avail = (32'd1 << t);
            df = dut.first_masked(avail); rf = ref_first(avail);
            if (df===rf && df===t[4:0]) checks=checks+1; else ck("first single-bit corner", 0);
        end
        avail = 32'd0; df = dut.first_masked(avail);
        if (df===5'd0) checks=checks+1; else ck("first(0)=0", 0);
        // ---- directed corners: next_masked, avail single-bit at every pos ----
        for (t=0; t<32; t=t+1) for (i=0; i<32; i=i+1) begin
            avail = (32'd1 << t); cur = i[4:0];
            dn = dut.next_masked(cur, avail); rn = ref_next(cur, avail);
            if (dn===rn) checks=checks+1; else ck("next single-bit corner", 0);
        end
        // ---- 4000 random groups (any cur, any avail incl empty) ----
        for (i=0; i<4000; i=i+1) begin
            seed = seed*32'd1103515245 + 32'd12345; g1 = seed ^ (seed>>7);
            seed = seed*32'd1103515245 + 32'd12345; g2 = seed ^ (seed>>9);
            avail = g1 & g2;                     // bias toward sparse (realistic)
            cur   = g1[4:0];
            dn = dut.next_masked(cur, avail); rn = ref_next(cur, avail);
            if (dn===rn) checks=checks+1; else ck("rand next", 0);
            df = dut.first_masked(avail); rf = ref_first(avail);
            if (df===rf) checks=checks+1; else ck("rand first", 0);
        end
        // ---- 2000 random dense masks (uniform) ----
        for (i=0; i<2000; i=i+1) begin
            seed = seed*32'd1103515245 + 32'd12345; avail = seed ^ (seed>>11) ^ (seed<<3);
            cur  = seed[4:0];
            dn = dut.next_masked(cur, avail); rn = ref_next(cur, avail);
            if (dn===rn) checks=checks+1; else ck("rand2 next", 0);
        end
        $display("=== MASK32 SUMMARY: %0d checks, %0d FAIL ===", checks, fails);
        $display("=== TB MASK32 END ===");
        $finish;
    end
endmodule
