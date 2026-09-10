//=============================================================================
// tb_v103_load —— v10.3 装载全链路时序台（b-19 三链抓现行）
// 拓扑（照真实 TOP user_source\hdl_source\top_tf_hdmi_audio.v L690-702/L748-749）：
//   sd_card_bmp(真,内含 bmp_read_m0/sd_card_top_m0) → write_en/write_data/real_w/h/
//   pix_sov/pix_eov → img_scaler(真) → out_en/out_data → ffw_behav(行为级
//   frame_fifo_write 替身) → write_req/ack 直连、write_finish_toggle 回灌播放器。
// SPI 边界：力驱 dut.sd_sec_read_data / _valid / _end，监听 dut.sd_sec_read/_addr
//   （sd_card_bmp.v L209-213：这些 net 在 bmp_read_m0(L1150) 与 sd_card_top_m0
//    (L1189) 之间——tb_chain.v L40-45 同款 force 手法；sd_card_top 引擎被架空，
//    sd_init_done 直接 force 1）。
// 扇区服务机：见 sd_sec_read 上升沿 → 等 40 拍 → 连续 512 字节（每字节 TPX 拍）
//   → sd_sec_read_end 1 拍；load_abort 抢停（读沿掉 0 即弃当前扇区）。
//   扫描阶段与装载阶段回同一份真文件头：BM/54/24bpp + mr_ok 域内宽高
//   （bmp_read.v L90-96 header_match、L85-89 mr_ok）——扫到 1 张(target=1)即
//   真 scan_done、真 img_sector0 表项，首图自动装载 → 无需 force 表项的最短真实链。
// 契约参考：frame_fifo_write.v L275 附近 S_WRITE_BURST_END：write_cnt<write_len_latch
//   回 S_CHECK_FIFO 续写，==write_len(307200，top FRAME_PIXELS L47) 才 S_END→
//   write_finish；top L171-176 把 write_finish 打平成 write_finish_toggle。
//   替身：收 write_req→3 拍后 ack（S_ACK 秒 ack 行为的同域简化）、req 撤 ack 撤；
//   数 write_en 拍；==307200 同拍翻 toggle；>307200 记 overflow（抓链B越界写）；
//   <307200 永不 toggle（抓链B短帧永不完成）。
// -----------------------------------------------------------------------------
// 测试点：L1 锚 640×480（921,654B）；L2 链A 1280×720 真 2,764,854B（旧 0.8s
//   定标=80M 拍硬超时误杀；b-19 活动门控 sd_card_bmp.v L992 放行）；
//   L3 链B 640×200（旧 !e_band 直通 128,000 拍 → 永不 toggle → 超时）；
//   L3b 链B越界 1280×360（旧直通灌 460,800 字 >307,200 越界）；
//   L4 链C 半帧 1280×720 撕帧(load_abort 注入)→换 320×240 重装（旧 sov 被吞，
//   帧2 字数≠307200；b-19 修复3 in_sov 无条件重启 → 完整）。
// 速率：默认 TPX=60 拍/字节（真实 SPI 标定；L1≈55.3M、L2≈166M、全程≈350M 拍，
//   vvp 数分钟可接受；每 10M 拍 PROGRESS 一行）。编译加 -DTPX_FAST 降为 8 拍/
//   字节：L2 时长 22.1M 拍仍 < 80M 拍超时阈值 → 链A判据不变（file_len 保持真值）。
// 构建（PowerShell，勿全树 file list——加密 hdmi 核炸语法）：
//   $env:PATH+=";C:\iverilog\bin"
//   iverilog -g2005 -s tb_v103_load -I C:\td_batch\lab_pro\user_source `
//     -I C:\td_batch\lab_pro\user_source\hdl_source `
//     -I C:\td_batch\lab_pro\user_source\hdl_source\SD `
//     -I C:\td_batch\lab_pro\user_source\hdl_source\include -o $env:TEMP\t2.vvp `
//     C:\td_batch\lab_pro\tools\tests\tb_v103_load.v `
//     (Get-ChildItem C:\td_batch\lab_pro\user_source\hdl_source\SD -Filter *.v|%FullName) `
//     C:\td_batch\lab_pro\user_source\hdl_source\img_scaler.v `
//     C:\td_batch\lab_pro\user_source\hdl_source\sdiv24.v `
//     C:\td_batch\lab_pro\tools\tests\sim_stubs.v
//   C:\iverilog\bin\vvp.exe $env:TEMP\t2.vvp
//=============================================================================
`timescale 1ns/1ps

//------------------------------------------------------------------ 行为级替身
// frame_fifo_write（~30 行）：语义见上。beats/overflow/toggles/acks 供 TB 层级探针。
module ffw_behav(
    input  wire        clk,
    input  wire        rst,
    input  wire        write_req,
    output reg         write_req_ack,
    input  wire        write_en,
    input  wire [31:0] write_data,
    output reg         write_finish_toggle
);
    // 真 top 里 write_req_ack/write_finish_toggle 均有复位；替身必须同样给初值，
    // 否则 ~X=X → 播放器 toggle 沿检出恒 X → write_done_seen 永不置位（首轮实测踩坑）。
    initial begin write_req_ack = 1'b0; write_finish_toggle = 1'b0; end
    localparam integer WLEN = 307200;                  // top FRAME_PIXELS（24'd307200）
    integer beats = 0, overflow = 0, toggles = 0, acks = 0, tgl_done = 0;
    integer ack_t = 0;
    reg req_d = 0;
    always @(posedge clk) begin
        req_d <= write_req;
        if (rst) begin
            write_req_ack <= 1'b0; ack_t <= 0;
        end else begin
            if (write_req && !write_req_ack) begin
                if (req_d) begin
                    if (ack_t >= 2) begin                 // S_ACK：秒 ack + write_cnt<=0
                        write_req_ack <= 1'b1; ack_t <= 0;
                        beats = 0; tgl_done = 0; acks = acks + 1;
                    end else ack_t <= ack_t + 1;
                end
            end else if (!write_req) begin
                write_req_ack <= 1'b0; ack_t <= 0;        // req 撤 → ack 撤
            end
            // 真实拓扑 FIFO 输入侧无背压（frame_read_write.v L97：we=write_en 恒接），
            // 自 ack 起所有 write_en 拍都计数——>307200 的后半截正是链B越界本体。
            if (write_en) begin
                beats = beats + 1;
                if (beats == WLEN && !tgl_done) begin
                    write_finish_toggle <= ~write_finish_toggle;  // ==307200 同拍翻转
                    toggles = toggles + 1; tgl_done = 1;
                end
                if (beats > WLEN) overflow = overflow + 1; // 越界写事件（链B抓现行点）
            end
        end
    end
endmodule

//------------------------------------------------------------------ TB 主体
module tb_v103_load;

`ifdef TPX_FAST
    localparam integer TPX = 8;    // 降级速率（判据不变，注释见文件头）
`else
    localparam integer TPX = 60;   // 真实 SPI：60 拍/字节
`endif
    localparam integer FILE_SEC = 32'd1000;   // 假想卡上唯一 BMP 的起始扇区

    reg clk = 0; always #5 clk = ~clk;        // 10ns 周期
    reg rst = 1;
    reg soft_next_r = 0;

    // ------------------------------------------------------------------ 文件模型
    integer fW = 640, fH = 480;               // 当前装载文件几何（TB 侧）
    integer file_len = 921654;
    integer sec2 = 2801;                      // 第二迷你图扇区=主文件跳转落点
    task set_file; input integer w, h;
        begin
            fW=w; fH=h; file_len = 54 + 3*w*h;
            sec2 = FILE_SEC + (file_len + 511)/512;   // bmp SCAN 命中后 addr=sec+ceil(len/512)
        end
    endtask
    // 绝对文件位置 → 字节（文件起点=FILE_SEC 扇区：卡绝对扇区须减基准）。
    // BM 头：0:'B' 1:'M' 2..5=file_len 10..13=54 18..21=width 22..25=height
    //   28..29=24bpp 其余 0；像素：BGR 字节序，24bit 值=行主序线性坐标 i 三重字节。
    function [7:0] byte_at; input integer secaddr; input integer idx;
        integer pos, p, i, j;
        reg [31:0] c;
        begin
            // ---- 卡上第二张迷你图（320×80，54+76800=76854B）放在"扫描命中主文件后
            // 的跳转落点"：真实 sd_card_bmp L671-677 的 play_mask 放行采 count 有
            // 1 拍 off-by-one（scan_done 边沿拍到 count 自增可见拍之间），单图卡
            // mask=count_to_bits(0)=0 → 永不装载。双图卡（板上常态）恰好绕开：
            // 第二命中拍的边沿采到 count=1 → mask=bit0 → 首图装载正常。
            if (secaddr == sec2) begin
                pos = idx;   // 迷你图从自己的扇区基址看
                if (pos < 54) begin
                    case (pos)
                        0  : byte_at = "B";
                        1  : byte_at = "M";
                        2  : byte_at = 8'h36;      // file_len 76854 = 0x12C36
                        3  : byte_at = 8'h2C;
                        4  : byte_at = 8'h01;
                        5  : byte_at = 8'h00;
                        10 : byte_at = 8'd54;
                        18 : byte_at = 8'd64;     // 320 = 0x140
                        19 : byte_at = 8'd1;
                        22 : byte_at = 8'd80;     // 80
                        28 : byte_at = 8'd24;
                        default : byte_at = 8'd0;
                    endcase
                end else byte_at = 8'd0;          // 迷你图像素没人消费，给 0
            end else begin
                pos = (secaddr - FILE_SEC)*512 + idx;   // 主文件：卡绝对扇区→文件偏移
            if (pos < 54) begin
                case (pos)
                    0  : byte_at = "B";
                    1  : byte_at = "M";
                    2  : byte_at = file_len[7:0];
                    3  : byte_at = file_len[15:8];
                    4  : byte_at = file_len[23:16];
                    5  : byte_at = file_len[31:24];
                    10 : byte_at = 8'd54;
                    18 : byte_at = fW[7:0];
                    19 : byte_at = fW[15:8];
                    22 : byte_at = fH[7:0];
                    23 : byte_at = fH[15:8];
                    28 : byte_at = 8'd24;
                    default : byte_at = 8'd0;
                endcase
            end else begin
                p = pos - 54;
                if (p < fW*fH*3) begin
                    i = p/3; j = p%3; c = i;
                    case (j)
                        0    : byte_at = c[7:0];
                        1    : byte_at = c[15:8];
                        default: byte_at = c[23:16];
                    endcase
                end else byte_at = 8'd0;
            end
            end
        end
    endfunction

    // ------------------------------------------------------------------ DUT 接线
    wire        ffw_req, ffw_ack, ffw_we, ffw_tgl, sc_en, sc_fd;
    wire [31:0] ffw_wd, sc_out;
    wire [15:0] w_real_w, w_real_h;
    wire        w_sov, w_eov;
    wire        bmp_we;  wire [31:0] bmp_wd;          // sd_card_bmp 原始像素口
    wire        s_in_en; wire [31:0] s_in_d;

    sd_card_bmp #(
        .CLK_FREQ_HZ(100_000_000), .SCAN_START_SECTOR(FILE_SEC),
        .SCAN_MAX_SECTOR(32'd131071), .SCAN_TARGET_COUNT(3'd2)   // 2=绕开 play_mask 单图边沿竞态（见文件模型注释）
    ) dut (
        .clk(clk), .rst(rst), .key_next(1'b0), .key_auto(1'b0),
        .soft_next_btn(soft_next_r), .soft_auto_btn(1'b0), .soft_prev_btn(1'b0),
        .prm_tgl(1'b0), .prm_code(4'd0), .prm_a(4'd0), .prm_b(8'd0),
        .list_cnt_o(), .list_depth_o(), .list_cur_o(),
        .bmp_width(16'd640), .bmp_height(16'd480),
        .display_valid(), .state_code(),
        .write_finish_toggle(ffw_tgl), .write_buf_idx(), .disp_buf_idx(),
        .write_req(ffw_req), .write_req_ack(ffw_ack),
        .write_en(bmp_we), .write_data(bmp_wd),
        .multi_res(1'b1),                          // = TOP msg_scale_en（SC=1 域）
        .real_w(w_real_w), .real_h(w_real_h), .pix_sov(w_sov), .pix_eov(w_eov),
        .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b0),
        .dbg_o(), .stall_sig_now(), .stall_hist1(), .stall_hist2(), .stall_cnt());

    // TOP L690-702：scaler 输入 = sd_card_bmp 像素流（sd_card_write_en/data）
    assign s_in_en = bmp_we;
    assign s_in_d  = bmp_wd;
    img_scaler u_scaler(
        .clk(clk), .rst_n(~rst), .in_en(s_in_en), .in_data(s_in_d),
        .src_w(w_real_w), .src_h(w_real_h), .in_sov(w_sov), .in_eov(w_eov),
        .out_en(sc_en), .out_data(sc_out), .frame_done(sc_fd));

    // TOP L748-749：frame writer 数据口 = scaler 输出（msg_scale_en=1）
    ffw_behav u_ffw(.clk(clk), .rst(rst), .write_req(ffw_req), .write_req_ack(ffw_ack),
                    .write_en(sc_en), .write_data(sc_out), .write_finish_toggle(ffw_tgl));


    // MUTATION EXPERIMENT ONLY (t2mut): 重新引入直通，验证 L2/L3/L3b 判据真的会抓
    initial begin : mut_blk force u_scaler.guard_c = 1'b1; end
    // ------------------------------------------------------------------ SPI 扇区服务机
    reg        svc_valid = 0, svc_end = 0; reg [7:0] svc_byte = 0;
    integer    svcs = 0, bidx = 0, tv = 0; integer sec_addr = 0;
    reg        srd_d = 0;
    reg        sim_sd_init = 0;    // 板上语义：init 完成后才拉高（给播放器 !sd_init_done
                                   // 分支数拍，初始化 scan_cont_active 等 rst 块缺项寄存器，
                                   // 否则 L1024 mux 采到 X → 扫描起点永久 X 化）
    initial begin
        force dut.sd_init_done           = sim_sd_init;
        force dut.sd_sec_read_data       = svc_byte;
        force dut.sd_sec_read_data_valid = svc_valid;
        force dut.sd_sec_read_end        = svc_end;
        // 注：曾试 force dut.sd_card_top_m0.clk=0 给旁路引擎停钟提速——与父级连线驱动
        //     冲突，iverilog 零时间活锁，勿再尝试（引擎本身开销可接受）。
    end
    always @(posedge clk) begin
        srd_d <= dut.sd_sec_read;
        if ((svcs == 1 || svcs == 2) && !dut.sd_sec_read) begin  // 撕帧抢停
            svcs <= 0; svc_valid <= 0; svc_end <= 0;
        end else case (svcs)
            0: if (dut.sd_sec_read && !srd_d) begin
                   sec_addr = dut.sd_sec_read_addr; bidx = 0; tv = 0; svcs <= 1;
                   svc_valid <= 0; svc_end <= 0;
               end
            1: if (tv >= 40) begin tv <= 0; svcs <= 2; end else tv <= tv + 1;
            2: begin
                   svc_valid <= 1'b0;                       // 1 拍/字节脉冲（本拍无字节则 0）
                   if (tv == TPX - 1) begin
                       tv <= 0;
                       svc_valid <= 1'b1; svc_end <= 1'b0;
                       svc_byte  <= byte_at(sec_addr, bidx);
                       if (bidx >= 511) begin bidx <= 512; svcs <= 3; end
                       else bidx <= bidx + 1;
                   end else tv <= tv + 1;
               end
            3: begin svc_valid <= 0; svc_end <= 1; svcs <= 4; end
            4: begin svc_end <= 0; if (!dut.sd_sec_read) svcs <= 0; end
            default: svcs <= 0;
        endcase
    end

    // ------------------------------------------------------------------ 观察/驱动
    integer checks = 0, fails = 0;
    task ck; input [8*48-1:0] nm; input ok;   // 名字必须 ASCII、≤48 字符
        begin checks=checks+1;
              if (!ok) begin fails=fails+1; $display("FAIL %0s", nm); $fflush; end
              else     $display("PASS %0s", nm); $fflush;
        end
    endtask

    integer cyc = 0;
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (cyc % 10_000_000 == 0) begin
            $display("[%0t] PROGRESS cyc=%0d beats=%0d ovf=%0d tg=%0d stall=%0d busy=%b st=%0d | pulse=%b sds=%b wds=%b ltc=%0d retry=%b tgl=%b",
                     $time, cyc, u_ffw.beats, u_ffw.overflow, u_ffw.toggles,
                     dut.stall_cnt, dut.load_busy, dut.bmp_read_m0.state,
                     dut.write_finish_pulse, dut.source_done_seen, dut.write_done_seen,
                     dut.load_timeout_cnt, dut.retry_req, ffw_tgl);
            $fflush;
        end
    end

    task pulse_next;
        begin
            @(negedge clk); soft_next_r = 1;
            repeat (3) @(negedge clk); soft_next_r = 0;   // ≥3 拍高：3FF+沿检出
            repeat (10) @(posedge clk);
        end
    endtask

    // 一次完整装载。abrt>0：1280×720 流到第 abrt 扇区时 force load_abort 撕帧，
    // 换 320×240 文件，等重扫→自动装载→提交。
    integer stall0, tg0, ovf0, last_beats, abort_fired;
    task run_load; input integer w, h, cap, abrt;
        integer t, ok, cap2;
        begin
            set_file(w, h);
            stall0 = dut.stall_cnt; tg0 = u_ffw.toggles; ovf0 = u_ffw.overflow;
            pulse_next;                                  // 首图分支会顺带清 pending，L1 无害
            ok = 0;
            for (t = 0; t < 200_000 && !ok; t = t + 1) begin
                @(posedge clk); if (dut.load_busy) ok = 1;
            end
            ck("load started", ok == 1);
            abort_fired = 0; t = 0;
            while (dut.load_busy && t < cap) begin
                @(posedge clk); t = t + 1;
                if (abrt > 0 && !abort_fired && dut.load_busy &&
                    dut.bmp_read_m0.sd_sec_read_addr >= FILE_SEC + abrt) begin
                    abort_fired = 1;
                    $display("[%0t] L4: torn-frame force load_abort @addr=%0d beats=%0d",
                             $time, dut.bmp_read_m0.sd_sec_read_addr, u_ffw.beats);
                    force dut.load_abort = 1'b1;
                    @(posedge clk); @(posedge clk); @(posedge clk);
                    release dut.load_abort;
                    set_file(320, 240);   // 撕帧后换图：重扫读新头 → 首图自动装载 320×240
                end
            end
            if (abort_fired) begin
                ok = 0;
                for (t = 0; t < 500_000 && !ok; t = t + 1) begin
                    @(posedge clk); if (dut.load_busy) ok = 1;
                end
                ck("L4 re-load kicked (rescan->first image)", ok == 1);
                cap2 = 320*240*3*TPX + 60_000_000; t = 0;
                while (dut.load_busy && t < cap2) begin @(posedge clk); t = t + 1; end
            end
            last_beats = u_ffw.beats;
            ck("commit (load_busy fell, stall unchanged)",
               !dut.load_busy && dut.stall_cnt == stall0 && t < cap);
        end
    endtask

    initial begin
        repeat (10) @(posedge clk); rst <= 0;
        repeat (20) @(posedge clk); sim_sd_init = 1;      // SD 栈"初始化完成"
        repeat (20) @(posedge clk);
        // ---------------- L1 锚：640×480 921,654B（pass 路）----------------
        $display("[%0t] L1 anchor 640x480 bytes=%0d TPX=%0d", $time, 54+3*640*480, TPX);
        run_load(640, 480, 921654*TPX + 60_000_000, 0);
        ck("L1 display_valid=1", dut.display_valid === 1'b1);
        ck("L1 beats==307200 (pass 1:1)", last_beats == 307200);
        ck("L1 toggle+1", u_ffw.toggles == tg0 + 1);
        ck("L1 overflow==0", u_ffw.overflow == ovf0);
        ck("L1 stall_cnt==0", dut.stall_cnt == 8'd0);
        // ---------------- L2 链A：1280×720 真 2,764,854B ----------------
        $display("[%0t] L2 chain-A 1280x720 bytes=%0d est=%0d cyc", $time, 54+3*1280*720, (54+3*1280*720)*TPX);
        run_load(1280, 720, 2764854*TPX + 60_000_000, 0);
        ck("L2 beats==307200", last_beats == 307200);
        ck("L2 toggle+1", u_ffw.toggles == tg0 + 1);
        ck("L2 stall_cnt==0 chainA gated", dut.stall_cnt == 8'd0);
        // ---------------- L3 链B：640×200（旧 !e_band 短直通→永不 toggle）----------------
        $display("[%0t] L3 chain-B 640x200 bytes=%0d", $time, 54+3*640*200);
        run_load(640, 200, 384054*TPX + 60_000_000, 0);
        ck("L3 beats==307200 (no short bypass)", last_beats == 307200);
        ck("L3 toggle+1 write_finish seen", u_ffw.toggles == tg0 + 1);
        ck("L3 overflow==0", u_ffw.overflow == ovf0);
        ck("L3 stall_cnt==0", dut.stall_cnt == 8'd0);
        // ---------------- L3b 链B越界：1280×360（旧直通 460,800 字越界写）----------------
        $display("[%0t] L3b chain-B overrun 1280x360 bytes=%0d", $time, 54+3*1280*360);
        run_load(1280, 360, 1382454*TPX + 60_000_000, 0);
        ck("L3b overflow==0 no 307200 overrun", u_ffw.overflow == ovf0);
        ck("L3b toggle+1", u_ffw.toggles == tg0 + 1);
        ck("L3b stall_cnt==0", dut.stall_cnt == 8'd0);
        // ---------------- L4 链C：半帧 1280×720 撕帧 → 320×240 完整重装 ----------------
        $display("[%0t] L4 chain-C torn 1280x720 -> 320x240", $time);
        run_load(1280, 720, 2764854*TPX + 60_000_000, 300);
        ck("L4 abort fired", abort_fired == 1);
        ck("L4 frame2 beats==307200 sov-restart", last_beats == 307200);
        ck("L4 stall_cnt==0 torn self-heal", dut.stall_cnt == 8'd0);
        // ---------------- 收尾探针（层级引用打印）----------------
        $display("PROBES: stall_cnt=%0d sig=%h hist=%h state=%0d list_cnt=%0d img_idx=%0d",
                 dut.stall_cnt, dut.stall_sig_now, dut.stall_hist1, dut.state_code,
                 dut.list_cnt_o, dut.img_idx);
        $display("PROBES: ffw acks=%0d toggles=%0d final_beats=%0d overflow=%0d",
                 u_ffw.acks, u_ffw.toggles, u_ffw.beats, u_ffw.overflow);
        $display("SUMMARY (v103_load, TPX=%0d): checks=%0d fails=%0d", TPX, checks, fails);
        $finish;
    end

    initial begin
        #25_000_000_000;   // 25s 全局保险丝（TPX=60 全程 ≈3.5s 仿真时间，最坏全挂 ≈6.5s）
        $display("GLOBAL TIMEOUT");
        fails = fails + 1;
        $display("SUMMARY (v103_load, TPX=%0d): checks=%0d fails=%0d (global timeout)", TPX, checks, fails);
        $finish;
    end
endmodule
