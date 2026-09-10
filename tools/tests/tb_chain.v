`timescale 1ns/1ps
// tb_chain (v10.1 hunt): exercise the REAL chain-scan FSM inside sd_card_bmp
// with a forced-assignment fake bmp (scan_done LEVEL semantics + found pulses).
// Key assertions: after SCAN32 with a 4-image card, player must fire pass2 kick
// and finally CLEAR scan_cont_active (no permanent lock).
module tb_chain;
    reg clk=0, rst=1;
    always #5 clk = ~clk;                     // 100MHz
    wire        display_valid; wire [3:0] state_code;
    wire [1:0]  write_buf_idx, disp_buf_idx;
    wire        write_req, write_en; wire [31:0] write_data;
    wire        SD_nCS, SD_DCLK, SD_MOSI; wire [7:0] dbg_o;
    wire [7:0]  stall_sig_now, stall_hist1, stall_hist2, stall_cnt;
    reg         write_finish_toggle=0, write_req_ack=0, prm_tgl=0, SD_MISO=0,
                key_next=0, key_auto=0, soft_next_btn=0, soft_auto_btn=0,
                soft_prev_btn=0;                     // v10.2
    reg  [3:0]  prm_code=0, prm_a=0; reg [7:0] prm_b=0;

    sd_card_bmp dut(
        .clk(clk), .rst(rst), .key_next(key_next), .key_auto(key_auto),
        .soft_next_btn(soft_next_btn), .soft_auto_btn(soft_auto_btn),
        .soft_prev_btn(soft_prev_btn),                 // v10.2
        .prm_tgl(prm_tgl), .prm_code(prm_code), .prm_a(prm_a), .prm_b(prm_b),
        .list_cnt_o(), .list_depth_o(), .list_cur_o(), // v10.2
        .bmp_width(16'd640), .bmp_height(16'd480),
        .display_valid(display_valid), .state_code(state_code),
        .write_finish_toggle(write_finish_toggle), .write_buf_idx(write_buf_idx),
        .disp_buf_idx(disp_buf_idx), .write_req(write_req), .write_req_ack(write_req_ack),
        .write_en(write_en), .write_data(write_data),
        .multi_res(1'b0), .real_w(), .real_h(), .pix_sov(), .pix_eov(),  // v10.3
        .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK), .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO),
        .dbg_o(dbg_o), .stall_sig_now(stall_sig_now), .stall_hist1(stall_hist1),
        .stall_hist2(stall_hist2), .stall_cnt(stall_cnt));

    // ---------- fake bmp wires (forced onto player-visible nets) ----------
    reg f_sd_init = 0, f_ready = 1, f_done = 0, f_fv = 0;
    reg [31:0] f_fs = 0;
    reg f_wft = 0;
    initial begin
        force dut.sd_init_done       = f_sd_init;
        force dut.bmp_ready          = f_ready;
        force dut.scan_done          = f_done;
        force dut.scan_found_valid   = f_fv;
        force dut.scan_found_sector  = f_fs;
        force dut.write_finish_toggle = f_wft;
    end

    // ---------- fake scan engine v2: board-faithful (IDLE-only accept + LOAD 抢占窗) ----------
    // mst: 0=IDLE(ready) 1=SCAN 2=LOAD pass(ready=0 但 done 保持——板上 done=1&ready=0 之谜的载体)
    integer pass_ctr = 0, load_ctr = 0, nh, hi, cnt, steal_n;
    integer base = 0, ii;                     // v10.3b-18: 12 图卡模型起点
    reg steal = 0;                          // scenario switch: LOAD 抢占演练开/关
    reg [1:0] mst = 0;
    reg [31:0] startv;
    always @(posedge clk) begin
        cnt <= cnt + 1;
        case (mst)
            2'd0: begin
                if (dut.scan_start_pulse) begin           // IDLE 态才采样（真实语义）
                    startv = dut.scan_start_sector_r;
                    // v10.3b-18: 12 张卡（扇区 100..1200），每趟最多 7 张（bmp 物理上限）
                    base = 0;
                    for (ii = 1; ii <= 12; ii = ii + 1)
                        if ((32'd100 * ii) < startv) base = ii;
                    nh = 12 - base; if (nh > 7) nh = 7; if (nh < 0) nh = 0;
                    hi <= 0; cnt <= 0; mst <= 2'd1; f_done <= 0;
                end else if (dut.load_start_pulse) begin  // LOAD：300 拍搬运+回 IDLE 沿+toggle → commit 闭环
                    cnt <= 0; mst <= 2'd2;
                end
            end
            2'd1: begin
                if (cnt == hi*12 + 6 && hi < nh) begin
                    f_fs <= 32'd100 * (base + hi + 1); f_fv <= 1;
                end else f_fv <= 0;
                if (hi < nh && cnt == hi*12 + 7) hi <= hi + 1;
                if (cnt >= nh*12 + 12) begin
                    f_done <= 1; mst <= 2'd0;
                    pass_ctr = pass_ctr + 1;
                    $display("[%0t] FAKE scan pass %0d done (start=%0d hits=%0d)", $time, pass_ctr, startv, nh);
                end
            end
            2'd2: begin
                // 真实 LOAD 通道：对 scan_start 完全免疫（这就是板上被吞的那口），
                //   200 拍帧写完 toggle，300 拍回 IDLE（player 双握手 commit）
                if (cnt == 200) f_wft <= ~f_wft;
                if (cnt >= 300) begin
                    mst <= 2'd0;
                    load_ctr = load_ctr + 1;
                    $display("[%0t] FAKE LOAD #%0d complete (commit expected)", $time, load_ctr);
                end
            end
            default: mst <= 2'd0;
        endcase
        f_ready <= (mst == 2'd0);
    end

    // ---------- observation ----------
    integer checks=0, fails=0;
    task ck(input [8*40-1:0] nm, input ok);
        begin checks=checks+1; if(!ok) begin fails=fails+1; $display("FAIL %0s", nm); end end
    endtask

    task prm_send(input [3:0] code, input [7:0] b);
        begin
            @(posedge clk); prm_code <= code; prm_b <= b; prm_a <= 4'd0;
            @(posedge clk); prm_tgl <= ~prm_tgl;   // ONE flip = one command edge
            repeat (3) @(posedge clk);
        end
    endtask

    integer t;
    initial begin
        // reset + sd init
        repeat (10) @(posedge clk);
        rst <= 0;                                // deassert! (tb_mask32 was comb-only, we are sequential)
        repeat (4) @(posedge clk);
        f_sd_init <= 1;
        // let boot kick (default wanted=4 target=4) run: fake returns 4 hits
        #1500;
        ck("boot scan kicked once", pass_ctr >= 1);
        ck("boot scan_done level=1", dut.scan_done === 1'b1);
        ck("boot found=4", dut.img_found_count === 6'd4);

        // ---- SCAN7: single pass, no chain (wanted=7<=7) ----
        #1000;
        ck("boot settled (no extra pass w/o cmd)", pass_ctr == 1);

        // ---- SCAN32: chain must run pass2 (0 hits) and UNLOCK ----
        prm_send(4'd7, 8'd32);                     // SCAN32 = code 7 per msg_ink v10
        t = pass_ctr;
        #4000;                                      // generous time for 2+ passes
        $display("[SCAN32] pass_ctr=%0d cont_active=%b done=%b wanted=%0d",
                 pass_ctr, dut.scan_cont_active, dut.scan_done, dut.scan_wanted);
        ck("SCAN32 fired >=2 passes", pass_ctr >= t + 2);
        ck("SCAN32 ends UNLOCKED (scan_cont_active=0)", dut.scan_cont_active === 1'b0);

        // ---- VID then re-check unlock persists ----
        prm_send(4'd8, 8'd4);                       // VID 4 = code 8
        #500;
        ck("VID4 arm visible vid_en", dut.vid_en === 1'b1);
        ck("still unlocked", dut.scan_cont_active === 1'b0);

        // ---- SECOND SCAN32 (board scenario!): chain must run again AND unlock ----
        t = pass_ctr;
        prm_send(4'd7, 8'd32);
        #5000;
        $display("[SCAN32#2] pass_ctr=%0d cont=%b done=%b", pass_ctr, dut.scan_cont_active, dut.scan_done);
        ck("SCAN32 second run fired >=2 passes", pass_ctr >= t + 2);
        ck("SCAN32 second run UNLOCKS", dut.scan_cont_active === 1'b0);

        // ---- recovery escape hatch: SCAN4 while (hypothetically) locked must clear ----
        prm_send(4'd7, 8'd32);
        #3000;                                      // mid-chain
        prm_send(4'd5, 8'd0);                       // SCAN4 interrupts
        #2500;
        ck("SCAN4 clears lock even mid-chain", dut.scan_cont_active === 1'b0);

        // ---- v10.2 SCAN n (code 9): single-digit depth 5 -> wanted=5, target=5 ----
        prm_send(4'd9, 8'd5);
        #400;
        $display("[SCANn] wanted=%0d target=%0d", dut.scan_wanted, dut.scan_target_r);
        ck("SCAN5 -> scan_wanted=5",  dut.scan_wanted === 6'd5);
        ck("SCAN5 -> scan_target=5 (single pass)", dut.scan_target_r === 3'd5);

        // ---- v10.2 SCAN n two-digit 12 -> wanted=12, target=7 (chain) ----
        prm_send(4'd9, 8'd12);
        #400;
        ck("SCAN12 -> scan_wanted=12", dut.scan_wanted === 6'd12);
        ck("SCAN12 -> target=7 (chains >7)", dut.scan_target_r === 3'd7);

        // ---- v10.2 RNG58 (code 10) -> mask bits 4..11 = 0x0FF0, exits VID ----
        prm_send(4'd8, 8'd4);                         // arm VID first, then RNG must clear it
        #200;
        prm_send(4'd10, 8'h58);                       // a=5 b=8  -> 第5..12张
        #300;
        $display("[RNG58] play_mask=%h vid_en=%b", dut.play_mask, dut.vid_en);
        ck("RNG58 -> mask=0xFF0 (bits4..11)", dut.play_mask === 32'h0000_0FF0);
        ck("RNG58 -> exits VID (vid_en=0)", dut.vid_en === 1'b0);
        // RNG58 with a=1 b=9 -> bits0..8 = 0x1FF
        prm_send(4'd10, 8'h19);
        #300;
        ck("RNG19 -> mask=0x1FF (bits0..8)", dut.play_mask === 32'h0000_01FF);
        // RNG99 -> a=9,b=9 -> 连 9 张 bit8..16 = 0x1FF00 (proves 32-bit widening beyond byte)
        prm_send(4'd10, 8'h99);
        #300;
        $display("[RNG99] play_mask=%h", dut.play_mask);
        ck("RNG99 -> mask bits8..16 (32bit path)", dut.play_mask === 32'h0001_FF00);
        // ---- prev_masked: on mask 0xFF0, from idx=6 prev=5 (nearest lower set) ----
        ck("prev_masked(6,0xFF0)=5",  prev_probe(5'd6, 32'h0FF0) === 5'd5);
        ck("prev_masked(4,0xFF0)=11 (wrap to highest)", prev_probe(5'd4, 32'h0FF0) === 5'd11);
        ck("prev_masked(8,0xFF0)=7 (nearest lower)", prev_probe(5'd8, 32'h0FF0) === 5'd7);

        // ---- 端到端：按 soft_prev_btn -> 真 img_idx 必须变小（或环回绕到最大号）----
        // 先回到全 4 张可播 + 深度 4 的干净态
        prm_send(4'd5, 8'd0);                         // SCAN4 复位深度（PLYALL 现随张数放开，12 图卡会开太大）
        prm_send(4'd3, 8'h0F);                        // v10.3b-18: 改 PLY 显式锁 4 图池，喂给 wrap 断言
        #6000;                                        // 等 kick->首图重载(300cyc)->commit 闭环
        begin : prev_e2e
            integer i; reg [4:0] x1, x2;
            x1 = dut.img_idx;
            soft_prev_btn <= 1'b0; @(posedge clk);
            soft_prev_btn <= 1'b1; repeat (4) @(posedge clk);
            soft_prev_btn <= 1'b0;
            x2 = x1;
            for (i = 0; i < 800 && (dut.img_idx === x1); i = i + 1) @(posedge clk);
            x2 = dut.img_idx;
            $display("[PREV-E2E] idx %0d -> %0d (after %0d cyc)", x1, x2, i);
            ck("soft_prev_btn -> img_idx actually changed", x2 !== x1);
            ck("PREV wrap rule: 0->max(3) or n->n-1",
               (x1 === 5'd0 && x2 === 5'd3) || (x2 + 5'd1 === x1));
            // 对照：NEXT 按纽仍前进（防 else-if 链插入改变老语义）
            x1 = dut.img_idx;
            soft_next_btn <= 1'b0; @(posedge clk);
            soft_next_btn <= 1'b1; repeat (4) @(posedge clk);
            soft_next_btn <= 1'b0;
            for (i = 0; i < 800 && (dut.img_idx === x1); i = i + 1) @(posedge clk);
            x2 = dut.img_idx;
            $display("[NEXT-E2E] idx %0d -> %0d (after %0d cyc)", x1, x2, i);
            ck("soft_next_btn -> img_idx changed", x2 !== x1);
            ck("NEXT wrap rule: n->n+1 or 3->0",
               (x1 === 5'd3 && x2 === 5'd0) || (x1 + 5'd1 === x2));
        end

        // ================= v10.3b-18: 播放池放开专项 =================
        // 板上抓现行：扫到 15 张、NEXT 只在 0..3 打转（play_mask 默认 0x0F 没随深扫放开）。
        // b-18 语义：scan_done 上升沿自动 play_mask = count_to_bits(已扫张数)。
        prm_send(4'd7, 8'd32);                        // SCAN32 -> 12 图卡链扫 7+5+(0 停)
        #6000;
        $display("[POOL] count=%0d mask=%h cont=%b", dut.img_found_count, dut.play_mask, dut.scan_cont_active);
        ck("b18 12图卡扫满 found=12", dut.img_found_count === 6'd12);
        ck("b18 auto-open mask=0xFFF", dut.play_mask === 32'h0000_0FFF);
        begin : nxt_pool
            integer j; reg [4:0] y1; reg reached_hi; reg [4:0] max_seen;
            reached_hi = 0; max_seen = dut.img_idx;
            for (j = 0; j < 18 && !reached_hi; j = j + 1) begin
                y1 = dut.img_idx;
                soft_next_btn <= 1'b1; @(posedge clk); soft_next_btn <= 1'b0;
                for (ii = 0; ii < 900 && (dut.img_idx === y1); ii = ii + 1) @(posedge clk);
                if (dut.img_idx > max_seen) max_seen = dut.img_idx;
                if (dut.img_idx >= 5'd8) reached_hi = 1;
            end
            $display("[POOL-E2E] NEXT %0d 次, max_seen=%0d", j, max_seen);
            ck("b18 NEXT 越过旧天花板 7（到达 >=8）", reached_hi);
        end
        // 手工选曲不被自动池踩脚：PLY 之后无新扫沿 -> mask 保持用户值
        prm_send(4'd3, 8'h05);                        // PLY 05 = 只播第1、3张
        #400;
        ck("b18 用户 PLY 在池开后仍生效(mask=0x05)", dut.play_mask === 32'h0000_0005);

        $display("=== TB_CHAIN SUMMARY: %0d checks, %0d FAIL ===", checks, fails);
        $finish;
    end

    // peek into the player's prev_masked via hierarchical function call wrapper
    function [4:0] prev_probe;
        input [4:0] cur; input [31:0] avail;
        begin prev_probe = dut.prev_masked(cur, avail); end
    endfunction
endmodule
