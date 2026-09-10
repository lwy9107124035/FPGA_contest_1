//=============================================================================
// tb_img_scaler —— img_scaler b-19 新契约 12+1 用例 TB
// -----------------------------------------------------------------------------
// b-19 新契约（RTL: user_source\hdl_source\img_scaler.v guard_c=c_ex0 / sov 无条件重启）：
//   · 只有 640×480 逐位直通（pass 转发=输入字数=307200，恰好等于下游 frame_fifo_write
//     的 write_len=307200 契约，见 hdl_source\SD\frame_fifo_write.v L275：
//     write_cnt<write_len_latch 续写，==才进 S_END→write_finish）。
//   · 其余一律缩放，输出恒 640×480 = 307,200 拍 + frame_done 与末拍同拍。
//     旧"扁条带/过小(<320×16)/过大/极端比(>4:1)直通"守卫全废弃 → 原 S06/S09/S11
//     三个"守卫尺寸走 pass、期望 W*H 字"用例改按新契约（期望 307200）。
// 为什么小尺寸(200×800/200×1000/160×40)放宽为"域内采样"而非逐拍金样：
//   b-19 只改"走不走直通"与"撕帧重启"；缩放路内部（sdiv24 除法调度、Q13 采样、
//   4 行环形缓存）对这些尺寸逐位未变。而环缓存"黑带冲刺律" lead=offy*1280/(Tpx*w0)<4
//   对小尺寸高喂速本就违反（真实 SPI Tpx≥163 恒满足；TB 快节奏喂图会让写指针越过
//   读指针 4 行→槽覆盖），逐拍金样会把"环覆盖"误报成 b-19 回归——那正是旧 RTL 给
//   它们开直通的原因。b-19 关心的是契约面：①总拍数==307200 ②frame_done 到达且
//   与末拍同拍 ③中心区采样点像素确实"来自源"（坐标编码花样，解码落 [1,W*H)——
//   抓"无输出/卡黑/位级垃圾/字数错"）。金样路径保留在尺寸域真会走缩放且喂速满足
//   黑带律的 S02/03/04/05/07/08/10。
// S12 撕帧-重启（b-19 修复3 专测）：喂半帧 1280×720 不给 eov（旧 RTL 撕帧后
//   st 恒 1、eovr 永不置位 → 永久 wedged），随后直接 in_sov 起 320×240 新帧 →
//   帧2 必须完整 307200 拍 + frame_done。
//=============================================================================
`timescale 1ns/1ps
module tb_img_scaler;
    reg clk = 0; always #5 clk = ~clk;      // 100MHz
    reg rst_n = 0;
    reg in_en = 0, sov = 0, eov = 0;
    reg [31:0] in_data = 0;
    reg [15:0] sw = 0, sh = 0;
    wire out_en, fd; wire [31:0] out_data;

    img_scaler dut(.clk(clk),.rst_n(rst_n),.in_en(in_en),.in_data(in_data),
                   .src_w(sw),.src_h(sh),.in_sov(sov),.in_eov(eov),
                   .out_en(out_en),.out_data(out_data),.frame_done(fd));

    integer W, H, gap;
    integer wide, dw, dh, offx, offy, stepx, stepy, dst_area;
    integer fails, nchk, mode;   // mode: 0=scaled金样 1=直通位级(仅640x480) 2=缩放放宽 3=忽略(撕帧源)
    integer obx, oby;             // 输出坐标计数（scaled）
    integer recv;                 // 本帧收到的 out_en 拍数
    integer frame_done_flag, exp_total;
    reg [31:0] in_dly;            // bypass 位级对齐用
    // ---- 撕帧喂图控制 ----
    integer stop_after;           // >0：喂到该像素数即停（不给 eov）
    reg     drop_eov;             // 1：本帧永不拉 eov
    // ---- mode2 中心区采样点（run_case 里按 dst 几何算好）----
    integer p1x,p1y,p2x,p2y,p3x,p3y,p4x,p4y,p5x,p5y;

    initial begin
        fails=0; nchk=0; recv=0; frame_done_flag=0; stop_after=0; drop_eov=0;
        repeat (4) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);
        // S01 直通位级一致：640×480（新契约下唯一直通尺寸）快速喂（1px/2拍）
        run_case(640,480,2,1,"S01 bypass 640x480 bit-exact");
        // S02 wide downscale 800×600 -> 640×480 无黑边
        run_case(800,600,3,0,"S02 800x600 wide-fit full");
        // S03 tall upscale 320×240 -> 640×480 全屏 2 倍
        run_case(320,240,8,0,"S03 320x240 upscale full");
        // S05 wide 1280×720 -> 640×360 上下黑边60（黑带律 Tpx42⇒lead1.4<4）
        run_case(1280,720,40,0,"S05 1280x720 letterbox");
        // S06 200×800：旧=w0<320 守卫直通 → 新契约走缩放，307200 拍+中心区采样放宽
        run_case(200,800,3,2,"S06 200x800 scaled relaxed");
        // S07 奇数宽 777×500 -> 640×411 offy=34（黑带律 lead=34*1280/(41*777)=2.56<4）
        run_case(777,500,40,0,"S07 777x500 odd width");
        // S04 tall 1280×1024 -> 600×480 左右黑边 20
        run_case(1280,1024,2,0,"S04 1280x1024 pillarbox");
        // S09 200×1000（1:5 极端比）：旧=直通兜底 → 新=缩放，期望 307200 拍
        run_case(200,1000,2,2,"S09 200x1000 scaled relaxed");
        // S10 400×800 竖图 1:2 → 240×480 左右黑边（offy=0 无冲刺）金样
        run_case(400,800,3,0,"S10 400x800 pillarbox");
        // S11 160×40 小图：旧=w0<320 直通 → 新=放大缩放，期望 307200 拍
        run_case(160,40,2,2,"S11 160x40 scaled relaxed");
        // S08 背靠背两帧 320×240
        run_case(320,240,8,0,"S08a back-to-back frame1");
        run_case(320,240,8,0,"S08b back-to-back frame2");
        // S12 撕帧-重启（b-19 修复3）：半帧 1280×720 无 eov → 新 sov 320×240 必须完整
        run_tear_restart;
        // 收尾：等总线静默
        repeat (100) @(posedge clk);
        if (fails == 0) $display("=== ALL PASS (%0d checks) ===", nchk);
        else            $display("=== FAILS: %0d / %0d checks ===", fails, nchk);
        $display("SUMMARY (b-19 contract): checks=%0d fails=%0d", nchk, fails);
        $finish;
    end

    task run_case;
        input integer w, h, g; input integer md; input [8*64-1:0] nm;
        begin
            W=w; H=h; gap=g; mode=md;
            // ---- TB 金模型几何（整数一步除法，与 RTL 的 sdiv24 流水完全独立） ----
            wide = ((W*480) >= (H*640)) ? 1 : 0;
            if (md == 1) begin
                dw=W; dh=H; offx=0; offy=0; stepx=0; stepy=0;
                exp_total = W*H;
            end else begin
                if (wide) begin dw=640; dh=(H*640)/W; end
                else      begin dh=480; dw=(W*480)/H; end
                offx=(640-dw)/2; offy=(480-dh)/2;
                stepx=(W*8192)/dw; stepy=(H*8192)/dh;
                exp_total=307200;
            end
            // mode2 中心区采样点（全部落在 dst 有效域内，避开边角 idx=0 歧义）
            p1x=offx+dw/2;    p1y=offy+dh/2;
            p2x=offx+dw/4;    p2y=offy+dh/4;
            p3x=offx+3*dw/4;  p3y=offy+3*dh/4;
            p4x=offx+dw-2;    p4y=offy+dh-2;
            p5x=offx+dw/2;    p5y=offy+dh-2;
            obx=0; oby=0; recv=0; frame_done_flag=0;
            fork
                feed;
                check_timeout(w*H*(2*(g+1)+1) + 800000, nm);  // 喂速上限：每像素 (g+1) 拍周期+余量
            join
            if (recv != exp_total) begin
                fails=fails+1;
                $display("BEATS %0s: got %0d want %0d", nm, recv, exp_total);
            end else nchk = nchk + 1;
            $display("[%0s] done recv=%0d fails=%0d", nm, recv, fails);
        end
    endtask

    // ---- S12：撕帧-重启 ----
    task run_tear_restart;
        begin
            // 帧1：1280×720 喂一半（360 行），永不 eov；mode=3 监视器只数不判
            W=1280; H=720; gap=1; mode=3; exp_total=0;
            stop_after=W*H/2; drop_eov=1'b1;
            obx=0; oby=0; recv=0; frame_done_flag=0;
            feed;                            // 快，无需超时伴跑
            repeat (50000) @(posedge clk);   // 静置 0.5ms：帧1 早已停在半帧（st=1、无 eovr）
            nchk = nchk + 1;
            if (frame_done_flag != 0) begin
                fails=fails+1; $display("TORN frame1 produced frame_done (must stall)");
            end
            stop_after=0; drop_eov=1'b0;
            repeat (64) @(negedge clk);      // 让撕帧残拍（若有）落净再起新帧
            // 帧2：320×240 全新帧（金样逐拍）——旧 RTL 的 sov 被吞 → 字数≠307200 → FAIL
            run_case(320,240,8,0,"S12 torn-restart 320x240");
        end
    endtask

    task check_timeout;
        input integer deadline; input [8*64-1:0] nm;
        integer t;
        begin
            for (t = 0; t < deadline; t = t + 1) begin
                @(posedge clk);
                if (frame_done_flag == 1) t = deadline;
            end
            if (frame_done_flag != 1) begin
                fails = fails + 1;
                $display("TIMEOUT %0s: recv=%0d", nm, recv);
                frame_done_flag = 1;
            end
        end
    endtask

    // 源像素花样：24bit 全帧索引三重置换，逐点唯一，抄错坐标必露馅
    function [23:0] pxpat; input integer n;
        begin pxpat = {n[7:0], n[15:8], n[23:16]}; end
    endfunction

    task feed;
        integer n, tot;
        begin
            tot = W*H;
            if (stop_after > 0 && stop_after < tot) tot = stop_after;
            @(negedge clk);
            sw=W; sh=H; sov=1;
            @(negedge clk); sov=0;
            repeat (gap) @(negedge clk);
            for (n=0; n<tot; n=n+1) begin
                in_en=1; in_data={pxpat(n),8'h00};
                eov= drop_eov ? 1'b0 : (n==tot-1);
                @(negedge clk);
                in_en=0; eov=0;               // 空隙：in_en 必须真正拉低！
                repeat (gap) @(negedge clk);
            end
        end
    endtask

    // owner：Q13 闭式（TB 独立整数版）
    function [15:0] own; input integer k; input integer stp;
        begin own = ((2*k+1)*stp) >> 14; end
    endfunction

    // ---- 输出监视（posedge 采样，永不阻塞 DUT） ----
    always @(posedge clk) begin
        in_dly <= in_data;
        if (out_en === 1'b1) begin
            recv = recv + 1;
            if (mode == 1) begin
                // bypass：位级=上一拍输入（1 拍延迟）
                if (out_data !== {in_dly[31:8],8'h00} && fails < 12) begin
                    fails=fails+1;
                    $display("BYPASS mismatch @%0d: got %h want %h", recv, out_data, {in_dly[31:8],8'h00});
                end
                nchk = nchk + 1;
            end else if (mode == 3) begin
                // 撕帧源帧：不判（帧1 半帧输出本就残缺）
            end else if (mode == 2) begin : relaxed
                integer idx;
                if ((obx==p1x&&oby==p1y)||(obx==p2x&&oby==p2y)||(obx==p3x&&oby==p3y)
                    ||(obx==p4x&&oby==p4y)||(obx==p5x&&oby==p5y)) begin
                    // DUT 出 {pxpat,8'h00}：out[31:24]=n[7:0]…低字节恒 0；解码=pxpat 自逆
                    idx = {out_data[15:8], out_data[23:16], out_data[31:24]};
                    nchk = nchk + 1;
                    if (out_data[7:0] !== 8'h00 || idx == 0 || idx >= W*H) begin
                        fails = fails + 1;
                        $display("SAMPLE(%0d,%0d) out-of-source-domain: got %h idx=%0d limit=%0d",
                                 obx, oby, out_data, idx, W*H);
                    end
                end
                obx = obx + 1;
                if (obx == 640) begin obx=0; oby=oby+1; end
            end else begin : scaled
                integer expv, sy, sx, base;
                if (oby >= offy && oby < offy+dh && obx >= offx && obx < offx+dw) begin
                    sy = own(oby-offy, stepy); sx = own(obx-offx, stepx);
                    if (sy > H-1) sy = H-1;
                    if (sx > W-1) sx = W-1;
                    base = sy*W + sx;
                    expv = {pxpat(base), 8'h00};
                end else expv = 32'd0;
                if (out_data !== expv[31:0] && fails < 12) begin
                    fails=fails+1;
                    $display("PIX mismatch (%0d,%0d)->src(%0d): got %h want %h | rows_done=%0d syc=%0d sxc=%0d",
                             obx, oby, (oby>=offy&&oby<offy+dh&&obx>=offx&&obx<offx+dw)?((own(oby-offy,stepy))*W+own(obx-offx,stepx)):-1,
                             out_data, expv, dut.rows_done, dut.syc, dut.sxc);
                end
                nchk = nchk + 1;
                obx = obx + 1;
                if (obx == 640) begin obx=0; oby=oby+1; end
            end
            if (fd === 1'b1 && mode != 3) begin
                if (recv != exp_total) begin   // frame_done 必须与最后一拍同拍
                    fails=fails+1;
                    $display("FD MISALIGNED recv=%0d total=%0d", recv, exp_total);
                end
                frame_done_flag = 1;
            end
        end
    end

    // fd 可能在 out_en=0 的拍上吗？scaled 末拍同拍出；若 DUT 违约单独兜底
    always @(posedge clk) if (fd === 1'b1 && out_en !== 1'b1 && !frame_done_flag && mode != 3) begin
        fails=fails+1; $display("FD without out_en!"); frame_done_flag=1;
    end

    initial begin
        #3_000_000_000;   // 3s 全局保险丝（S05/S07 慢喂 387/163ms + 其余 ~150ms + 撕帧 ~25ms）
        $display("GLOBAL TIMEOUT"); fails=fails+1; $finish;
    end
endmodule
