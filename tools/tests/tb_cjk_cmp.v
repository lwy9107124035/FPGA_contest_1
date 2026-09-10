`default_nettype wire
`timescale 1ns/1ps
//=============================================================================
// tb_cjk_cmp.v -- WP-J "true font-responder" differential bench
//
//   osd_banner (current, v8+ ascii BRAM)  vs  osd_banner_golden (v7.2+COL)
//   fed IDENTICAL 640x480 raster + IDENTICAL 22-slot MSG writes, each DUT
//   paired with its OWN behavioral glyph_xcd responder (same LAT, same hash)
//   so the CJK return path -- never exercised by WP-G's static xcd TB -- now
//   really runs: FSM -> req_v/addr -> busy -> new_v -> G_TAKE -> 16x G_WR ->
//   glyph_ram -> rd_word pre-issue -> pixels.
//
//   Scenarios: mixed half/full text commits, steady CJK frames, loader_inhibit
//   held-frame, mid-frame inhibit drop during pending dirty, GB2312 edge
//   codes, EMG cjk16 rows, and a NEGATIVE CONTROL flipping ONE BIT inside
//   the golden-side responder only (must break the pixel comparison, proving
//   CJK pixels are live on the compare wire).
//=============================================================================
module tb;

    `include "tb_golden_fn.v"      // verbatim original glyph8x16 (content check)

    localparam integer LP = 688, BL = 48;   // cycles/line, blank cycles
    localparam integer LAT = `LATV;         // responder latency (cycles)

    // ---- shared stimulus nets ---------------------------------------------
    reg          clk = 1'b0;
    reg          rst_n;
    reg          de;
    reg  [11:0]  x, y;
    reg  [23:0]  rgb_in;
    reg          msg_we;
    reg  [4:0]   msg_wslot;
    reg  [15:0]  msg_wcode;
    reg          msg_commit;
    reg          emg_mode;
    reg  [1:0]   emg_sel;
    reg  [2:0]   txt_col_sel;
    reg          loader_inhibit;

    // DUT-side xcd wires (golden side)
    wire         req_g, new_g, busy_g;
    wire [19:0]  addr_g;
    wire [255:0] out_g;
    // DUT-side xcd wires (current side)
    wire         req_n, new_n, busy_n;
    wire [19:0]  addr_n;
    wire [255:0] out_n;

    reg  [255:0] flip_g, flip_n;             // responder XOR (negative control)
    wire [15:0]  done_g, done_n;

    wire [23:0]  ro_n, ro_g;

    osd_banner dut_n (
        .clk(clk), .rst_n(rst_n), .de(de), .x(x), .y(y),
        .rgb_in(rgb_in), .rgb_out(ro_n),
        .msg_we(msg_we), .msg_wslot(msg_wslot), .msg_wcode(msg_wcode),
        .msg_commit(msg_commit),
        .emg_mode(emg_mode), .emg_sel(emg_sel), .txt_col_sel(txt_col_sel),
        .xcd_new_v(new_n), .xcd_out_v(out_n), .xcd_busy_v(busy_n),
        .loader_inhibit(loader_inhibit),
        .xcd_req_v(req_n), .xcd_addr_v(addr_n)
    );
    xcd_resp #(.LAT(LAT)) resp_n (
        .clk(clk), .rst_n(rst_n), .req_v(req_n), .addr_v(addr_n),
        .flip_mask(flip_n), .busy_v(busy_n), .new_v(new_n), .out_v(out_n),
        .done_cnt(done_n)
    );

    osd_banner_golden dut_g (
        .clk(clk), .rst_n(rst_n), .de(de), .x(x), .y(y),
        .rgb_in(rgb_in), .rgb_out(ro_g),
        .msg_we(msg_we), .msg_wslot(msg_wslot), .msg_wcode(msg_wcode),
        .msg_commit(msg_commit),
        .emg_mode(emg_mode), .emg_sel(emg_sel), .txt_col_sel(txt_col_sel),
        .xcd_new_v(new_g), .xcd_out_v(out_g), .xcd_busy_v(busy_g),
        .loader_inhibit(loader_inhibit),
        .xcd_req_v(req_g), .xcd_addr_v(addr_g)
    );
    xcd_resp #(.LAT(LAT)) resp_g (
        .clk(clk), .rst_n(rst_n), .req_v(req_g), .addr_v(addr_g),
        .flip_mask(flip_g), .busy_v(busy_g), .new_v(new_g), .out_v(out_g),
        .done_cnt(done_g)
    );

    always #19.936 clk = ~clk;      // 25.175 MHz pixel clock

    // ---- raster (identical to WP-G's proven generator) ---------------------
    reg [9:0] cyc, ycnt;
    always @(posedge clk) begin : RASTER
        reg [9:0] nc, ny;
        if (!rst_n) begin
            cyc <= 10'd0; ycnt <= 10'd0;
            de <= 1'b0; x <= 12'd0; y <= 12'd0; rgb_in <= 24'd0;
        end else begin
            nc = (cyc == LP-1) ? 10'd0 : (cyc + 10'd1);
            ny = (cyc == LP-1) ? ((ycnt == 10'd479) ? 10'd0 : (ycnt + 10'd1))
                               : ycnt;
            cyc  <= nc;
            ycnt <= ny;
            de     <= (nc >= BL);
            x      <= (nc >= BL) ? {2'd0, (nc - BL)} : 12'd0;
            y      <= {2'd0, ny};
            rgb_in <= {ny[7:0], (nc[7:0] ^ 8'h3C), ny[3:0], nc[3:0]};
        end
    end

    // ---- cycle-by-cycle comparator ------------------------------------------
    integer cmp_n, mism, mism_cfg, cov_cjk_px, cov_cjk_lit, cov_txt_msg;
    integer run_cmp;
    integer req_seen, addr_viol;
    reg [19:0] max_addr;
    integer hit_3356, hit_2384, hit_3676, hit_3145, hit_8836, hit_8930;
    always @(negedge clk) begin : COMPARE
        if (run_cmp == 1) begin
            cmp_n = cmp_n + 1;
            if (ro_n !== ro_g) begin
                mism = mism + 1;
                if (mism <= 20)
                    $display("[%0t] MISMATCH #%0d x=%0d y=%0d de=%b new=%h golden=%h slot=%0d",
                             $time, mism, x, y, de, ro_n, ro_g, x/16);
            end
            if ((req_n !== req_g) || (addr_n !== addr_g)) begin
                mism_cfg = mism_cfg + 1;
                if (mism_cfg <= 10)
                    $display("[%0t] XCD MISMATCH #%0d n=%b/%h g=%b/%h",
                             $time, mism_cfg, req_n, addr_n, req_g, addr_g);
            end
            // ---- g_addr sanity: 19-bit ceiling + 32B alignment + big-offset
            // slot-hit tracking (你/好/全/绿 = g_sum 3356/2384/3676/3145,
            // plus max-code sweep FEFF/FFFF near the 19-bit boundary) ----
            if (req_n === 1'b1) begin
                req_seen = req_seen + 1;
                if (addr_n[19] || ((addr_n & 20'h1F) != 20'd0)) begin
                    addr_viol = addr_viol + 1;
                    $display("[%0t] ADDR VIOLATION req #%0d addr=%h (bit19=%b, align=%0h)",
                             $time, req_seen, addr_n, addr_n[19], addr_n & 20'h1F);
                end
                if (addr_n > max_addr) max_addr = addr_n;
                case (addr_n >> 5)
                    20'd3356: hit_3356 = hit_3356 + 1;   // 你 C4E3
                    20'd2384: hit_2384 = hit_2384 + 1;   // 好 BAC3
                    20'd3676: hit_3676 = hit_3676 + 1;   // 全 C8AB
                    20'd3145: hit_3145 = hit_3145 + 1;   // 绿 C2CC
                    20'd8836: hit_8836 = hit_8836 + 1;   // FEFF: qu93 wei94
                    20'd8930: hit_8930 = hit_8930 + 1;   // FFFF: absolute max
                endcase
            end
            // NOTE: out_n/out_g intentionally NOT compared -- they must diverge
            // during the negative control (golden responder XORs one bit).
            // req/addr/new/busy are the DUT-driven interface: always equal.
            if ((new_n !== new_g) || (busy_n !== busy_g)) begin
                mism_cfg = mism_cfg + 1;
                if (mism_cfg <= 10)
                    $display("[%0t] RESP TIMING MISMATCH #%0d", $time, mism_cfg);
            end
            // liveness coverage: MSG band pixels where a CJK word is on the
            // render bus, and white text pixels inside the MSG band
            if (de && (y >= 12'd448) && (y < 12'd480)) begin
                if ((|dut_g.rd_word) && (|dut_n.rd_word)) cov_cjk_lit = cov_cjk_lit + 1;
                if (ro_g == 24'hFFFFFF)                   cov_txt_msg = cov_txt_msg + 1;
                if ((|dut_g.rd_word) && (ro_g == 24'hFFFFFF)) cov_cjk_px = cov_cjk_px + 1;
            end
        end
    end

    // ---- TEST-A equivalent: ascii_rom content == original glyph8x16 ---------
    integer a, err_a;
    task run_content_check;
    begin
        err_a = 0;
        for (a = 0; a < 4096; a = a + 1)
            if (dut_n.ascii_rom[a[11:0]] !== glyph8x16(a[11:4], a[3:0])) begin
                err_a = err_a + 1;
                if (err_a <= 10)
                    $display("CONTENT MISMATCH addr=%03h rom=%02h golden=%02h",
                             a[11:0], dut_n.ascii_rom[a[11:0]],
                             glyph8x16(a[11:4], a[3:0]));
            end
        $display("TEST-A: checked 4096/4096 ascii_rom words, %0d content errors", err_a);
    end
    endtask

    // ---- stimulus helpers ----------------------------------------------------
    integer codes [0:21];
    integer wk;

    task wait_frame_start;
    begin
        @(negedge clk);
        while (!((ycnt == 0) && (cyc == 0))) @(negedge clk);
    end
    endtask

    task wait_nd(input integer Y, input integer C);
    begin
        @(negedge clk);
        while (!((ycnt == Y[9:0]) && (cyc == C[9:0]))) @(negedge clk);
    end
    endtask

    // write all 22 slots in v-blank line 410, then pulse commit (WP-G pattern)
    task commit_codes;
    begin
        wait_nd(410, 10);
        for (wk = 0; wk < 22; wk = wk + 1) begin
            msg_we    = 1'b1;  msg_wslot = wk[4:0];
            msg_wcode = codes[wk][15:0];
            @(negedge clk);
        end
        msg_we = 1'b0;
        wait_nd(410, 44);
        msg_commit = 1'b1;  @(negedge clk);  msg_commit = 1'b0;
    end
    endtask

    task load_txt1; begin
        codes[0]=16'h0048; codes[1]=16'h0065; codes[2]=16'h006C; codes[3]=16'h006C;
        codes[4]=16'h006F; codes[5]=16'h002C; codes[6]=16'h0020; codes[7]=16'h0077;
        codes[8]=16'h006F; codes[9]=16'h0072; codes[10]=16'h006C; codes[11]=16'h0064;
        codes[12]=16'h0021; codes[13]=16'h0020;
        codes[14]=16'hC4E3; codes[15]=16'hBAC3; codes[16]=16'hA3AC;   // 你 好 ，
        codes[17]=16'h0076; codes[18]=16'h0039;                       // v 9
        codes[19]=16'hC8AB; codes[20]=16'hC2CC; codes[21]=16'hA142;   // 全 绿 。
    end endtask

    task load_txt2; begin   // 任意中文测试 OK 全部正常 TEST!!
        codes[0]=16'hD2CE; codes[1]=16'hD2E2; codes[2]=16'hD6D0; codes[3]=16'hCED2;
        codes[4]=16'hB2E2; codes[5]=16'hCAD4; codes[6]=16'h0020; codes[7]=16'h004F;
        codes[8]=16'h004B; codes[9]=16'h0020;
        codes[10]=16'hC8AB; codes[11]=16'hB2BF; codes[12]=16'hD5FD; codes[13]=16'hB3A3;
        codes[14]=16'h0054; codes[15]=16'h0045; codes[16]=16'h0053; codes[17]=16'h0054;
        codes[18]=16'h0021; codes[19]=16'h0021; codes[20]=16'h0000; codes[21]=16'h0000;
    end endtask

    task load_txt3; begin   // 集合点 保持冷静 EMGCALM...   (committed UNDER inhibit)
        codes[0]=16'hBCAF; codes[1]=16'hBACF; codes[2]=16'hB5E3; codes[3]=16'h0020;
        codes[4]=16'hB1A3; codes[5]=16'hB3D6; codes[6]=16'hC1E4; codes[7]=16'hBEB2;
        codes[8]=16'h0045; codes[9]=16'h004D; codes[10]=16'h0047; codes[11]=16'h0020;
        codes[12]=16'h0043; codes[13]=16'h0041; codes[14]=16'h004C; codes[15]=16'h004D;
        codes[16]=16'hC4E3; codes[17]=16'hBAC3; codes[18]=16'h0000; codes[19]=16'h0000;
        codes[20]=16'h0000; codes[21]=16'h0000;
    end endtask

    task load_txt4; begin   // 危险区域禁止通行 + ASCII tail (mid-frame inhibit drop)
        codes[0]=16'hCEA3; codes[1]=16'hCFD5; codes[2]=16'hC7F8; codes[3]=16'hD3F2;
        codes[4]=16'hBDAF; codes[5]=16'hD6B9; codes[6]=16'hCDA8; codes[7]=16'hD0D0;
        codes[8]=16'h0020; codes[9]=16'h004E; codes[10]=16'h004F; codes[11]=16'h002D;
        codes[12]=16'h0047; codes[13]=16'h004F; codes[14]=16'h0020; codes[15]=16'hC8AB;
        codes[16]=16'hC2CC; codes[17]=16'h0020; codes[18]=16'h0021; codes[19]=16'h0020;
        codes[20]=16'h0000; codes[21]=16'h0000;
    end endtask

    task load_txt5; begin   // GB2312 edge-code sweep + odd half codes
        codes[0]=16'hA1A1; codes[1]=16'hFEFE; codes[2]=16'hA1FE; codes[3]=16'hFEA1;
        codes[4]=16'hA1FF;   // wei=94 OOB row-cross (FSM does not validate)
        codes[5]=16'hFE41;   // lo<A1: not full, not half -> dark
        codes[6]=16'h00FF;   // half, ROM 0x7F..0xFF blank
        codes[7]=16'h0100;   // neither half nor full -> dark
        codes[8]=16'hC4E3;   // repeat 你 -> forces fresh fetch (no dedup)
        codes[9]=16'h0041; codes[10]=16'h007A; codes[11]=16'h0030;
        codes[12]=16'hA1E3; codes[13]=16'hB0A1; codes[14]=16'hD7D7;
        codes[15]=16'h0020; codes[16]=16'hFEFF;  // qu=93 wei=94 -> g_sum 8836 (big)
        codes[17]=16'hFFFF;                     // absolute max: g_sum 8930 = 285760
        codes[18]=16'hA1A1; codes[19]=16'h002E; codes[20]=16'h0000; codes[21]=16'hB5E3;
    end endtask

    task load_txt6; begin   // 全绿回归测试中文任意 + digits  (NEG-control fetch)
        codes[0]=16'hC8AB; codes[1]=16'hC2CC; codes[2]=16'hB9E9; codes[3]=16'hB9E6;
        codes[4]=16'hB2E2; codes[5]=16'hCAD4; codes[6]=16'hD6D0; codes[7]=16'hCEC4;
        codes[8]=16'hC8CE; codes[9]=16'hD2E2; codes[10]=16'h0030; codes[11]=16'h0031;
        codes[12]=16'h0032; codes[13]=16'h0033; codes[14]=16'h0034; codes[15]=16'h0035;
        codes[16]=16'h0036; codes[17]=16'h0037; codes[18]=16'h0038; codes[19]=16'h0039;
        codes[20]=16'hA3A1; codes[21]=16'h0000;
    end endtask

    task frame_tail(input integer f);   // run to end of current frame + report
    begin
        @(negedge clk);
        while (!((ycnt == 0) && (cyc == 0))) @(negedge clk);
        $display("[%0t] frame %0d done: cmp=%0d mism=%0d cfg_mism=%0d fetch(n=%0d,g=%0d)",
                 $time, f, cmp_n, mism, mism_cfg, done_n, done_g);
    end
    endtask

    integer mism_before_neg, mism_at_f16, mism_after_restore;
    // main sequence -------------------------------------------------------------
    integer k;
    initial begin
        rst_n = 1'b0;
        de = 1'b0; x = 12'd0; y = 12'd0; rgb_in = 24'd0;
        msg_we = 1'b0; msg_wslot = 5'd0; msg_wcode = 16'd0; msg_commit = 1'b0;
        emg_mode = 1'b0; emg_sel = 2'd0; txt_col_sel = 3'd0;
        loader_inhibit = 1'b0;
        flip_g = 256'd0; flip_n = 256'd0;
        cyc = 10'd0; ycnt = 10'd0;
        cmp_n = 0; mism = 0; mism_cfg = 0; run_cmp = 0;
        req_seen = 0; addr_viol = 0; max_addr = 20'd0;
        hit_3356 = 0; hit_2384 = 0; hit_3676 = 0; hit_3145 = 0;
        hit_8836 = 0; hit_8930 = 0;
        cov_cjk_px = 0; cov_cjk_lit = 0; cov_txt_msg = 0;

        run_content_check;                  // TEST-A at t=0

        repeat (6) @(negedge clk);
        rst_n = 1'b1;                       // async release inside blanking
        frame_tail(-1);
        run_cmp = 1;

        // f0: power-on preset row, no activity
        frame_tail(0);

        // f1: real CJK text #1 -> 6 fetches start
        load_txt1; commit_codes; frame_tail(1);
        // f2,f3: CJK fully fetched + rendering steady
        frame_tail(2);
        frame_tail(3);
        // f4: 14-CJK text #2
        load_txt2; commit_codes; frame_tail(4);
        frame_tail(5);
        // f6: commit UNDER loader_inhibit (must NOT fetch; dirty queues)
        loader_inhibit = 1'b1;
        load_txt3; commit_codes;
        frame_tail(6);
        // f7: inhibit released at frame start -> queued fetches run (~10)
        loader_inhibit = 1'b0;
        frame_tail(7);
        // f8: commit again under inhibit, drop inhibit MID-FRAME while raster live
        loader_inhibit = 1'b1;
        load_txt4; commit_codes;
        wait_nd(300, 100);                  // mid active picture
        loader_inhibit = 1'b0;
        frame_tail(8);
        frame_tail(9);
        // f10: edge-code sweep; f11 settle
        load_txt5; commit_codes; frame_tail(10);
        frame_tail(11);
        // f12-14: EMG big-font rows (cjk16 path live on the compare wire)
        emg_mode = 1'b1;
        emg_sel = 2'd0; frame_tail(12);
        emg_sel = 2'd1; frame_tail(13);
        emg_sel = 2'd2; frame_tail(14);
        emg_mode = 1'b0;

        // f15: NEGATIVE CONTROL -- flip ONE bit (row5 LSB) in GOLDEN responder only
        mism_before_neg = mism;
        load_txt6;
        flip_g = 256'h1 << 160;             // word row5 (bits [175:160]) bit0
        commit_codes;
        frame_tail(15);
        flip_g = 256'h0;
        // f16: both re-fetch clean (golden re-reads un-flipped glyph)
        load_txt6; commit_codes; frame_tail(16);
        mism_at_f16 = mism;
        frame_tail(17);
        mism_after_restore = mism - mism_at_f16;   // must be 0: flip was transient

        $display("============================================================");
        $display("total cycles compared        : %0d", cmp_n);
        $display("rgb_out mismatches           : %0d", mism);
        $display("  up to f14 (pre-NEG)        : %0d  (expect 0)", mism_before_neg);
        $display("  induced by NEG flip        : %0d  (expect >0)",
                 mism_at_f16 - mism_before_neg);
        $display("  new after flip removed     : %0d  (expect 0)", mism_after_restore);
        $display("xcd req/addr/resp mismatches : %0d  (expect 0)", mism_cfg);
        $display("fetches completed  n/g       : %0d / %0d", done_n, done_g);
        $display("MSG-band CJK-word lit cycles : %0d  (expect >0)", cov_cjk_lit);
        $display("MSG-band white text px       : %0d", cov_txt_msg);
        $display("CJK-lit AND white-text px    : %0d  (expect >0)", cov_cjk_px);
        $display("-- g_addr audit (19-bit ceiling) --");
        $display("req pulses seen            : %0d", req_seen);
        $display("addr violations (bit19/align): %0d  (expect 0)", addr_viol);
        $display("max addr observed          : %0d (0x%0h) < 524288? %s",
                 max_addr, max_addr, (max_addr < 20'h80000) ? "YES" : "NO");
        $display("big-offset slot hits 你3356/好2384/全3676/绿3145 : %0d/%0d/%0d/%0d (expect >0 each)",
                 hit_3356, hit_2384, hit_3676, hit_3145);
        $display("max-code hits FEFF-8836 / FFFF-8930           : %0d/%0d (expect >0 each)",
                 hit_8836, hit_8930);
        $display("============================================================");
        if ((err_a == 0) && (mism_before_neg == 0) &&
            (mism_at_f16 - mism_before_neg > 0) && (mism_after_restore == 0) &&
            (mism_cfg == 0) && (done_n > 20) && (done_g == done_n) &&
            (cov_cjk_px > 100) && (addr_viol == 0) && (max_addr < 20'h80000) &&
            hit_3356 && hit_2384 && hit_3676 && hit_3145 && hit_8836 && hit_8930) begin
            $display("TEST-B: EQUIVALENT on real XCD traffic, CJK path LIVE, neg-control OK");
            if (mism > 0)
                $display("VERDICT: osd_banner innocent (diffs only under injected responder fault)");
            else
                $display("VERDICT: NO DIFF EVEN UNDER NEG CONTROL -- bench blind, investigate TB");
        end else begin
            if (mism_before_neg > 0)
                $display("VERDICT: REAL DIFFERENCE between golden and current (pre-NEG) -> v8 guilty");
            else
                $display("VERDICT: bench incomplete (coverage/consistency check failed)");
        end
        $finish;
    end

    initial begin
        #1_500_000_000;                      // hard timeout (sim time)
        $display("TIMEOUT");
        $finish;
    end

endmodule
