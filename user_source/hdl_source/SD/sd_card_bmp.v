// ============================================================================
// === 集成给主线的话（WP-K · 播控 v10：动感画报 32 帧 + 卡死黑匣子）===
//
// 本版在 v7.4 基础上增量升级（三件事）：
//   需求一：扫描/扇区表由 7 张扩到 32 张（img_sector0..31）。
//           !! 关键约束（TD 必读）!! bmp_read.v 的 .scan_target_count 与
//           .scan_found_total 都是 3bit（物理上限 7），且 bmp_read.v 属禁碰域，
//           因此单趟扫描物理上最多只回调 7 张。32 帧靠"播放器侧链式续扫"实现：
//           本模块把 .scan_start_sector 由常量改为受控寄存器（scan_start_sector_r），
//           SCAN32 时先扫前 7 张，扫完（scan_done 上升沿）后以
//           (上一张已存图扇区+1) 为起点、目标仍 7 张，续扫下一批，最多 5 趟。
//           续扫起点严格 > 已存所有扇区，扫到的每张必是新图（BMP 头 8 字段联合
//           判据，误命中概率极低），故无需去重；单趟无新增即判"卡已扫尽"终止链。
//           SCAN4 / SCAN7 走单趟老路，行为零回归（链式仅在 scan_wanted>7 时武装）。
//   需求二：VID <0-32> 动感画报模式（见下 prm 表 + 兑现块注释）。
//   需求三：卡死黑匣子 4 个新输出（stall_sig_now/stall_hist1/stall_hist2/stall_cnt）。
//
// prm_* 参数通道（msg_ink -> 播放器，toggle+3FF 同步；prm_code[3:0]）：
//   1=SPD 2=T 3=PLY 4=PLYALL 5=SCAN4 6=SCAN7
//   7=SCAN32（新增：链式扫 32 张）   8=VID（新增：动感画报，prm_b=帧数 0..32）
//   9..15 空闲
//
// 新增 output 端口（顶层加同名 wire 接 msg_ink 新同名 input）：
//   [7:0] stall_sig_now  最近一次 stall 签名 {bmp状态4b,源完1b,写完1b,2'b00}
//   [7:0] stall_hist1    上上次 stall 签名
//   [7:0] stall_hist2    上上上次 stall 签名
//   [7:0] stall_cnt      累计 stall 次数（8bit 饱和 255）
//   —— 三者均在 timeout / v7.3a watchdog 升级重扫的分支里 3 级流水锁存；rst 清零
//      （诊断历史跨"重扫"保留、跨"复位"清零——复位=重新上电/重烧，语义上应归零）。
// ============================================================================

module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    // v5d: 软件播控注入（高电平有效，来自顶层 300ms 整形脉冲，旁路物理键抖动链路）
    input                       soft_next_btn,
    input                       soft_auto_btn,
    input                       soft_prev_btn,       // v10.2: PREV 注入（顶层 press3）
    // v7 WP-E: msg_ink -> 播放器参数通道（准静态数据 + toggle，本域 3FF 自同步）
    input                       prm_tgl,
    input  [3:0]                prm_code,
    input  [3:0]                prm_a,
    input  [7:0]                prm_b,
    // v10.2 LIST?: 候选名单回读（准静态，msg_ink 读走拼 "L cc ii dd" 回执）
    output     [5:0]            list_cnt_o,
    output     [5:0]            list_depth_o,
    output     [4:0]            list_cur_o,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    // v10.3 扩展3：多分辨率缩放支撑（bmp_read 透传；multi_res=0 时行为逐位不变）
    input                       multi_res,
    output      [15:0]          real_w, real_h,
    output                      pix_sov, pix_eov,
    // v12 (B3-lite): 缩放器源侧限流请求（透传 bmp_read.pause）
    input                       pause,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO,

    // v5f diag: {scan_done, auto_en, src_done, wr_done, disp_valid, load_busy, img_idx[1:0]}
    //   卡死分诊（冻结期直接判读）：
    //     load_busy=1 & src_done=0                 -> 源未送完：SPI/SD 卡读流挂起（卡侧/命令侧）
    //     load_busy=1 & src_done=1 & wr_done=0     -> 写帧完成脉冲缺失：SDRAM 写通路/frame_fifo_write 未走到 S_END
    //     load_busy=1 & src_done=1 & wr_done=1     -> 理应提交显示；若持续为真属第三种未知死锁
    //   （v5c 的 key1_lvl/key2_lvl 两位用于排查旧消抖锁死 bug，该 bug 已修复，此两位让给握手内部量）
    output      [7:0]           dbg_o,

    // v10 需求三：卡死黑匣子（timeout/watchdog 升级分支锁存，rst 清零）
    output reg  [7:0]           stall_sig_now,
    output reg  [7:0]           stall_hist1,
    output reg  [7:0]           stall_hist2,
    output reg  [7:0]           stall_cnt
);
// key level "oscilloscope": 2FF sample of the raw (synced) key wires
reg S_k1_1d, S_k1_2d, S_k2_1d, S_k2_2d;
always @(posedge clk or posedge rst) begin
    if (rst) begin S_k1_1d <= 1'b1; S_k1_2d <= 1'b1; S_k2_1d <= 1'b1; S_k2_2d <= 1'b1; end
    else begin
        S_k1_1d <= key_next; S_k1_2d <= S_k1_1d;
        S_k2_1d <= key_auto; S_k2_2d <= S_k2_1d;
    end
end
// v7: img_idx 加宽为 3bit（最多 7 张），dbg_o 位布局保持不变，仍只取低 2bit
// v10: img_idx 再宽到 5bit（最多 32 张），dbg_o 布局不动（仍取 [1:0]，向后兼容分诊）
assign dbg_o = {scan_done, auto_play_en, source_done_seen, write_done_seen,
                display_valid, load_busy, img_idx[1:0]};   // 正常位图

// ---------------------------------------------------------------------------
// v7 WP-E: 物理键根治前端（整体替换旧 key_press_debounce，旧模块已删除）
//   板上事实：PULLUP，空闲=0，按下=1（高有效）。
//   时序：raw -> 2FF 同步 -> 连续高 5ms(19'd500_000@100M) 发 1 拍事件并置 armed；
//         armed 后须连续低 5ms 才解除（一次按压只发一发，抖动全被 5ms 稳定窗吃掉）。
//   语义与软键一致（按下瞬间触发），在既有两处消费点 OR。
// ---------------------------------------------------------------------------
reg        k1_s1, k1_s2, k1_armed;
reg [18:0] k1_hcnt, k1_lcnt;
reg        key1_evt;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        k1_s1    <= 1'b0;
        k1_s2    <= 1'b0;
        k1_armed <= 1'b0;
        k1_hcnt  <= 19'd0;
        k1_lcnt  <= 19'd0;
        key1_evt <= 1'b0;
    end else begin
        k1_s1    <= key_next;
        k1_s2    <= k1_s1;
        key1_evt <= 1'b0;
        if (k1_s2) begin
            k1_lcnt <= 19'd0;
            if (!k1_armed) begin
                if (k1_hcnt >= 19'd500_000) begin
                    k1_hcnt  <= 19'd0;
                    k1_armed <= 1'b1;
                    key1_evt <= 1'b1;
                end else begin
                    k1_hcnt <= k1_hcnt + 19'd1;
                end
            end
        end else begin
            k1_hcnt <= 19'd0;
            if (k1_armed) begin
                if (k1_lcnt >= 19'd500_000)
                    k1_armed <= 1'b0;
                else
                    k1_lcnt <= k1_lcnt + 19'd1;
            end else begin
                k1_lcnt <= 19'd0;
            end
        end
    end
end

reg        k2_s1, k2_s2, k2_armed;
reg [18:0] k2_hcnt, k2_lcnt;
reg        key2_evt;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        k2_s1    <= 1'b0;
        k2_s2    <= 1'b0;
        k2_armed <= 1'b0;
        k2_hcnt  <= 19'd0;
        k2_lcnt  <= 19'd0;
        key2_evt <= 1'b0;
    end else begin
        k2_s1    <= key_auto;
        k2_s2    <= k2_s1;
        key2_evt <= 1'b0;
        if (k2_s2) begin
            k2_lcnt <= 19'd0;
            if (!k2_armed) begin
                if (k2_hcnt >= 19'd500_000) begin
                    k2_hcnt  <= 19'd0;
                    k2_armed <= 1'b1;
                    key2_evt <= 1'b1;
                end else begin
                    k2_hcnt <= k2_hcnt + 19'd1;
                end
            end
        end else begin
            k2_hcnt <= 19'd0;
            if (k2_armed) begin
                if (k2_lcnt >= 19'd500_000)
                    k2_armed <= 1'b0;
                else
                    k2_lcnt <= k2_lcnt + 19'd1;
            end else begin
                k2_lcnt <= 19'd0;
            end
        end
    end
end

// 软按键电平 -> 本域两拍同步 + 上升沿事件（与消抖输出同宽同性质，OR 进事件源）
reg S_sn1, S_sn2, S_sn3, S_sa1, S_sa2, S_sa3, S_sp1, S_sp2, S_sp3;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        S_sn1 <= 1'b0; S_sn2 <= 1'b0; S_sn3 <= 1'b0;
        S_sa1 <= 1'b0; S_sa2 <= 1'b0; S_sa3 <= 1'b0;
        S_sp1 <= 1'b0; S_sp2 <= 1'b0; S_sp3 <= 1'b0;
    end else begin
        S_sn1 <= soft_next_btn; S_sn2 <= S_sn1; S_sn3 <= S_sn2;
        S_sa1 <= soft_auto_btn; S_sa2 <= S_sa1; S_sa3 <= S_sa2;
        S_sp1 <= soft_prev_btn; S_sp2 <= S_sp1; S_sp3 <= S_sp2;   // v10.2
    end
end
wire soft_next_press = ~S_sn3 & S_sn2;
wire soft_auto_press = ~S_sa3 & S_sa2;
wire soft_prev_press = ~S_sp3 & S_sp2;   // v10.2: PREV 上升沿事件

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;   // bmp_read 3bit 输出（本趟计数，单趟<=7），链式续扫时忽略其跨趟值

reg              scan_start_pulse;
// ---- v10.1d: SD 协议栈自愈软复位 ----
//   病灶(XRAY6 实锤)：卡/ SPI 瞬态丢应答时，下层 sd_card_sec_read_write 永停 S_READ 等
//   ack（该层无超时），bmp 的 load_abort 复位不到它 -> 续扫/重扫永远停在首扇区 (st=2,ready=0)。
//   判据：sd_init 完成 + 引擎忙 + 无加载在途 + 已发起扫描且未完成，持续 4s（正常单趟扫描
//   含 8192 止损尾 <=2.5s，余量 60%）。动作：对 bmp_read+sd_card_top 整栈 8 拍软复位 ->
//   卡重初始化 -> boot kick 自动重扫重建候选表 -> 首图加载无缝恢复（display_valid 不清，画面不黑）。
reg  [28:0]      sd_stuck_cnt;
reg  [3:0]       sd_sr_len;
reg              sd_soft_rst;
wire             sd_rst_w = rst | sd_soft_rst;   // 仅供 bmp_read / sd_card_top 两实例
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg [23:0]       load_gap_cnt;   // v12.8: 提交/失败后冷却，避免换图瞬间写口抢读口
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [31:0]       auto_target;         // v7: 当前显示图的自动翻页计数终点（秒数 x 100M）
reg [5:0]        img_found_count;     // v10: 0..32 累计已扫到并存的张数
reg [4:0]        img_idx;              // 当前真正显示中的图片编号（v10: 0..31）
reg [4:0]        load_idx;             // 当前正在写入的图片编号（v10: 0..31）
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg [31:0]       img_sector4;
reg [31:0]       img_sector5;
reg [31:0]       img_sector6;
reg [31:0]       img_sector7;
reg [31:0]       img_sector8;          // v10: 动感画报 32 帧槽位（8..31 由链式续扫填充）
reg [31:0]       img_sector9;
reg [31:0]       img_sector10;
reg [31:0]       img_sector11;
reg [31:0]       img_sector12;
reg [31:0]       img_sector13;
reg [31:0]       img_sector14;
reg [31:0]       img_sector15;
reg [31:0]       img_sector16;
reg [31:0]       img_sector17;
reg [31:0]       img_sector18;
reg [31:0]       img_sector19;
reg [31:0]       img_sector20;
reg [31:0]       img_sector21;
reg [31:0]       img_sector22;
reg [31:0]       img_sector23;
reg [31:0]       img_sector24;
reg [31:0]       img_sector25;
reg [31:0]       img_sector26;
reg [31:0]       img_sector27;
reg [31:0]       img_sector28;
reg [31:0]       img_sector29;
reg [31:0]       img_sector30;
reg [31:0]       img_sector31;
reg [31:0]       dur_flat;             // v7: 8 x 4bit 秒数（图 0..6 用 nibble 0..6，nibble7 闲置）
reg [31:0]       play_mask;            // v7:8bit PLY → v10.2: 加宽 32bit（PLY 仍低 8 位，RNG 可达 bit17）
reg              scan_done_d2;         // v10.3b-18: prm 块内 scan_done 上升沿检测（扫完自动放开池）
reg              ply_locked;           // v10.3b-18: 用户手工选曲(PLY/PLYALL/RNG)后置 1，防扫描落定踩脚；重扫类命令清 0
reg [2:0]        scan_target_r;        // v10: bmp_read 单趟目标深度（3bit 物理上限 7）
reg [5:0]        scan_wanted;          // v10/v10.2: 期望总张数 1..32（SCAN n 可定义，旧档 4/7/32）（链式续扫的终止条件）
reg              scan_cont_active;     // v10: 链式续扫进行中
reg [31:0]       scan_start_sector_r;  // v10: 喂给 bmp_read .scan_start_sector（链式续扫可改）
reg [31:0]       scan_cont_start;      // v10: 下一趟续扫起点 = 上一张已存图扇区 +1
reg [31:0]       last_stored_sector;   // v10: 本表最新写入的扇区号（续扫起点基准）
reg [5:0]        scan_pass_before;     // v10: 本趟开始前 img_found_count（无新增=卡已扫尽）
reg              scan_done_d;          // v10: scan_done 打一拍，捕获每趟完成上升沿
reg              prm_rekick;           // v7: SCAN7/SCAN32 应用拍脉冲（主 FSM 用它清 scan_kicked 触发自愈重扫）
reg              prm_dur_touch;        // v7: SPD/T 应用拍脉冲（auto_target 块据此重取终点）
reg              vid_en;               // v10 需求二：动感画报模式开关
reg [5:0]        vid_n;                // v10 需求二：VID 帧数 0..32
reg              next_req_pending;
reg              prev_req_pending;       // v10.2: PREV 意图锁存（与 next 同构）
reg              auto_tgl_pending;      // v7.1: AUTO 翻转意图锁存（穿越重扫窗口存活，scan_done&&two_or_more 时兑现）
reg              load_busy;
reg [31:0]       load_timeout_cnt;
reg              bmp_ready_d;          // v5f: bmp_ready 打一拍，用于捕获"本次加载真正读完源后回 IDLE"的上升沿

reg              load_abort;
// v7.3: stall recovery WITHOUT black screen. On load timeout first silently
// reload the SAME image (up to 2 tries; display + sector table untouched).
// Only when retries are exhausted fall back to the legacy load_abort kick
// (full FAT rescan, ~1.6s blank). Normal loads finish in ~0.55s, so the
// timeout shrinks 3s -> 0.8s (still ~45% margin) to cap the freeze window.
// v10 注：超时阈值与重试语义一字未动（探针先行，等主线拿到签名数据再评估）。
reg              retry_req;
reg [1:0]        retry_cnt;
reg [24:0]       retry_wait;    // v7.3a watchdog: bmp stuck (never ready) 0.3s

// bmp_ready 先表示"源文件读取/送 FIFO 完成"；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

// v7 WP-E: prm_* 准静态参数通道同步链（tgl 3FF + 异或沿；数据 2FF，边沿沿到时必已稳定）
reg [2:0]        prm_tgl_sync;
reg [3:0]        prm_code_r1, prm_code_r2;
reg [3:0]        prm_a_r1,    prm_a_r2;
reg [7:0]        prm_b_r1,    prm_b_r2;
wire             prm_edge;
reg [4:0]        img_idx_d;

wire             auto_tick;
wire             auto_effective;       // v10: auto_play_en | vid_en（VID 强制自动播）
wire [31:0]      avail_set;            // v10: 候选集位图（PLY: play_mask 低 8 位 & 已扫到位图；VID: 低 n 位 & 已扫到位图）
wire [31:0]      cur_mask32;           // v10: 掩码源（PLY 8bit 展宽 / VID 低 n 位）
wire             two_or_more;          // 候选集 >=2 置位（Verilog-2001 无 $countones 的等价判据）
wire [4:0]       next_from_current;
wire [4:0]       prev_from_current;     // v10.2: 显式声明！隐式 1bit 截断曾把 3 变 1（板上 0->1 之谜）
wire [4:0]       first_from_avail;
wire [7:0]       cur_sig;              // v10: 当前 stall 签名组合（timeout/watchdog 分支锁存）

assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign auto_tick  = (auto_cnt >= (auto_target - 32'd1));
assign two_or_more = (avail_set != 32'd0) && ((avail_set & (avail_set - 32'd1)) != 32'd0);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign prm_edge           = prm_tgl_sync[2] ^ prm_tgl_sync[1];
assign state_code = state_code_i;
// v10 需求二：VID 打开即等效自动播放（不改 auto_play_en 本身，保证单写者）
assign auto_effective = auto_play_en | vid_en;
// v10 需求三：签名组合 {bmp状态4b, 源完1b, 写完1b, 2'b00}
assign cur_sig = {state_code_i, source_done_seen, write_done_seen, 2'b00};

function [31:0] sector_lut;
    input [4:0] idx;
    begin
        case (idx)
            4'd0:    sector_lut = img_sector0;
            4'd1:    sector_lut = img_sector1;
            4'd2:    sector_lut = img_sector2;
            4'd3:    sector_lut = img_sector3;
            4'd4:    sector_lut = img_sector4;
            4'd5:    sector_lut = img_sector5;
            4'd6:    sector_lut = img_sector6;
            4'd7:    sector_lut = img_sector7;
            4'd8:    sector_lut = img_sector8;
            4'd9:    sector_lut = img_sector9;
            4'd10:   sector_lut = img_sector10;
            4'd11:   sector_lut = img_sector11;
            4'd12:   sector_lut = img_sector12;
            4'd13:   sector_lut = img_sector13;
            4'd14:   sector_lut = img_sector14;
            4'd15:   sector_lut = img_sector15;
            5'd16:   sector_lut = img_sector16;
            5'd17:   sector_lut = img_sector17;
            5'd18:   sector_lut = img_sector18;
            5'd19:   sector_lut = img_sector19;
            5'd20:   sector_lut = img_sector20;
            5'd21:   sector_lut = img_sector21;
            5'd22:   sector_lut = img_sector22;
            5'd23:   sector_lut = img_sector23;
            5'd24:   sector_lut = img_sector24;
            5'd25:   sector_lut = img_sector25;
            5'd26:   sector_lut = img_sector26;
            5'd27:   sector_lut = img_sector27;
            5'd28:   sector_lut = img_sector28;
            5'd29:   sector_lut = img_sector29;
            5'd30:   sector_lut = img_sector30;
            default: sector_lut = img_sector31;
        endcase
    end
endfunction

// v10: 从 cur 起沿环找 avail 中距 cur 最近的下一置位（1..31 步）；无其它置位返回 cur。
//   常量界 31 次展开循环，等价旧 7 级 case 写法（TD 铁律：只读 avail 位 + 寄存器，零 RAM）。
    // ==== 对数树公共件（tb_masktree 110787 对拍穷举等价 sd_card_bmp v10.3b16 原函数）====
    // rot_self[i] = avail[(cur+i) mod 32]（bit0=cur 自己）；64 位桶形移位一级 5 选 1
    function [31:0] rot_self;
        input [4:0]  cur;
        input [31:0] avail;
        reg   [63:0] dbl;
        begin
            dbl      = {avail, avail};
            rot_self = (dbl >> {2'd0, cur}) & 32'hFFFF_FFFF;
        end
    endfunction
    // one-hot -> 5bit 下标：5 级二分树（输入必须至多 1 位为 1；全 0 返回 0）
    function [4:0] onehot_idx;
        input [31:0] low;
        reg   b4, b3, b2, b1, b0;
        reg [15:0] h4;
        reg  [7:0] h3;
        reg  [3:0] h2;
        reg  [1:0] h1;
        begin
            b4 = |low[31:16]; h4 = b4 ? low[31:16] : low[15:0];
            b3 = |h4[15:8];   h3 = b3 ? h4[15:8]   : h4[7:0];
            b2 = |h3[7:4];    h2 = b2 ? h3[7:4]    : h3[3:0];
            b1 = |h2[3:2];    h1 = b1 ? h2[3:2]    : h2[1:0];
            b0 = h1[1];
            onehot_idx = {b4, b3, b2, b1, b0};
        end
    endfunction
    // 最高置位 -> 5bit 下标：同一棵二分树反着走（全 0 返回 0）
    function [4:0] highbit_idx;
        input [31:0] v;
        reg   b4, b3, b2, b1, b0;
        reg [15:0] h4;
        reg  [7:0] h3;
        reg  [3:0] h2;
        reg  [1:0] h1;
        begin
            b4 = |v[31:16]; h4 = b4 ? v[31:16] : v[15:0];
            b3 = |h4[15:8]; h3 = b3 ? h4[15:8] : h4[7:0];
            b2 = |h3[7:4];  h2 = b2 ? h3[7:4]  : h3[3:0];
            b1 = |h2[3:2];  h1 = b1 ? h2[3:2]  : h2[1:0];
            b0 = h1[1];
            highbit_idx = {b4, b3, b2, b1, b0};
        end
    endfunction

function [4:0] next_masked;
    input [4:0]  cur;
    input [31:0] avail;
    reg [31:0] m;
    reg [4:0]  d;
    reg [5:0]  s;
    begin
        m = rot_self(cur, avail) & 32'hFFFF_FFFE;   // 去掉 bit0=自己
        if (m == 32'd0) next_masked = cur;          // 环上无其它置位
        else begin
            d = onehot_idx(m & (~m + 32'd1));       // 最低置位 = 环上最近后继距离
            s = {1'b0, cur} + {1'b0, d};
            if (s >= 6'd32) s = s - 6'd32;
            next_masked = s[4:0];
        end
    end
endfunction

// v10: avail 中最低位置位（首图/重扫提交起点）；无置位返回 0（调用点保证 avail!=0）
function [4:0] first_masked;
    input [31:0] avail;
    begin
        first_masked = onehot_idx(avail & (~avail + 32'd1));  // 最低置位（全0返回0=原语义）
    end
endfunction

// v10.2: next_masked 的镜像——沿环找 avail 中距 cur 最近的上一置位（1..31 步）；
//   无其它置位返回 cur。常量界展开，同 TD 铁律（只读 avail 位 + 寄存器，零 RAM）。
function [4:0] prev_masked;
    input [4:0]  cur;
    input [31:0] avail;
    reg [31:0] m;
    reg [4:0]  d;
    reg [5:0]  s;
    begin
        m = rot_self(cur, avail) & 32'hFFFF_FFFE;   // 去掉 bit0=自己
        if (m == 32'd0) prev_masked = cur;
        else begin
            d = highbit_idx(m);                     // 绕环最高 = 逆序最近前驱
            s = {1'b0, cur} + {1'b0, d};
            if (s >= 6'd32) s = s - 6'd32;
            prev_masked = s[4:0];
        end
    end
endfunction

// v10: 已扫到张数(0..32) -> 低 c 位置 1 的 32bit 位图（常量界循环，可综合）
function [31:0] count_to_bits;
    input [5:0] c;
    integer     k;
    reg [31:0]  m;
    begin
        m = 32'd0;
        for (k = 0; k < 32; k = k + 1)
            if ({1'b0, k[4:0]} < c) m[k] = 1'b1;
        count_to_bits = m;
    end
endfunction

// v7: 取某图当前秒数 nibble（TD 铁律：平铺向量 + case 读）
// v10: idx 宽到 4bit；T<0-6> 语义不变，图 7..31 无独立定时 -> 走 default(全局 nibble0)。
function [3:0] dur_nib_lut;
    input [4:0] idx;
    begin
        case (idx)
            5'd0:    dur_nib_lut = dur_flat[3:0];
            5'd1:    dur_nib_lut = dur_flat[7:4];
            5'd2:    dur_nib_lut = dur_flat[11:8];
            5'd3:    dur_nib_lut = dur_flat[15:12];
            5'd4:    dur_nib_lut = dur_flat[19:16];
            5'd5:    dur_nib_lut = dur_flat[23:20];
            5'd6:    dur_nib_lut = dur_flat[27:24];
            default: dur_nib_lut = dur_flat[3:0];   // 图 7..31：无独立定时，回落全局秒数（VID 模式则整体被 30M 覆盖）
        endcase
    end
endfunction

// v7: 秒数 -> 100MHz 计数终点（常数 case，不用乘法器；9 秒=900M < 2^32）
function [31:0] sec_to_ticks;
    input [3:0] sec;
    begin
        case (sec)
            4'd1:    sec_to_ticks = 32'd100_000_000;
            4'd2:    sec_to_ticks = 32'd200_000_000;
            4'd3:    sec_to_ticks = 32'd300_000_000;
            4'd4:    sec_to_ticks = 32'd400_000_000;
            4'd5:    sec_to_ticks = 32'd500_000_000;
            4'd6:    sec_to_ticks = 32'd600_000_000;
            4'd7:    sec_to_ticks = 32'd700_000_000;
            4'd8:    sec_to_ticks = 32'd800_000_000;
            4'd9:    sec_to_ticks = 32'd900_000_000;
            default: sec_to_ticks = 32'd100_000_000;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

// v10: 候选集/轮播目标的组合输出（放在所用函数定义之后，先声明后使用）
assign cur_mask32      = vid_en ? count_to_bits(vid_n) : play_mask;   // v10.2: play_mask 加宽 32bit
assign avail_set       = cur_mask32 & count_to_bits(img_found_count);
assign next_from_current = next_masked(img_idx, avail_set);
assign prev_from_current = prev_masked(img_idx, avail_set);           // v10.2: PREV
assign first_from_avail  = first_masked(avail_set);
// v10.2 LIST? 回读（寄存器直出，准静态；msg_ink 跨域读取同 stall_* 先例）
assign list_cnt_o   = img_found_count;
assign list_depth_o = scan_wanted;
assign list_cur_o   = img_idx;

// v10.1c: 链式续扫"武装"组合线——本拍扫描完成沿且链 FSM 将发起下一趟续扫时=1。
//   LOAD 各发起分支必须同拍让路（否则同拍 scan_cont_active 旧值仍=0，first_image/retry
//   会抢先把 bmp 抓去 LOAD，下一拍续扫脉冲撞上非空闲引擎 -> 被吞 -> v10.1a 冻结根因）。
wire chain_arming = scan_done && !scan_done_d && (scan_wanted > 6'd7)
                  && (img_found_count < scan_wanted) && (img_found_count != scan_pass_before);

// ---------------------------------------------------------------------------
// v7 WP-E: 参数通道应用块（dur_flat/play_mask/scan_target_r/vid_en/vid_n 唯一驱动者）
//   铁律：全部平铺向量 + unrolled 写 case；对主 FSM 的所有权只经由
//   prm_dur_touch/prm_rekick 两个单拍脉冲信号，绝无多驱动。
//   v10.1a: scan_cont_active 移出本块（HDL-8007 多驱动修复）——本块对它的
//   4 处赋值全是清零，其真实生命周期归主 FSM 独占；清锁动作改由主 FSM
//   直接感知 (prm_edge && code==SCAN4/7/32)。本块不再出现该信号。
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        prm_tgl_sync  <= 3'b000;
        prm_code_r1   <= 4'd0;
        prm_code_r2   <= 4'd0;
        prm_a_r1      <= 4'd0;
        prm_a_r2      <= 4'd0;
        prm_b_r1      <= 8'd0;
        prm_b_r2      <= 8'd0;
        dur_flat      <= 32'h1111_1111;   // 每图默认 1 秒
        play_mask     <= 8'h0F;           // 默认前 4 张（= 默认 4 张扫描全放行）
        scan_done_d2  <= 1'b0;            // v10.3b-18
        ply_locked    <= 1'b0;            // v10.3b-18
        scan_target_r <= SCAN_TARGET_COUNT;
        scan_wanted   <= {3'd0, SCAN_TARGET_COUNT};
        prm_rekick    <= 1'b0;
        prm_dur_touch <= 1'b0;
        vid_en        <= 1'b0;            // v10 需求二
        vid_n         <= 6'd0;            // v10 需求二
    end else begin
        prm_tgl_sync  <= {prm_tgl_sync[1:0], prm_tgl};
        prm_code_r1   <= prm_code;
        prm_code_r2   <= prm_code_r1;
        prm_a_r1      <= prm_a;
        prm_a_r2      <= prm_a_r1;
        prm_b_r1      <= prm_b;
        prm_b_r2      <= prm_b_r1;
        prm_rekick    <= 1'b0;
        prm_dur_touch <= 1'b0;

        if (prm_edge) begin
            case (prm_code_r2)
                4'd1: begin                          // SPD: 全部 8 个 nibble := prm_b[3:0]
                    dur_flat <= {8{prm_b_r2[3:0]}};
                    prm_dur_touch <= 1'b1;
                end
                4'd2: begin                          // T: 仅 nibble[prm_a]（prm_a>6 已由 msg_ink 挡掉）
                    case (prm_a_r2)
                        4'd0: dur_flat[3:0]   <= prm_b_r2[3:0];
                        4'd1: dur_flat[7:4]   <= prm_b_r2[3:0];
                        4'd2: dur_flat[11:8]  <= prm_b_r2[3:0];
                        4'd3: dur_flat[15:12] <= prm_b_r2[3:0];
                        4'd4: dur_flat[19:16] <= prm_b_r2[3:0];
                        4'd5: dur_flat[23:20] <= prm_b_r2[3:0];
                        4'd6: dur_flat[27:24] <= prm_b_r2[3:0];
                        default: ;
                    endcase
                    prm_dur_touch <= 1'b1;
                end
                4'd3: begin                          // PLY: 掩码 = prm_b（bit7 由 avail 截断，天然无效）
                    play_mask <= prm_b_r2;
                    ply_locked <= 1'b1;              // v10.3b-18
                end
                4'd4: begin                          // PLYALL: 掩码 = 已扫到位图（v10.3b-18 放宽到 32，此前封 7 张）
                    play_mask <= count_to_bits(img_found_count);
                    ply_locked <= 1'b1;              // v10.3b-18
                end
                4'd5: begin                          // SCAN4（单趟；清锁 + 强制重扫）
                    scan_target_r    <= 3'd4;
                    scan_wanted      <= 6'd4;
                    ply_locked       <= 1'b0;        // v10.3b-18: 重扫=换片，池交还给自动放行
                    prm_rekick       <= 1'b1;        // v12.4: 与 SCAN7 同型重扫。原 SCAN4 不
                                                     //   rekick：PLYALL(count=0) 把 play_mask
                                                     //   清零后，已扫完的场景没有新的 scan_done
                                                     //   上升沿，首图永不加载（板测 L 04 却黑屏）。
                    if (play_mask == 32'd0)
                        play_mask    <= 32'h0F;      // 兜底：零掩码=永远 avail_set=0
                end
                4'd6: begin                          // SCAN7 + 触发自愈重扫（重扫后 img_sector* 按新深度重建）
                    scan_target_r    <= 3'd7;
                    scan_wanted      <= 6'd7;
                    prm_rekick       <= 1'b1;
                    ply_locked       <= 1'b0;        // v10.3b-18
                end
                4'd7: begin                          // v10 SCAN32：单趟 7 + 链式续扫到 32；触发一次全新重扫
                    scan_target_r    <= 3'd7;        // bmp_read 3bit 物理上限
                    scan_wanted      <= 6'd32;
                    prm_rekick       <= 1'b1;
                    ply_locked       <= 1'b0;        // v10.3b-18
                end
                4'd8: begin                          // v10 VID <0-32>
                    vid_n  <= prm_b_r2[5:0];         // msg_ink 已保证 0..32
                    vid_en <= (prm_b_r2[5:0] != 6'd0);
                    prm_dur_touch <= 1'b1;           // 让 auto_target 立即按 vid_en 重取（30M 或常规秒数）
                end
                4'd9: begin                          // v10.2: "SCAN n" 任意深度 1..32
                    //   msg_ink 已保证 prm_b∈1..32（SCAN4/7 仍走旧码 5/6，非此路）。
                    //   ≤7 单趝（bmp 物理目标=张数）；>7 单趝 7 + 链式续扫到 n。
                    scan_wanted   <= prm_b_r2[5:0];
                    scan_target_r <= (prm_b_r2[5:0] >= 6'd7) ? 3'd7 : prm_b_r2[2:0];
                    prm_rekick    <= 1'b1;
                    ply_locked    <= 1'b0;           // v10.3b-18
                end
                4'd10: begin                         // v10.2: "RNGab" 从第 a 张连播 b 张
                    //   prm_b={a[7:4], b[3:0]}，各 1..9。掩码 bit(a-1)..bit(a+b-2)。
                    //   RNG 生效即退出 VID（新语义：区间优先于画报）。
                    vid_en    <= 1'b0;
                    play_mask <= count_to_bits({2'd0, prm_b_r2[7:4]} + {2'd0, prm_b_r2[3:0]} - 6'd1)
                              &  ~count_to_bits({2'd0, prm_b_r2[7:4]} - 6'd1);
                    ply_locked <= 1'b1;              // v10.3b-18: 手工区间不被扫描落定踩脚
                end
                default: ;
            endcase
        end

        // v10.3b-18: 扫描链落定自动放开播放池——play_mask 默认 0x0F、PLYALL 旧封顶 0x7F，
        //   深扫 15 张只能播前 4（9/7 板测走查抓现行，v10.2 就有、五扩展卡第一次顶穿）。
        //   只在 scan_done 上升沿动手；用户手工 PLY/PLYALL/RNG 置 ply_locked 后不再踩脚，
        //   直到下一次 SCAN* 清锁（=换片，池重新交给自动放行）。VID 池自管（cur_mask32 走 vid_n）。
        scan_done_d2 <= scan_done;
        // v12.4: scan_done 上升沿与末张 scan_found_valid 同拍；img_found_count
        //   要下一拍才 +1，用旧值会把 play_mask 算少 1（4 张→只放行 3 张）。
        if (scan_done && !scan_done_d2 && !vid_en && !ply_locked)
            play_mask <= count_to_bits(scan_found_valid ? (img_found_count + 6'd1)
                                                        : img_found_count);
    end
end

// ---------------------------------------------------------------------------
// v7 WP-E: auto_target 独立小 FSM-less 块（唯一驱动者）
//   复位 / prm 改动时长(prm_dur_touch) / 切图(img_idx 变化) 三处刷新。
//   v10: VID 打开时终点强制 30_000_000（0.3s，独立于 SPD/dur_flat）；退出恢复常规。
//   时序：上述事件拍后下一拍生效，100M 域内与 auto_cnt 清零节拍无竞争。
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        auto_target <= 32'd100_000_000;
        img_idx_d   <= 5'd0;
    end else begin
        img_idx_d <= img_idx;
        if ((img_idx != img_idx_d) || prm_dur_touch)
            auto_target <= vid_en ? 32'd30_000_000 : sec_to_ticks(dur_nib_lut(img_idx));
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        sd_stuck_cnt          <= 29'd0;   // v10.1d
        sd_sr_len             <= 4'd0;    // v10.1d
        sd_soft_rst           <= 1'b0;    // v10.1d
        bmp_ready_d           <= 1'b0;   // v10.1b
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 6'd0;
        img_idx               <= 5'd0;
        load_idx              <= 5'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        img_sector4           <= 32'd0;
        img_sector5           <= 32'd0;
        img_sector6           <= 32'd0;
        img_sector7           <= 32'd0;
        img_sector8           <= 32'd0;
        img_sector9           <= 32'd0;
        img_sector10          <= 32'd0;
        img_sector11          <= 32'd0;
        img_sector12          <= 32'd0;
        img_sector13          <= 32'd0;
        img_sector14          <= 32'd0;
        img_sector15          <= 32'd0;
        img_sector16          <= 32'd0;
        img_sector17          <= 32'd0;
        img_sector18          <= 32'd0;
        img_sector19          <= 32'd0;
        img_sector20          <= 32'd0;
        img_sector21          <= 32'd0;
        img_sector22          <= 32'd0;
        img_sector23          <= 32'd0;
        img_sector24          <= 32'd0;
        img_sector25          <= 32'd0;
        img_sector26          <= 32'd0;
        img_sector27          <= 32'd0;
        img_sector28          <= 32'd0;
        img_sector29          <= 32'd0;
        img_sector30          <= 32'd0;
        img_sector31          <= 32'd0;
        next_req_pending      <= 1'b0;
        prev_req_pending      <= 1'b0;   // v10.2
        auto_tgl_pending      <= 1'b0;
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        retry_req             <= 1'b0;   // v7.3
        retry_wait            <= 25'd0;  // v7.3a
        retry_cnt             <= 2'd0;   // v7.3
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        load_gap_cnt          <= 24'd0;
        bmp_ready_d           <= 1'b1;
        display_valid         <= 1'b0;
        // v10 链式续扫 + 黑匣子状态复位
        scan_start_sector_r   <= SCAN_START_SECTOR;
        scan_cont_start       <= 32'd0;
        last_stored_sector    <= 32'd0;
        scan_pass_before      <= 6'd0;
        scan_done_d           <= 1'b0;
        stall_sig_now         <= 8'd0;
        stall_hist1           <= 8'd0;
        stall_hist2           <= 8'd0;
        stall_cnt             <= 8'd0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;
        bmp_ready_d      <= bmp_ready;
        scan_done_d      <= scan_done;

        // v10.1d: SD 栈自愈判据——引擎连续"忙"超 4s 即认定下层 FSM 挂死（正常单趟扫描
        //   ≤2.5s 含 8192 止损尾、单张加载 ≤0.55s，其间 bmp_ready 会拉高，4s 绝不误触）。
        //   覆盖扫描卡死(st=2/ready=0)与加载卡死(0x18)两种形态，load_abort 复不了下层，唯复位整栈可救。
        if (sd_init_done && !bmp_ready) begin
            if (sd_sec_read_data_valid) begin
                // b-17: 字节流在流动=扫描健康（FAT32 大分区图片起点可能在 15MB+ 处，
                //   4s 硬门限会把健康长扫描误杀成永远重启动回路，9/7 板测实证）。
                sd_stuck_cnt <= 29'd0;
            end else if (sd_stuck_cnt >= 29'd400_000_000) begin        // 4s @100MHz 无任何字节=真死
                sd_stuck_cnt <= 29'd0;
                sd_sr_len    <= 4'd8;
                stall_hist2  <= stall_hist1;                  // 黑匣子记一笔（签名=引擎当时的状态）
                stall_hist1  <= stall_sig_now;
                stall_sig_now<= cur_sig;
                if (stall_cnt != 8'd255) stall_cnt <= stall_cnt + 8'd1;
            end else
                sd_stuck_cnt <= sd_stuck_cnt + 29'd1;
        end else begin
            sd_stuck_cnt <= 29'd0;
        end
        if (sd_sr_len != 4'd0) begin
            sd_sr_len   <= sd_sr_len - 4'd1;
            sd_soft_rst <= 1'b1;
        end else
            sd_soft_rst <= 1'b0;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 6'd0;
            img_idx               <= 5'd0;
            load_idx              <= 5'd0;
            // v7.4: 拔卡/SD 重初始化期间不再清 display_valid 与 buf 指针——
            //   画面保留最后一张完好帧；卡回来后首图分支写另一 buffer 无缝覆盖。
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            img_sector4           <= 32'd0;
            img_sector5           <= 32'd0;
            img_sector6           <= 32'd0;
            img_sector7           <= 32'd0;
            img_sector8           <= 32'd0;
            img_sector9           <= 32'd0;
            img_sector10          <= 32'd0;
            img_sector11          <= 32'd0;
            img_sector12          <= 32'd0;
            img_sector13          <= 32'd0;
            img_sector14          <= 32'd0;
            img_sector15          <= 32'd0;
            img_sector16          <= 32'd0;
            img_sector17          <= 32'd0;
            img_sector18          <= 32'd0;
            img_sector19          <= 32'd0;
            img_sector20          <= 32'd0;
            img_sector21          <= 32'd0;
            img_sector22          <= 32'd0;
            img_sector23          <= 32'd0;
            img_sector24          <= 32'd0;
            img_sector25          <= 32'd0;
            img_sector26          <= 32'd0;
            img_sector27          <= 32'd0;
            img_sector28          <= 32'd0;
            img_sector29          <= 32'd0;
            img_sector30          <= 32'd0;
            img_sector31          <= 32'd0;
            next_req_pending      <= 1'b0;
            prev_req_pending      <= 1'b0;   // v10.2
            auto_tgl_pending      <= 1'b0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            load_abort            <= 1'b0;
            retry_req             <= 1'b0;   // v7.3
            retry_wait            <= 25'd0;  // v7.3a
            retry_cnt             <= 2'd0;   // v7.3
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            bmp_ready_d           <= 1'b1;
            // v10: 拔卡期间链式续扫状态归零，卡回来后 SCAN32 若仍期望会由 scan_done 边沿重武装
            scan_cont_active      <= 1'b0;
            scan_pass_before      <= 6'd0;
            // v7.4: display_valid 不清——拔卡/重初始化期间画面保留最后一张完好帧；
            //   上电首启时它本就是复位值 0（黑屏语义由 rst 块天然承担）。
        end else begin
            // v5d-fix1: load_abort 由"锁死"改为 1 拍脉冲（原代码置 1 后无人清零，
            //   bmp_read 会被永久按在复位分支 -> scan_done 永不再置 1 -> 播控全灭）
            load_abort <= 1'b0;
            // v5d-fix2: bmp_read 的扫描成果若被 abort/SD 重初始化清空，解除一次性
            //   扫描锁，让系统在下方 kick 分支自动重扫（自愈，约 1~2s）
            // v7: 追加 SCAN7/SCAN32 的 prm_rekick——改深度后主动重扫重建 img_sector*
            if (!sd_init_done || load_abort || prm_rekick)
                scan_kicked <= 1'b0;

            // v10: 链式续扫 FSM（仅 scan_wanted>7 时武装；SCAN4/7/32 命令到达无条件清锁）
            //   v10.1a: 本信号唯一驱动者=本 always 块（HDL-8007 修复：prm 块的同名清零
            //   已移除，清锁动作改在此处直接感知 prm_edge——与续扫边沿同拍时命令优先）。
            //   每趟 scan_done 上升沿：够数->停；本趟无新增->卡扫尽停；否则以(最新存图扇区+1)续扫。
            if (prm_edge && (prm_code_r2 == 4'd5 || prm_code_r2 == 4'd6 || prm_code_r2 == 4'd7
                             || prm_code_r2 == 4'd8
                             || prm_code_r2 == 4'd9)) begin  // v10.1c: VID(8) 也纳入清锁逃生口
                scan_cont_active <= 1'b0;
            end
            else if (scan_done && !scan_done_d && (scan_wanted > 6'd7)) begin
                if (img_found_count >= scan_wanted) begin
                    scan_cont_active <= 1'b0;
                end else if (img_found_count == scan_pass_before) begin
                    scan_cont_active <= 1'b0;   // 本趟零新增 -> 卡已扫尽（<scan_wanted 张可用）
                end else begin
                    scan_cont_active <= 1'b1;
                    scan_cont_start  <= last_stored_sector + 32'd1;
                    scan_pass_before <= img_found_count;
                    scan_kicked      <= 1'b0;   // 解除一次性锁 -> 下方 kick 分支发起续扫
                end
            end

            // 扫描阶段缓存图片起始 sector（v10: 表扩到 32，单写者=本 case）
            if (scan_found_valid) begin
                if (img_found_count < scan_wanted && img_found_count < 6'd32) begin
                    case (img_found_count[4:0])
                        5'd0:  img_sector0  <= scan_found_sector;
                        5'd1:  img_sector1  <= scan_found_sector;
                        5'd2:  img_sector2  <= scan_found_sector;
                        5'd3:  img_sector3  <= scan_found_sector;
                        5'd4:  img_sector4  <= scan_found_sector;
                        5'd5:  img_sector5  <= scan_found_sector;
                        5'd6:  img_sector6  <= scan_found_sector;
                        5'd7:  img_sector7  <= scan_found_sector;
                        5'd8:  img_sector8  <= scan_found_sector;
                        5'd9:  img_sector9  <= scan_found_sector;
                        5'd10: img_sector10 <= scan_found_sector;
                        5'd11: img_sector11 <= scan_found_sector;
                        5'd12: img_sector12 <= scan_found_sector;
                        5'd13: img_sector13 <= scan_found_sector;
                        5'd14: img_sector14 <= scan_found_sector;
                        5'd15: img_sector15 <= scan_found_sector;
                        5'd16: img_sector16 <= scan_found_sector;
                        5'd17: img_sector17 <= scan_found_sector;
                        5'd18: img_sector18 <= scan_found_sector;
                        5'd19: img_sector19 <= scan_found_sector;
                        5'd20: img_sector20 <= scan_found_sector;
                        5'd21: img_sector21 <= scan_found_sector;
                        5'd22: img_sector22 <= scan_found_sector;
                        5'd23: img_sector23 <= scan_found_sector;
                        5'd24: img_sector24 <= scan_found_sector;
                        5'd25: img_sector25 <= scan_found_sector;
                        5'd26: img_sector26 <= scan_found_sector;
                        5'd27: img_sector27 <= scan_found_sector;
                        5'd28: img_sector28 <= scan_found_sector;
                        5'd29: img_sector29 <= scan_found_sector;
                        5'd30: img_sector30 <= scan_found_sector;
                        default: img_sector31 <= scan_found_sector;
                    endcase
                    img_found_count    <= img_found_count + 6'd1;
                    last_stored_sector <= scan_found_sector;
                end
            end

            // v5f-fix1: source_done_seen 必须在"加载窗口内"捕获 bmp_ready 的上升沿。
            //   原为电平判断：load_start_pulse 置起当拍到 bmp_read 走出 ST_IDLE 之间恰有
            //   1 拍窗口 load_busy=1 && bmp_ready=1 同时成立，source_done_seen 被提前置 1，
            //   两级握手(源送完+帧写完)退化为"load 窗口内等一个 write_finish 脉冲"单条件：
            //   源流(SPI/SD 卡)一旦瞬态挂起，只能靠 3s 超时→abort→重扫兜底，表现为 AUTO
            //   高占空比连续加载时周期性卡图；任何迟到/杂散 toggle 也可能提前切显。
            //   改为上升沿捕获后，source_done_seen=1 才真正代表"本张图逐字节送完 FIFO"。
            if (load_busy && bmp_ready && !bmp_ready_d)
                source_done_seen <= 1'b1;

            // 记住写帧完成脉冲，避免“先写完后源结束”导致脉冲丢失而卡死
            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            // 只有“源图送完 + 整帧写完”都满足，才提交新图并切换显示缓冲区
            if (load_busy && source_done_seen && write_done_seen) begin
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                retry_cnt             <= 2'd0;   // v7.3: success clears retry
                disp_buf_idx          <= pending_buf_idx;
                img_idx               <= load_idx;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
                load_gap_cnt          <= 24'd16_000_000; // ~0.16s @100M
            end else if (load_busy) begin
                if (load_timeout_cnt > 32'd250_000_000) begin                   // v12.4: 2.5s（原0.8s；缩放路源完后仍~1s出货）
                    stall_hist2   <= stall_hist1;
                    stall_hist1   <= stall_sig_now;
                    stall_sig_now <= cur_sig;
                    if (stall_cnt != 8'd255) stall_cnt <= stall_cnt + 8'd1;
                    // v7.3: 0.8s（v5e 的 3s 太长：卡顿时画面冻结感明显；正常加载
                    //   ~0.55s，0.8s 仍留 ~45% 余量）。且超时不再直接进重扫黑屏：
                    //   先静默重试同一张图，最多 2 次；仍失败才走 v5d 全量重扫兜底。
                    load_busy             <= 1'b0;
                    load_timeout_cnt      <= 32'd0;
                    source_done_seen      <= 1'b0;
                    write_done_seen       <= 1'b0;
                    if (retry_cnt < 2'd2) begin
                        retry_cnt  <= retry_cnt + 2'd1;
                        retry_req  <= 1'b1;
                    end else begin
                        retry_cnt    <= 2'd0;
                        load_abort   <= 1'b1;   // 终极兜底：重扫（黑 ~1.6s，罕见）
                    end
                end else begin
                    // v10.3b-19/20 活动门控（b-17 扫描看门狗同族·定案版）：v7.3 的 0.8s 固定
                    //   超时按"正常加载 ~0.55s"定标，那是 640×480(921KB) 时代——多分辨率演示图
                    //   (1280×720=2.76MB) SPI 流要 1.0s+，健康大图被误杀 = 9/7"槽6永远卡"。
                    //   b19a 无差别认 sd_sec_read_data_valid 又引入"扫描字节冒充装载健康"的
                    //   幽灵装载（24s 周期振荡，22 号第7轮三案补充实验）。定案：**只认本装载
                    //   LOAD_DATA(state=4) 期的字节**+帧写完脉冲清零；装载从未启动/数据段
                    //   真断流 0.8s 照旧超时（保护语义不丢）。retry 侧由 v7.3a-b20 看门狗
                    //   负责"发不出去"，二者不再互相踩踏。
                    // v12.4: 超时 0.8s→2.5s。源读完后缩放路仍以 1字/32拍 出货 ~1s，
                    //   0.8s 会把健康装载杀成 0x18→重扫（板测 src_done=1/frame_done=0 循环）。
                    if ((sd_sec_read_data_valid && state_code_i == 4'd4) || write_finish_pulse)
                        load_timeout_cnt <= 32'd0;
                    else if (load_timeout_cnt < 32'd250_000_000)
                        load_timeout_cnt <= load_timeout_cnt + 32'd1;
                    end
            // v7.3a watchdog: retry armed but bmp_ready never returns within 0.3s
            //   => stall lives in bmp/SD side -> escalate to legacy full rescan.
            // b20 修（v7.3a 世代坑）：retry_wait 条件原为"retry_req 且 bmp 未就绪"——
            //   可重试的装载一旦真正启动，bmp 在整整 0.55~1.7s 里都不就绪（装载中），
            //   0.3s 计数必然命中 → 健康装载被 load_abort 撕掉 → 重扫再来一遍 =
            //   9/7 晚间 b19a 板上"SC0/SC1 轮流发作、模式互染"状态病根。
            //   修=装载一旦真正开跑（bmp 从 IDLE 走起，state_code_i≠0/1）即撤武装，
            //   看门狗只管"retry 发不出去"（链占着 bmp，state 恒 2）的场景。
            end else if (retry_req && !bmp_ready) begin
                if (state_code_i != 4'd0 && state_code_i != 4'd1 && state_code_i != 4'd2) begin
                    retry_req  <= 1'b0;              // b20: 装载真正在跑（HDR_WAIT=3/DATA=4），看门狗解除
                    retry_wait <= 25'd0;
                end else if (retry_wait >= 25'd30_000_000) begin
                    // v10 黑匣子：watchdog 升级重扫也算一次 stall（签名同字段，此刻
                    //   load_busy=0 故 source/wr_done_seen 已在上一 timeout 清零 -> 通常 {state,0,0,00}）
                    stall_hist2   <= stall_hist1;
                    stall_hist1   <= stall_sig_now;
                    stall_sig_now <= cur_sig;
                    if (stall_cnt != 8'd255) stall_cnt <= stall_cnt + 8'd1;
                    retry_wait <= 25'd0;
                    retry_req  <= 1'b0;
                    retry_cnt  <= 2'd0;
                    load_abort <= 1'b1;
                end else begin
                    retry_wait <= retry_wait + 25'd1;
                end
            end else begin
                retry_wait       <= 25'd0;
                load_timeout_cnt <= 32'd0;
            end
            // v12.8: 冷却倒计时（独立于 load_busy 路径，避免与超时 else 抢清）
            if (load_gap_cnt != 24'd0)
                load_gap_cnt <= load_gap_cnt - 24'd1;

            // 上电/续扫发起一次“扫描 BMP”（第一趟起点=SCAN_START_SECTOR，续扫起点=scan_cont_start）
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                scan_start_sector_r   <= scan_cont_active ? scan_cont_start : SCAN_START_SECTOR;
                // 仅全新扫描（非续扫）时清零累计与趟前计数
                if (!scan_cont_active) begin
                    img_found_count  <= 6'd0;
                    scan_pass_before <= 6'd0;
                    last_stored_sector <= 32'd0;
                    img_idx          <= 5'd0;
                    load_idx         <= 5'd0;
                end
                // v5e: 重扫不清 AUTO 开关/图序——自愈恢复用户可见状态，防"播着播着自动关"
                auto_cnt              <= 32'd0;
                // v7.4 零黑屏手术：kick 不再清 display_valid / 三个 buf 指针。
                //   恢复性重扫期间，完好旧帧继续显示；重扫后首图分支用
                //   next_buf_lut(disp,valid) 写另一 buffer，commit 时 ping-pong
                //   换页覆盖旧帧——全程无黑帧。上电首扫时这些寄存器本就是 0/0。
                next_req_pending      <= 1'b0;
                prev_req_pending      <= 1'b0;   // v10.2
                retry_req             <= 1'b0;   // v7.3
                retry_wait            <= 25'd0;  // v7.3a
                retry_cnt             <= 2'd0;   // v7.3a: fresh budget after rescan
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                load_gap_cnt          <= 24'd0;   // 重扫后尽快出首图
            end else begin
                // v10: 链式续扫进行中 -> 不提交显示/不自动播（等 32 张攒齐，避免半程轮播）
                if (key1_evt || soft_next_press)
                    next_req_pending <= 1'b1;

                if (soft_prev_press)
                    prev_req_pending <= 1'b1;   // v10.2: 无物理键，仅软键/串口

                if (key2_evt || soft_auto_press)
                    auto_tgl_pending <= 1'b1;

                // 自动播放开/关：兑现点（scan 就绪 + 候选>=2），一次意图恰好翻转一次
                //   v10: 续扫中(scan_cont_active)推迟兑现（scan_done 门控天然满足，这里加 !scan_cont_active）
                if (auto_tgl_pending && scan_done && !scan_cont_active && two_or_more) begin
                    auto_play_en     <= ~auto_play_en;
                    auto_cnt         <= 32'd0;
                    auto_tgl_pending <= 1'b0;
                end

                // 自动播放计时：终点 auto_target（v7: 秒数可运行时改；v10: VID 强制 30M）
                if (scan_done && !scan_cont_active && auto_effective && display_valid && !load_busy && first_image_committed && two_or_more) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // v7.3: 静默重试——超时后重发同一目标（load_idx/load_sector/
                //   pending buffer 全部保持原值不动），display_valid 不碰：
                //   画面停留在上一张完好帧上，零黑屏。
                if (retry_req && scan_done && bmp_ready && !load_busy && !load_abort
                    && !scan_cont_active && !chain_arming && (load_gap_cnt == 24'd0)) begin
                    retry_req        <= 1'b0;
                    load_sector      <= sector_lut(load_idx);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 首图自动加载到 buffer0（起点 = 候选集最低位；续扫中挂起）
                // v5f-fix2: 各发起分支统一加 !load_abort 防护——abort 拍 load_busy 已清、
                //   scan_done 要到下一拍才被 bmp_read 拉低，此窗口内发起的 load_start
                //   会被 abort 分支吞掉（v7.3 起：该场景多走上方 retry 分支，同理防护）
                else if (scan_done && !scan_cont_active && !chain_arming && !first_image_committed && bmp_ready && !load_busy && !load_abort && (avail_set != 32'd0) && (load_gap_cnt == 24'd0)) begin
                    load_idx         <= first_from_avail;
                    load_sector      <= sector_lut(first_from_avail);
                    // v7.4: 上电(valid=0)照旧 buf0；恢复性重扫(valid=1)写"非显示中"
                    //   的另一块 buffer，commit 时 ping-pong 无缝覆盖旧帧。
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (scan_done && !scan_cont_active && !chain_arming && bmp_ready && display_valid && !load_busy && !load_abort && next_req_pending && (avail_set != 32'd0) && (load_gap_cnt == 24'd0)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // v10.2: 手动上一张（PREV）：与 NEXT 同构反向，优先级紧随 NEXT 之后
                else if (scan_done && !scan_cont_active && !chain_arming && bmp_ready && display_valid && !load_busy && !load_abort && prev_req_pending && (avail_set != 32'd0) && (load_gap_cnt == 24'd0)) begin
                    load_idx         <= prev_from_current;
                    load_sector      <= sector_lut(prev_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    prev_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (scan_done && !scan_cont_active && !chain_arming && bmp_ready && display_valid && !load_busy && !load_abort && auto_effective && auto_tick && two_or_more && (load_gap_cnt == 24'd0)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
            end
        end
    end
end

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (sd_rst_w),   // v10.1d: 自愈软复位可达
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (scan_start_sector_r),   // v10: 常量改受控寄存器（链式续扫起点）
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (scan_target_r),         // v10: 单趟上限（3bit，SCAN32 每趟=7）
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    // v12 (B3-lite)
    .pause                  (pause),
    // v10.3 扩展3
    .multi_res              (multi_res),
    .real_w                 (real_w),
    .real_h                 (real_h),
    .pix_sov                (pix_sov),
    .pix_eov                (pix_eov)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (sd_rst_w),   // v10.1d: 自愈软复位直达 SPI/SD 底层
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule
