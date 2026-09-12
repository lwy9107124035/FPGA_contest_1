`timescale 1 ns / 1 ps
// =============================================================================
// msg_ink.v — serial command parser + GB2312 slot writer  (OSD v6, WP-C)
//
// v6 (WP-C rev) — banner text path upgraded from "8bit x 44 cols" to
//   "GB2312 pair -> 16bit x 22 slots" per OSD_CJK_CONTRACT.md §1/§2/§3/§8.
//   See "=== 集成给主线的话 ===" below for the new ports + instantiation.
//
// v7 (WP-F) — PLAYER_V7_CONTRACT §1/§2: five playback-parameter
//   commands (SPD / T / PLY / PLYALL / SCAN4 / SCAN7) classified in st1, plus
//   the prm_* quasi-static data + toggle channel (same handoff idea as ls_tgl).
//   NOTE: "PLY hh"/"PLYALL" need byte 5 of the line, but snap[7:0] only lands
//   at the END of the snix==5 cycle (nonblocking), so their per-char check is
//   deferred by ONE extra st1 cycle (snix==6, a zero-lbuf-access cycle).
//   All other v6 machinery (snapshot pipeline, ack engine, pairing engine,
//   existing commands) is bit-for-bit unchanged.
//   See "=== 集成给主线的话 ===" v7 block below for new ports + instantiation.
//
// v3c REWRITE root-cause notes (board evidence 9/4 late-night) — STILL BINDING:
//   The old code read lbuf[] with five *parallel* constant-index reads inside
//   one clock branch while ALSO doing one dynamic read + one dynamic write in
//   the same always block. TD serialized those onto a shared, registered read
//   mux, so at EOL the classifier saw stale bytes => "CLR" (first letter C,
//   never used as a first letter by any working command) classified ERR 100%
//   of the time, and msgcnt drifted from reality. FIX STRATEGY (kept):
//     * never read lbuf in >1 place per cycle;
//     * snapshot first 6 bytes through a 6-cycle pipeline into a plain 48-bit
//       register, and classify ONLY from that register;
//   v6 EXTENSION of the same rule:
//     * the st2 pairing engine touches exactly ONE dynamic lbuf reader,
//       module-level wire `nb` (used only inside st2); st1's two priming
//       destinations (f0 at snix==4, f1 at snix==5) RIDE the same existing
//       lbuf[4] / lbuf[5] reads as extra registers — never a new port;
//     * engine advance is still gated by `!de` exactly like v3c, so the
//       display read port keeps its active-window monopoly.
//   v9.1 ADDITION (WP-H): the new PLY decimal / INFO? classifiers below obey
//   the same iron rule — they read ONLY snap slices, the u0..u5 shadow and
//   plain registers; zero new lbuf[..] readers were introduced anywhere.
//
// Protocol (ASCII, "\n" terminated, CR ignored, letters uppercased in RX path;
//           v6: bytes >= 0xA1 pass through upc UNTOUCHED for GB2312 payload):
//   MSG <text>   -> text to banner row as 22 slots (GB2312 pairs + {0,ASCII})
//   EMG [1|2|3]  -> emergency CJK banner line 0 + preset status line   ack OK
//   CLR          -> exit EMG, zero all 22 slots + commit               ack OK
//   STAT?        -> ack "V2 <hh> <dd>"  (hh = hex accepted-cmd count)
//   INFO?        -> v9.1 ack "V2 <ddd> <bbbbbbbb>" (17 bytes: msgcnt as 3
//                  DIGITS decimal + the 8 dbg bits as '0'/'1', MSB first)
//   v7 (PLAYER_V7_CONTRACT §1, all ack OK + counted in msgcnt; illegal
//       digits/hex-chars/mask-0/length -> ERR, playback state untouched):
//   SPD <1-9>      -> global per-image dwell seconds       (prm_code=1)
//   T <0-6> <1-9>  -> per-image dwell override             (prm_code=2)
//   PLY <hh>       -> playback subset mask, bit7 forced 0, 0 illegal (code=3)
//                    v9.1: digits-only payloads are DECIMAL now, see below
//   PLYALL         -> mask = all scanned images            (prm_code=4)
//   SCAN4 / SCAN7  -> scan target depth 4 / 7              (prm_code=5/6)
//   anything else                                                 ack ERR
//
// =============================================================================
// === v9.1（WP-H）："去十六进制" 协议升级 =====================
//
// 需求一 · PLY 十进制解码（替换 v7 "两位皆数字=hex" 的旧解释）：
//   * "PLY <d>"  len5，d='1'..'9'：播放前 d 张图 → mask = (2^d)-1，仍
//     & 8'h7F（"PLY 3" → 8'h07）。在 snix==5 臂实现（该拍 s4 已有效，s5
//     未写入——v3c stale-byte trap，不得触碰）；gate 住 s3==8'h20 且
//     len==5，"PLYALL"（s3='A'，len6）永不被误吞。'PLY 0'（d='0'）→ ERR。
//   * "PLY <d1d2>"  len6，两位皆 '0'..'9'：mask = 十进制 10*d1+d2，合法域
//     1..99，结果 0（"PLY 00"）→ ERR。在 snix==6 延迟臂判定（需要 s5）。
//   * 任一数位含 'A'..'F'（"PLY 0f"/"PLY 7F"）→ 维持 v7 hex 老路
//     （snix==6 ply_ok 分支，经 u 影子大小写不敏感）。
//   行为变更点：**"PLY 44" 现在是十进制 44 → mask 8'h2C，不再是 hex 0x44**；
//   "PLY 05" 十进制 5 → 8'h05（与旧 hex 值巧合相同）。最终 mask 仍 & 8'h7F，
//   结果为 0 一律 ERR；prm_code=3 / prm_b 下游接口零变化。
//
// 需求二 · 新查询命令 "INFO?"（人类可读回执；STAT? 原样保留给工具链）：
//   * 匹配 len==5 且 u0..u4=="INFO?"（大写影子，大小写不敏感）；查询类，
//     与 STAT? 一致：不改 msgcnt。
//   * 新增 ack kind 2'd3，固定 17 字节："V2 <c2><c1><c0> <b7>...<b0>\r\n"。
//     3 位十进制 = msgcnt（000..255，纯函数 bin2bcd，双abble 移位修正，可
//     综合、零 RAM 读）；8 位 '0'/'1' 字符 = dbg 输入端口逐位展开（MSB
//     first；bit7扫描 bit6自动 bit5源完 bit4写完 bit3显示 bit2忙 bit1:0图号）。
//   * ackix/acklen 由 4bit 拓宽为 5bit（17 字节帧索引最大 16），ackb 的 i
//     参数同步加宽；OK/ERR/STAT 三种旧 kind 的 acklen 赋值点逐一核对：
//     OK 末索引 3、ERR 4、STAT 9，数值不变；st==3 发送比较逻辑
//     （ackix==acklen 收尾、ackix+1 步进）同步改 5bit 字面量。
// =============================================================================
// === 集成给主线的话 ===  (WP-C -> mainline, OSD_CJK_CONTRACT v1 §1)
//
// 端口变化（msg_ink 侧，其余端口全部原样）：
//   删除： we / waddr[6:0] / wdata[7:0]      （旧 44 列 8bit 写口，作废）
//   新增： msg_we                            1 拍槽写使能
//         msg_wslot[4:0]                     槽号 0..21（22 全角槽 = 352px）
//         msg_wcode[15:0]                    槽编码（契约 §2）：
//                                            16'h0000=空；{8'h00,ascii}=半角；
//                                            {hi>=A1,lo>=A1}=GB2312 全角
//         msg_commit                         一条消息（MSG/EMG/CLR）全部
//                                            槽写完后 1 拍脉冲 -> osd_banner
//                                            置 dirty、启动点阵刷新
// 行为：每条 MSG/EMG/CLR 都恰好写 22 槽（不足的槽写 16'h0000 清旧字符）后
//       commit 1 拍；VOL/NEXT/AUTO/LOAD/STAT?/INFO?/ERR 不碰写口（与旧行为一致）。
//       引擎只在 !de（消隐期）前进，与旧版占用显示 RAM 的时机相同。
//
// 顶层需要的连线改动：删掉 osd_we/osd_waddr/osd_wdata 三根线（或留给 WP-B
// 的其它通道，见 osd_banner 契约 §5/§6），新增四根线并替换 u_msg_ink 例化：
//
//   wire         msg_we;
//   wire [4:0]   msg_wslot;
//   wire [15:0]  msg_wcode;
//   wire         msg_commit;
//
//   msg_ink u_msg_ink (
//       .clk       (video_clk),
//       .rst_n     (~rst_all),
//       .rx_byte   (urx_byte),
//       .rx_vld    (urx_valid && !loader_active_v),   // v5 原样
//       .de        (de),
//       .msg_we    (msg_we),                          // 新 §1 写口 ×4
//       .msg_wslot (msg_wslot),
//       .msg_wcode (msg_wcode),
//       .msg_commit(msg_commit),
//       .tx_start  (tx_start),
//       .tx_byte   (tx_byte),
//       .tx_done   (tx_done),
//       .emg_mode  (emg_mode),
//       .emg_sel   (emg_sel),
//       .vol_lvl   (vol_lvl),
//       .next_pulse(next_pulse),
//       .auto_pulse(auto_pulse),
//       .ls_tgl    (ls_tgl),
//       .dbg       (sd_dbg)
//   );
//
// osd_banner 侧对应接收端口见 WP-B（msg_we/msg_wslot/msg_wcode/msg_commit，
// 方向 input）。旧 row-major 44 列写地址语义彻底消失，msg_ink 不再关心 ROW1。
//
// -----------------------------------------------------------------------------
// === 集成给主线的话 · v7 增补（WP-F，PLAYER_V7_CONTRACT §1/§2）===
//
// msg_ink 仅新增 4 个输出端口，不删不改任何既有端口。 prm_tgl 语义与 ls_tgl
// 同款：每条新命令合法解析成功 → 当拍装载 prm_code/prm_a/prm_b 并翻转
// prm_tgl（准静态数据+toggle）；非法（数字超域 / hex 非法字符 / PLY 掩码
// 去 bit7 后为 0 / 长度不符）→ 走既有 ERR 回包路径，tgl 不翻转、msgcnt 不
// 计数。输出在 video_clk 域，播放器（WP-E，clk50 域）自行对 tgl 打 3 拍同步
// + 边沿检测后按 code 应用。
//
//   wire       prm_tgl;     // 新命令成功解析翻转
//   wire [3:0] prm_code;    // 1=SPD 2=T 3=PLY 4=PLYALL 5=SCAN4 6=SCAN7
//   wire [3:0] prm_a;       // T: 图号 i（0..6）；其余命令 0
//   wire [7:0] prm_b;       // SPD/T: 秒数 1..9；PLY: 掩码（bit7 恒 0）；其余 0
//
// u_msg_ink 例化只需在 .dbg 行之前插入下面 4 行连线（其余原样）：
//
//   wire       prm_tgl;
//   wire [3:0] prm_code;
//   wire [3:0] prm_a;
//   wire [7:0] prm_b;
//   ...
//       .ls_tgl  (ls_tgl),
//       .prm_tgl (prm_tgl),                  // v7 §2 新增 ×4
//       .prm_code(prm_code),
//       .prm_a   (prm_a),
//       .prm_b   (prm_b),
//       .dbg     (sd_dbg)
//
// 行为说明（对主线只有两点可感知差异）：
//   1) PLY/PLYALL 的判据用到整行第 6 字节，而 snap[7:0] 在快照第 6 拍
//      （snix==5）拍末才写入（非阻塞），故这两条命令的逐字符分类顺延 1 拍
//      （st1 的 snix==6 拍完成，该拍不读 lbuf）；对外仅表现为回 OK/ERR 比其
//      它命令晚 1 个 video 周期（≈40ns），判据本身逐字符完整、不受影响。
//      v9.1 的两位十进制 PLY 走同一延迟臂，延迟特性不变。
//   2) 新命令全部在 st1 分类拍直接进 st3 回包，不进 st2 槽写引擎，msg_we/
//      msg_commit 行为与 VOL/NEXT/AUTO/LOAD/STAT? 相同（零写口动作）。
// =============================================================================

module msg_ink (
    input  wire       clk,          // video_clk 25.175 MHz
    input  wire       rst_n,
    input  wire [7:0] rx_byte,
    input  wire       rx_vld,
    input  wire       de,           // active pixel window flag
    // v6: banner row slot writer (OSD_CJK_CONTRACT §1, replaces we/waddr/wdata)
    output reg        msg_we,       // 1-cycle slot write strobe
    output reg  [4:0] msg_wslot,    // slot 0..21
    output reg  [15:0] msg_wcode,   // slot code, contract §2
    output reg        msg_commit,   // 1-cycle pulse after all 22 slots of a msg
    // uart_tx request
    output reg        tx_start,
    output reg  [7:0] tx_byte,
    input  wire       tx_done,      // pulse when previous byte fully sent
    // v3: emergency mode control (straight to osd_banner)
    output reg        emg_mode,
    output reg  [1:0] emg_sel,
    // v4: runtime alarm volume 0..9 (to alarm_tone)
    output reg  [3:0] vol_lvl,
    // v7.2: "COL <0-7>" msg-text palette index, quasi-static, SAME video
    // domain as osd_banner -> direct wire, no CDC needed.
    output reg  [2:0] txt_col,
    output reg        col_exec,   // v10.1: 1-cycle strobe, same clk domain -> osd unlocks emg-red
    // ---- v10.3 显示特效参数（准静态，同 video 域直连 vout_fx/osd_banner）----
    //   "BR n" 亮度0-9(5标准)  "GN n" 对比度0-9(5标准)  "FD0..3" 转场模式
    //   "CK0/1" 时间戳  "VU0/1" 频谱柱  "SR0..4" 标语滚动速度(px/帧,0停)
    output reg  [3:0] br_lvl,
    output reg  [3:0] gn_lvl,
    output reg  [1:0] fd_mode,
    output reg        clk_on,
    output reg        vu_on,
    output reg  [2:0] sr_spd,
    //   "SC0/1" 扩展3：多分辨率缩放总开关（准静态，1=允许非640×480并走 img_scaler）
    output reg        scale_en,
    // v4b: soft-key pulses (top turns these into 150ms "key press" level)
    output reg        next_pulse,        // NEXT: manual page forward
    output reg        auto_pulse,        // AUTO: toggle auto play
    output reg        prev_pulse,        // v10.2 PREV: manual page backward
    // v10.2 LIST? 候选名单回读（准静态二进制，播放器直出，这里只读拼字）
    input  wire [5:0] list_cnt,          //   已登记张数 0..32
    input  wire [5:0] list_depth,        //   当前扫描深度 1..32
    input  wire [4:0] list_cur,          //   当前播放图号 0..31
    // v5: LOAD session handoff — toggle flips once per LOAD command;
    // top synchronises into clk50, edge-detects -> loader_start pulse.
    output reg        ls_tgl,            // LOAD session request toggle
    // v7 (PLAYER_V7_CONTRACT §2): playback-parameter channel, quasi-static
    // data + toggle, armed together in st1 on every accepted new command.
    output reg        prm_tgl,           // flips once per accepted prm command
    output reg  [3:0] prm_code,          // 1=SPD 2=T 3=PLY 4=PLYALL 5=SCAN4 6=SCAN7 7=SCAN32 8=VID 9=SCAN n 10=RNGab
    output reg  [3:0] prm_a,             // T: image index i; 0 otherwise
    output reg  [7:0] prm_b,             // SPD/T: 秒; PLY: 掩码; VID: 帧数 0..32; SCAN9: 深度 1..32; RNG: {起a[7:4],张b[3:0]}; 其余 0
    // v10 需求三：卡死黑匣子（播放器 timeout/watchdog 锁存的 3 级签名 + 饱和计数）
    //   仅供新查询命令 "WHY?" 回执（kind 3'd4）；查询类不改 msgcnt。
    input  wire [7:0] stall_now,         // 最新 stall 签名
    input  wire [7:0] stall_h1,          // 上上次
    input  wire [7:0] stall_h2,          // 上上上次
    input  wire [7:0] stall_cnt,         // 累计 stall 次数（8bit 饱和 255）
    // v5c diag: {scan_done, found[2:0]} from player, appended to STAT reply,
    // v9.1: also expanded bit-by-bit into the INFO? reply
    input  wire [7:0] dbg
);
    localparam [7:0] NCOL = 8'd44;  // payload BYTE cap (bytes, not slots)

    // preset status line written as slots when EMG engaged (26 ASCII bytes;
    // contract §3 keeps pb() bytes untouched — pairing engine maps each byte
    // <0xA1 to {8'h00,byte}; slots beyond 21 are dropped per §3)
    localparam [207:0] PB = { 8'h45,8'h4D,8'h45,8'h52,8'h47,8'h45,8'h4E,8'h43,
                              8'h59,8'h20,8'h42,8'h52,8'h4F,8'h41,8'h44,8'h43,
                              8'h41,8'h53,8'h54,8'h20,8'h41,8'h43,8'h54,8'h49,
                              8'h56,8'h45 };  // "EMERGENCY BROADCAST ACTIVE"
    function [7:0] pb;              // constant-slice pick from packed param = pure mux
        input [5:0] i;
    begin
        case (i)
            6'd0:  pb = 8'h45; 6'd1:  pb = 8'h4D; 6'd2:  pb = 8'h45; 6'd3:  pb = 8'h52;
            6'd4:  pb = 8'h47; 6'd5:  pb = 8'h45; 6'd6:  pb = 8'h4E; 6'd7:  pb = 8'h43;
            6'd8:  pb = 8'h59; 6'd9:  pb = 8'h20; 6'd10: pb = 8'h42; 6'd11: pb = 8'h52;
            6'd12: pb = 8'h4F; 6'd13: pb = 8'h41; 6'd14: pb = 8'h44; 6'd15: pb = 8'h43;
            6'd16: pb = 8'h41; 6'd17: pb = 8'h53; 6'd18: pb = 8'h54; 6'd19: pb = 8'h20;
            6'd20: pb = 8'h41; 6'd21: pb = 8'h43; 6'd22: pb = 8'h54; 6'd23: pb = 8'h49;
            6'd24: pb = 8'h56; 6'd25: pb = 8'h45;
            default: pb = 8'h20;
        endcase
    end
    endfunction

    function [7:0] upc;             // uppercase + printable sanitize
        input [7:0] c;
    begin
        // v6: GB2312 lead/trail bytes (0xA1..0xFE) pass through UNTOUCHED so
        // the pairing engine sees the raw payload. 0x7F..0xA0 are still
        // replaced by space (they cannot take part in a §3 pair anyway).
        if (c >= 8'h61 && c <= 8'h7A)      upc = c - 8'h20;
        else if (c >= 8'h20 && c <= 8'h7E) upc = c;
        else if (c >= 8'hA1)               upc = c;
        else                               upc = 8'h20;
    end
    endfunction

    function [7:0] san;              // v9: case-preserving sanitize (storage path)
        input [7:0] c;
    begin
        if (c >= 8'h20 && c <= 8'h7E) san = c;   // printable ASCII as-is (含小写/标点)
        else if (c >= 8'hA1)          san = c;   // GB2312 双字节原样
        else                          san = 8'h20;
    end
    endfunction

    function [7:0] hexa;            // nibble -> ASCII hex digit (correct for A-F too)
        input [3:0] n;
    begin
        hexa = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
    end
    endfunction

    function [3:0] hxv;             // v7: ASCII hex digit -> nibble, inverse of
        input [7:0] c;              // hexa() over the upc()-uppercased alphabet
    begin
        // Caller must gate on the range check below first ("PLY 0G" => ERR,
        // hxv on a non-hex char merely yields a don't-care nibble, unused).
        hxv = (c <= 8'h39) ? c[3:0] : (c[3:0] + 4'd9);   // '0'..'9' | 'A'..'F'
    end
    endfunction

    // v9.1: 8-bit binary -> packed BCD {hundreds,tens,ones}, pure double-dabble
    // shift/add-3 loop (synthesizable, zero RAM access). Max input 255 fits
    // (hundreds nibble <= 2). Used only by ackb kind 3 (INFO? reply).
    // NOTE: the add-3 correction is applied BEFORE each shift — after the
    // last input bit lands no digit may be touched (post-shift-adjust would
    // inflate every final digit >=5: 255 -> "288", a real trap, fixed).
    function [11:0] bin2bcd;
        input [7:0] v;
        integer k;
        reg [11:0] a;
    begin
        a = 12'd0;
        for (k = 7; k >= 0; k = k - 1) begin
            if (a[3:0]  > 4'd4) a[3:0]  = a[3:0]  + 4'd3;
            if (a[7:4]  > 4'd4) a[7:4]  = a[7:4]  + 4'd3;
            if (a[11:8] > 4'd4) a[11:8] = a[11:8] + 4'd3;
            a = {a[10:0], v[k]};
        end
        bin2bcd = a;
    end
    endfunction

    // v9.1: "PLY <d>" single-digit rule — play the FIRST d images, i.e.
    // mask = (2^d)-1 with bit7 forced 0. d comes in as the digit VALUE 1..9
    // (caller gates out '0'); d>=7 all clamp to 8'h7F. Constant mux, no RAM.
    function [7:0] ply_dec1;
        input [3:0] d;
    begin
        case (d)
            4'd1:    ply_dec1 = 8'h01;
            4'd2:    ply_dec1 = 8'h03;
            4'd3:    ply_dec1 = 8'h07;
            4'd4:    ply_dec1 = 8'h0F;
            4'd5:    ply_dec1 = 8'h1F;
            4'd6:    ply_dec1 = 8'h3F;
            default: ply_dec1 = 8'h7F;               // 7,8,9 -> clamped mask
        endcase
    end
    endfunction

    // ack payload select: kind 0=OK 1=ERR 2=STAT "V2 hh dd",
    //                     3=INFO "V2 ddd bbbbbbbb" (v9.1, 17 bytes, i 0..16),
    //                     4=WHY  "W <hh> <hh> <hh> <ddd>" (v10, 16 bytes, i 0..15),
    //                     i = byte index (5 bits since v9.1)
    // v10: kind widened to 3 bits (0..4).
    function [7:0] ackb;
        input [4:0] i;
        input [2:0] kind;
        input [7:0] cnt;
        reg [11:0] bcd;
        reg [11:0] bcds;
    begin
        bcd  = bin2bcd(cnt);
        bcds = bin2bcd(stall_cnt);
        case (kind)
            3'd5: ackb =                                             // v10.2 LIST?
                (i==5'd0)  ? 8'h4C :                                   // L
                (i==5'd1)  ? 8'h20 :                                   // space
                (i==5'd2)  ? hexa({2'd0, list_cnt[5:4]}) :             // 已登记 hi
                (i==5'd3)  ? hexa(list_cnt[3:0]) :                     //        lo
                (i==5'd4)  ? 8'h20 :
                (i==5'd5)  ? hexa({1'b0, list_cur[4]}) :               // 当前图号 hi
                (i==5'd6)  ? hexa(list_cur[3:0]) :                     //          lo
                (i==5'd7)  ? 8'h20 :
                (i==5'd8)  ? hexa({2'd0, list_depth[5:4]}) :           // 深度 hi
                (i==5'd9)  ? hexa(list_depth[3:0]) :                   //      lo
                (i==5'd10) ? 8'h0D : 8'h0A;              // "L cc ii dd\r\n" (11B)
            3'd4: ackb =                                             // v10 WHY?
                (i==5'd0)  ? 8'h57 :                                   // W
                (i==5'd1)  ? 8'h20 :                                   // space
                (i==5'd2)  ? hexa(stall_now[7:4]) :                    // 最新签名 hi
                (i==5'd3)  ? hexa(stall_now[3:0]) :                    //              lo
                (i==5'd4)  ? 8'h20 :
                (i==5'd5)  ? hexa(stall_h1[7:4]) :                     // 上上次
                (i==5'd6)  ? hexa(stall_h1[3:0]) :
                (i==5'd7)  ? 8'h20 :
                (i==5'd8)  ? hexa(stall_h2[7:4]) :                     // 上上上次
                (i==5'd9)  ? hexa(stall_h2[3:0]) :
                (i==5'd10) ? 8'h20 :
                (i==5'd11) ? (8'h30 + {4'd0, bcds[11:8]}) :            // cnt 100s
                (i==5'd12) ? (8'h30 + {4'd0, bcds[7:4]}) :             // cnt 10s
                (i==5'd13) ? (8'h30 + {4'd0, bcds[3:0]}) :             // cnt 1s
                (i==5'd14) ? 8'h0D : 8'h0A;            // "W hh hh hh ddd\r\n"
            3'd0: ackb = (i==5'd0) ? 8'h4F : (i==5'd1) ? 8'h4B :
                     (i==5'd2) ? 8'h0D : 8'h0A;                       // OK\r\n
            3'd1: ackb = (i==5'd0) ? 8'h45 : (i==5'd1) ? 8'h52 : (i==5'd2) ? 8'h52 :
                     (i==5'd3) ? 8'h0D : 8'h0A;                       // ERR\r\n
            3'd3: ackb =                                             // v9.1 INFO?
                (i==5'd0)  ? 8'h56 :                                   // V
                (i==5'd1)  ? 8'h32 :                                   // 2
                (i==5'd2)  ? 8'h20 :                                   // space
                (i==5'd3)  ? (8'h30 + {4'd0, bcd[11:8]}) :             // cnt 100s
                (i==5'd4)  ? (8'h30 + {4'd0, bcd[7:4]}) :              // cnt 10s
                (i==5'd5)  ? (8'h30 + {4'd0, bcd[3:0]}) :              // cnt 1s
                (i==5'd6)  ? 8'h20 :                                   // space
                (i==5'd7)  ? (8'h30 + {5'd0, dbg[7]}) :                // dbg MSB
                (i==5'd8)  ? (8'h30 + {5'd0, dbg[6]}) :
                (i==5'd9)  ? (8'h30 + {5'd0, dbg[5]}) :
                (i==5'd10) ? (8'h30 + {5'd0, dbg[4]}) :
                (i==5'd11) ? (8'h30 + {5'd0, dbg[3]}) :
                (i==5'd12) ? (8'h30 + {5'd0, dbg[2]}) :
                (i==5'd13) ? (8'h30 + {5'd0, dbg[1]}) :
                (i==5'd14) ? (8'h30 + {5'd0, dbg[0]}) :                // dbg LSB
                (i==5'd15) ? 8'h0D : 8'h0A;              // "V2 ddd bbbbbbbb\r\n"
            default: ackb =                 // kind 2 = STAT (unchanged, 10B)
                (i==5'd0) ? 8'h56 :   // V
                (i==5'd1) ? 8'h32 :   // 2
                (i==5'd2) ? 8'h20 :   // space
                (i==5'd3) ? hexa(cnt[7:4]) :
                (i==5'd4) ? hexa(cnt[3:0]) :
                (i==5'd5) ? 8'h20 :
                (i==5'd6) ? hexa(dbg[7:4]) :                       // v5c: 8-bit player diag
                (i==5'd7) ? hexa(dbg[3:0]) :
                (i==5'd8) ? 8'h0D : 8'h0A;                         // "V2 hh dd\r\n"
        endcase
    end
    endfunction

    // ---- storage & state ----------------------------------------------------
    reg [7:0]  lbuf  [0:63];        // received line (ONE port touched per cycle)
    reg [6:0]  llen;
    reg [47:0] snap;                // lbuf[0..5] pipeline snapshot
    reg [2:0]  snix;
    reg [7:0]  paylen;              // payload BYTE count (unchanged semantics)
    reg [7:0]  bp;                  // v6: byte pointer 0..paylen
    reg [7:0]  fp;                  // v6: fetch pointer (chain tail fill index)
    reg [5:0]  slot;                // v6: slot counter 0..22 (22 -> commit)
    reg [1:0]  hv;                  // v6: valid bytes in f0..f2 (invariant: hv==fp-bp)
    reg [7:0]  f0, f1, f2;          // v6: 3-deep lookahead, f0 = head byte pending
    reg [4:0]  ackix;               // v9.1: 4 -> 5 bits (INFO? frame is 17B)
    reg [4:0]  acklen;              // index of last ack byte (v9.1: 5 bits)
    reg [2:0]  kindr;               // latched ack kind (0 OK,1 ERR,2 STAT,3 INFO,4 WHY) — v10 widened
    reg [1:0]  st;                  // 0 collect, 1 snapshot, 2 write, 3 ack
    reg [7:0]  msgcnt;
    reg        tx_pend;
    reg        wr_pre;              // 1 = engine sources from PB preset (EMG)
    reg [6:0]  len_snap;            // line length latched at EOL (for LOAD==4)

    // snapshot view helpers (pure register slices, no lbuf access)
    wire [7:0] s0 = snap[47:40];
    wire [7:0] s1 = snap[39:32];
    wire [7:0] s2 = snap[31:24];
    wire [7:0] s3 = snap[23:16];
    wire [7:0] s4 = snap[15:8];
    wire [7:0] s5 = snap[7:0];      // v7: consumed by PLY*/PLYALL — but ONLY in the
                                    // deferred snix==6 arm (snap[7:0] is written at
                                    // the END of snix==5, so it is stale during the
                                    // snix==5 classify cycle; reading it there was
                                    // the v3c stale-byte trap all over again)
    // v9: 大写影子——载荷在 lbuf 里保持原样大小写（san 不再折叠），命令字
    //     匹配一律走 u0..u5 影子视图，保持"命令大小写不敏感"的既有承诺。
    wire [7:0] u0 = upc(s0);
    wire [7:0] u1 = upc(s1);
    wire [7:0] u2 = upc(s2);
    wire [7:0] u3 = upc(s3);
    wire [7:0] u4 = upc(s4);
    wire [7:0] u5 = upc(s5);

    // v7: PLY mask helpers (pure snapshot-register slices, same rule as above;
    // only sampled at st1/snix==6 where s5 is valid).  Contract §1: mask bit7
    // forced 0; an all-zero result after clearing bit7 ("PLY 00", "PLY 80") is
    // illegal -> ERR via the shared final-else path, tgl untouched.
    // v9.1: ply_ok (hex path) now only ever sees payloads holding an A-F
    // letter — both-digit lines are consumed by ply2_ok below first.
    wire       hexp     = (u0==8'h50 && u1==8'h4C && u2==8'h59);
    wire       ply4_ok  = ((u4 >= 8'h30 && u4 <= 8'h39) || (u4 >= 8'h41 && u4 <= 8'h46));
    wire       ply5_ok  = ((u5 >= 8'h30 && u5 <= 8'h39) || (u5 >= 8'h41 && u5 <= 8'h46));
    wire [7:0] ply_msk  = {hxv(u4), hxv(u5)} & 8'h7F;
    wire       ply_ok   = hexp && (s3 == 8'h20) && (len_snap == 7'd6)
                          && ply4_ok && ply5_ok && (ply_msk != 8'h00);

    // v9.1: PLY two-digit DECIMAL helpers (same single-reader rule: pure
    // snap/u/len_snap reads, NO new lbuf access). Both u4,u5 in '0'..'9' =>
    // mask = 10*d1 + d2 (value 1..99), final & 8'h7F; 0 => ERR ("PLY 00").
    // Any A-F letter keeps the old hex path (ply_ok above) untouched.
    wire       dgt4        = (u4 >= 8'h30 && u4 <= 8'h39);
    wire       dgt5        = (u5 >= 8'h30 && u5 <= 8'h39);
    wire [7:0] ply_dec_msk = ({4'd0, u4[3:0]} * 8'd10 + {4'd0, u5[3:0]}) & 8'h7F;
    wire       ply2_ok     = hexp && (s3 == 8'h20) && (len_snap == 7'd6)
                             && dgt4 && dgt5 && (ply_dec_msk != 8'h00);

    // v10 需求二/三 分类 helpers（纯 snap/u/len_snap 读，零新增 lbuf 读者）
    //   VID：'V' 唯一新首字母（VOL 也是 V 但 u1='O'，VID u1='I'，不冲突）。
    //   SCAN32：'S' 家族里 u1='C'（SCAN4/7/32），SPD u1='P'，STAT? u1='T'，互不冲突。
    //   WHY?：'W' 唯一首字母，4 字节（W H Y ?），len==4，s0..s3 在 snix==5 全有效。
    wire vidp  = (u0==8'h56 && u1==8'h49 && u2==8'h44);   // V I D
    wire scanp = (u0==8'h53 && u1==8'h43 && u2==8'h41 && u3==8'h4E); // S C A N
    // "VID <d>"  单个数字（0..9，全部 <=32）——s4 在 snix==5 有效，就地判定
    wire       vid1_ok = vidp && (s3 == 8'h20) && (len_snap == 7'd5)
                         && (u4 >= 8'h30 && u4 <= 8'h39);
    // "VID <d1d2>"  两个数字，值 = 10*d1+d2，合法域 0..32（>32 ERR）——需 s5，延到 snix==6
    wire [7:0] vid2_val = ({4'd0, u4[3:0]} * 8'd10) + {4'd0, u5[3:0]};
    wire       vid2_ok  = vidp && (s3 == 8'h20) && (len_snap == 7'd6)
                          && dgt4 && dgt5 && (vid2_val <= 8'd32);
    // v10.2: "SCAN10..SCAN31" 两位数无空格（需 s5，延到 snix==6；SCAN32 走旧臂=码7，
    //   两者对播放器语义相同，保留旧臂零回归）。域 [10,31]；0x/ 前缀数字由 dgt 把关。
    wire [7:0] scan2_val = ({4'd0, u4[3:0]} * 8'd10) + {4'd0, u5[3:0]};
    wire       scan2_ok  = scanp && (len_snap == 7'd6)
                           && dgt4 && dgt5 && (scan2_val >= 8'd10)
                           && (scan2_val <= 8'd31);

    // v6: THE single dynamic lbuf reader of the whole design. Consumed only
    // inside the st2 block below; multiple destination regs in one cycle are
    // allowed, multiple addresses are not. EMG feeds pb() (pure constant mux,
    // zero RAM port); MSG feeds lbuf[4+fp] (fp<=44 -> addr<=48 < 64).
    wire [7:0] nb = wr_pre ? pb(fp[5:0])
                           : lbuf[{2'd0, fp[5:0]} + 6'd4];

    // v6: pairing decision wires (contract §3). All read registers only.
    //   hv>=2 inside `pair` implies bp+1<paylen (invariant hv==fp-bp<=paylen-bp),
    //   so the §3 "bp+1<paylen" condition is carried by hv>=2, and a byte whose
    //   partner can never arrive (fp==paylen) emits as a lone {0,f0}.
    wire       at_end  = (bp >= paylen);
    wire       have0   = (hv >= 2'd1);
    wire       have1   = (hv >= 2'd2);
    wire       pair    = have1 & (f0 >= 8'hA1) & (f1 >= 8'hA1);
    //   emit when payload exhausted (blank tail), or chain head is decidable:
    //   hv==0, or hv==1 with f0>=0xA1 while more bytes are still coming =>
    //   hold back and let the fill branch insert ONE wait cycle (no loss,
    //   no misalignment).
    wire       emit_go = at_end | (have0 & (have1 | (f0 < 8'hA1) | (fp >= paylen)));
    wire [1:0] consume = (emit_go & ~at_end) ? (pair ? 2'd2 : 2'd1) : 2'd0;
    wire       do_fetch = (fp < paylen) & ~(hv == 2'd3 & consume == 2'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 2'd0; llen <= 7'd0; snap <= 48'd0; snix <= 3'd0;
            paylen <= 8'd0; bp <= 8'd0; fp <= 8'd0; slot <= 6'd0; hv <= 2'd0;
            f0 <= 8'd0; f1 <= 8'd0; f2 <= 8'd0;
            ackix <= 5'd0; acklen <= 5'd3; kindr <= 3'd0;
            msgcnt <= 8'd0; tx_pend <= 1'b0; wr_pre <= 1'b0;
            msg_we <= 1'b0; msg_wslot <= 5'd0; msg_wcode <= 16'd0;
            msg_commit <= 1'b0;
            tx_start <= 1'b0; tx_byte <= 8'd0;
            emg_mode <= 1'b0; emg_sel <= 2'd0;
            vol_lvl <= 4'd6;                               // default loudness 6/9
            txt_col <= 3'd0;                               // v7.2: palette 0 = white
        col_exec <= 1'b0;                              // v10.1
            br_lvl <= 4'd5; gn_lvl <= 4'd5;            // v10.3: 5=标准档（直通零回归）
            fd_mode <= 2'd0;                           // v10.3: 默认硬切（=v10.2 行为）
            clk_on <= 1'b0; vu_on <= 1'b0; sr_spd <= 3'd0;
            // v12.2: 缩放默认【开】。原为 1'b0（"零回归"考虑），但 multi_res=0 时
            //   bmp_read 只认"恰 640x480"，多分辨率图会被整组拒收 —— 演示卡上
            //   8 张里只有 640x480 那张能播（用户实测"只显示两张图片"）。
            //   而播控台串口一旦不可用（缺 CH340），用户就无法下发 "SC 1" 自救。
            //   缩放链路已在 v12.1 修正并在真速率下全分辨率验证通过，故改为默认开。
            scale_en <= 1'b1;
            next_pulse <= 1'b0; auto_pulse <= 1'b0; prev_pulse <= 1'b0;
            ls_tgl <= 1'b0; len_snap <= 7'd0;
            prm_tgl <= 1'b0; prm_code <= 4'd0;            // v7 §2 channel state
            prm_a <= 4'd0; prm_b <= 8'd0;
        end else begin
            msg_we     <= 1'b0;                        // 1-cycle strobes
            msg_commit <= 1'b0;
            tx_start <= 1'b0;
            next_pulse <= 1'b0;
            auto_pulse <= 1'b0;
            prev_pulse <= 1'b0;                        // v10.2 strobe
            col_exec   <= 1'b0;                        // v10.1 strobe

            case (st)
            // ---------------- 0: accumulate; on EOL start snapshot ----------
            2'd0: begin
                if (rx_vld) begin
                    if (rx_byte == 8'h0A) begin
                        if (llen != 7'd0) begin
                            len_snap <= llen;
                            st   <= 2'd1; snix <= 3'd0;
                            llen <= 7'd0;
                        end else begin
                            llen <= 7'd0;                        // stray EOL
                        end
                    end else if (rx_byte != 8'h0D) begin
                        lbuf[llen[5:0]] <= san(rx_byte);   // v9: 存原始大小写
                        if (llen < 7'd63) llen <= llen + 7'd1;
                    end
                end
            end

            // ---------------- 1: 6-cycle snapshot pipeline (1 lbuf port/cycle)
            2'd1: begin
                case (snix)
                    3'd0: snap[47:40] <= lbuf[6'd0];
                    3'd1: snap[39:32] <= lbuf[6'd1];
                    3'd2: snap[31:24] <= lbuf[6'd2];
                    3'd3: snap[23:16] <= lbuf[6'd3];
                    3'd4: begin                                   // single read
                        snap[15:8] <= lbuf[6'd4];                 // port, two
                        f0         <= lbuf[6'd4];                 // destinations
                    end                                           // (v6: f0=b0)
                    3'd6, 3'd7: ;                                 // v7: deferred-
                    default: begin                                // snix==5   classification
                        snap[7:0] <= lbuf[6'd5];                  // single read,     cycles:
                        f1         <= lbuf[6'd5];                 // two dests  NO lbuf
                    end                                           // (v6: f1=b1) access
                endcase
                snix <= snix + 3'd1;
                if (snix == 3'd5) begin
                    // ---- classify from snapshot ONLY ----
                    if (u0==8'h4D && u1==8'h53 && u2==8'h47 && s3==8'h20) begin
                        kindr <= 3'd0; wr_pre <= 1'b0;
                        paylen <= paylen_r;                      // latched at EOL
                        bp     <= 8'd0; slot <= 6'd0;
                        fp     <= 8'd2;                          // b0,b1 preloaded
                        hv     <= (paylen_r >= 8'd2) ? 2'd2
                              :  (paylen_r == 8'd1) ? 2'd1 : 2'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st     <= 2'd2;                          // engine writes
                    end else if (u0==8'h45 && u1==8'h4D && u2==8'h47) begin
                        // v6-mainline: 19 = "EMERGENCY BROADCAST"（22 槽制下截尾 " ACTIVE"，
                        // PB/pb() 保持 26 字节原样，fp 读不到 19 之后；中文横幅走 cjk16 不受影响）
                        kindr <= 3'd0; wr_pre <= 1'b1; paylen <= 8'd19;
                        emg_mode <= 1'b1;
                        emg_sel  <= (s3 >= 8'h31 && s3 <= 8'h33)
                                    ? {1'b0, (s3 - 8'h31)} : 2'd0;
                        msgcnt <= msgcnt + 8'd1;
                        bp <= 8'd0; fp <= 8'd0; slot <= 6'd0; hv <= 2'd0;
                        st <= 2'd2;                              // engine writes PB
                    end else if (u0==8'h43 && u1==8'h4C && u2==8'h52) begin
                        kindr <= 3'd0; wr_pre <= 1'b0;
                        paylen <= 8'd0;                          // v6: CLR = 22 x
                        emg_mode <= 1'b0;                        // 16'h0000 + commit
                        msgcnt <= msgcnt + 8'd1;
                        bp <= 8'd0; fp <= 8'd0; slot <= 6'd0; hv <= 2'd0;
                        st <= 2'd2;
                    end else if (u0==8'h56 && u1==8'h4F && u2==8'h4C &&
                                 s3==8'h20 && s4 >= 8'h30 && s4 <= 8'h39) begin
                        // v4: "VOL <0-9>" — alarm loudness, no banner change
                        vol_lvl <= s4[3:0];
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (u0==8'h43 && u1==8'h4F && u2==8'h4C &&
                                 s3==8'h20 && s4 >= 8'h30 && s4 <= 8'h37 &&
                                 len_snap == 7'd5) begin
                        // v7.2: "COL <0-7>" — msg text palette (0 white,1 red,
                        // 2 green,3 yellow,4 cyan,5 magenta,6 blue,7 orange).
                        // 'C','O','L' can never alias CLR (s1='O' vs 'L').
                        txt_col <= s4[2:0];
                        col_exec <= 1'b1;              // v10.1: unlock emg-red on user COL
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (u0==8'h4E && u1==8'h45 && u2==8'h58 &&
                                 u3==8'h54) begin
                        // v4b: "NEXT" — soft page forward
                        next_pulse <= 1'b1;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (u0==8'h41 && u1==8'h55 && u2==8'h54 &&
                                 u3==8'h4F) begin
                        // v4b: "AUTO" — toggle auto slideshow
                        auto_pulse <= 1'b1;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 1'b1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (u0==8'h53 && u1==8'h50 && u2==8'h44 &&
                                 s3==8'h20 && s4 >= 8'h31 && s4 <= 8'h39 &&
                                 len_snap == 7'd5) begin
                        // v7: "SPD <1-9>" — global per-image dwell, seconds.
                        // 'S' arm is char-complete: SPD(s1='P'/s2='D') and
                        // SCAN(s1='C') never alias STAT?(s1='T',s2='A').
                        prm_code <= 4'd1; prm_a <= 4'd0;
                        prm_b    <= {4'd0, s4[3:0]};             // '1'..'9' -> 1..9
                        prm_tgl  <= ~prm_tgl;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (u0==8'h54 && s1==8'h20 && s2 >= 8'h30 &&
                                 s2 <= 8'h36 && s3 == 8'h20 &&
                                 s4 >= 8'h31 && s4 <= 8'h39 &&
                                 len_snap == 7'd5) begin
                        // v7: "T <0-6> <1-9>" — per-image dwell override
                        prm_code <= 4'd2;
                        prm_a    <= {1'b0, s2[2:0]};             // '0'..'6' -> i
                        prm_b    <= {4'd0, s4[3:0]};             // '1'..'9' -> n
                        prm_tgl  <= ~prm_tgl;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (u0==8'h50 && u1==8'h52 && u2==8'h45 &&
                                 u3==8'h56) begin
                        // v10.2: "PREV" — soft page backward (mirror of NEXT。
                        // 'P'+s1='R' never aliases PLY — PLY 是 s1='L')
                        prev_pulse <= 1'b1;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (u0==8'h52 && u1==8'h4E && u2==8'h47 &&
                                 s3 >= 8'h31 && s3 <= 8'h39 &&
                                 s4 >= 8'h31 && s4 <= 8'h39 &&
                                 len_snap == 7'd5) begin
                        // v10.2: "RNGab" — 从第 a 张起连播 b 张（a,b∈1..9，如 RNG58 = BMP0005~BMP0012）
                        //   s3/s4 在 snix==5 全有效（VOL/COL 同拍先例）。码 10：prm_b={a,b}。
                        prm_code <= 4'd10; prm_a <= 4'd0;
                        prm_b    <= {s3[3:0], s4[3:0]};
                        prm_tgl  <= ~prm_tgl;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (scanp && s4 >= 8'h31 && s4 <= 8'h39 &&
                                 len_snap == 7'd5) begin
                        // v10.2: "SCAN <1-9>" — 任意单数字深度。SCAN4/SCAN7 保留原 prm 码 5/6
                        //   （零回归），其余数字走新码 9（prm_b=数字）。两位数无空格形式
                        //   SCAN10..SCAN31 在 snix==6 延迟臂，SCAN32 沿用旧码 7。
                        prm_code <= (s4 == 8'h34) ? 4'd5
                                  : (s4 == 8'h37) ? 4'd6 : 4'd9;
                        prm_a    <= 4'd0;
                        prm_b    <= {4'd0, s4[3:0]};   // 仅码 9 会被播放器读取
                        prm_tgl  <= ~prm_tgl;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (u0==8'h42 && u1==8'h52 && s2==8'h20 &&
                                 s3 >= 8'h30 && s3 <= 8'h39 && len_snap == 7'd4) begin
                         // v10.3 "BR <0-9>" brightness (5=standard). 'B' unique head.
                         br_lvl <= s3[3:0];
                         kindr <= 3'd0; msgcnt <= msgcnt + 8'd1;
                         st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                     end else if (u0==8'h47 && u1==8'h4E && s2==8'h20 &&
                                  s3 >= 8'h30 && s3 <= 8'h39 && len_snap == 7'd4) begin
                         // v10.3 "GN <0-9>" contrast (5=standard). 'G' unique head.
                         gn_lvl <= s3[3:0];
                         kindr <= 3'd0; msgcnt <= msgcnt + 8'd1;
                         st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                     end else if (u0==8'h46 && u1==8'h44 && s2==8'h20 &&
                                  s3 >= 8'h30 && s3 <= 8'h33 && len_snap == 7'd4) begin
                         // v10.3 "FD <0-3>" transition: 0 cut / 1 fade / 2 wipe / 3 blinds.
                         fd_mode <= s3[1:0];
                         kindr <= 3'd0; msgcnt <= msgcnt + 8'd1;
                         st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                     end else if (u0==8'h43 && u1==8'h4B && s2==8'h20 &&
                                  (s3==8'h30 || s3==8'h31) && len_snap == 7'd4) begin
                         // v10.3 "CK <0/1>" timestamp on/off (K avoids COL/CLR).
                         clk_on <= s3[0];
                         kindr <= 3'd0; msgcnt <= msgcnt + 8'd1;
                         st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                     end else if (u0==8'h56 && u1==8'h55 && s2==8'h20 &&
                                  (s3==8'h30 || s3==8'h31) && len_snap == 7'd4) begin
                         // v10.3 "VU <0/1>" audio spectrum bars (U avoids VID/VOL).
                         vu_on <= s3[0];
                         kindr <= 3'd0; msgcnt <= msgcnt + 8'd1;
                         st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                     end else if (u0==8'h53 && u1==8'h52 && s2==8'h20 &&
                                  s3 >= 8'h30 && s3 <= 8'h34 && len_snap == 7'd4) begin
                         // v10.3 "SR <0-4>" marquee speed px/frame, 0=off (R avoids SPD/SCAN/STAT?).
                         sr_spd <= s3[2:0];
                         kindr <= 3'd0; msgcnt <= msgcnt + 8'd1;
                         st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (u0==8'h53 && u1==8'h43 && s2==8'h20 &&
                                 (s3==8'h30 || s3==8'h31) && len_snap == 7'd4) begin
                        // v10.3 ext3 "SC <0/1>" multi-res scale switch (0=v10.2 bit-identical)
                        scale_en <= s3[0];
                        kindr <= 3'd0; msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (hexp && s3 == 8'h20 && len_snap == 7'd5 &&
                                 s4 >= 8'h31 && s4 <= 8'h39) begin
                        // v9.1: "PLY <1-9>" — play the FIRST d images (mask =
                        // (2^d)-1, bit7 forced 0: "PLY 3" -> 8'h07). s4 is
                        // valid during snix==5 (s5 is NOT — stale-byte trap),
                        // so this arm lives here; the s3==8'h20 + len==5
                        // gates keep "PLYALL" (s3='A', len6) out of it.
                        // "PLY 0" fails the range gate and ERRs via the
                        // shared fall-through, playback state untouched.
                        prm_code <= 4'd3; prm_a <= 4'd0;
                        prm_b    <= ply_dec1(s4[3:0]);
                        prm_tgl  <= ~prm_tgl;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (u0==8'h49 && u1==8'h4E && u2==8'h46 &&
                                 u3==8'h4F && u4==8'h3F &&
                                 len_snap == 7'd5) begin
                        // v9.1: "INFO?" — human-readable query (u-shadow, so
                        // case-insensitive). Query class like STAT?: NO
                        // msgcnt change. Reply = kind 2'd3, 17 bytes. 'I'
                        // aliases no existing command first letter.
                        kindr <= 3'd3;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd16;
                    end else if (u0==8'h4C && u1==8'h49 && u2==8'h53 &&
                                 u3==8'h54 && u4==8'h3F &&
                                 len_snap == 7'd5) begin
                        // v10.2: "LIST?" — 候选名单查询（L I S T ?，5 字节）。
                        //   查询类：不改 msgcnt（INFO? 同型）。回执 kind 3'd5，
                        //   11 字节 "L cc ii dd\r\n"：已登记张数/当前图号/扫描深度，
                        //   全十六进制两位。'L' 首字母不与 LOAD（len4，s4 不参与）
                        //   冲突：LIST? 走 len5+u4='?'，LOAD 走 len4 臂互斥。
                        kindr <= 3'd5;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd11;  // 12B frame incl CRLF
                    end else if (u0==8'h57 && u1==8'h48 && u2==8'h59 &&
                                 u3==8'h3F && len_snap == 7'd4) begin
                        // v10 需求三: "WHY?" — 卡死黑匣子查询（W H Y ?，4 字节）。
                        //   查询类：与 STAT?/INFO? 一致，不改 msgcnt。回执 kind 3'd4，
                        //   16 字节 "W <2hex> <2hex> <2hex> <ddd>\r\n"。'W' 首字母唯一，
                        //   与现有命令零前缀冲突。s0..s3 在 snix==5 全部有效。
                        kindr <= 3'd4;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd15;
                    end else if (vid1_ok) begin
                        // v10 需求二: "VID <0-9>" 单数字（含 "VID 0"=退出）。s4 在
                        //   snix==5 有效；prm_code=8，prm_b=帧数字值（0..9）。
                        prm_code <= 4'd8; prm_a <= 4'd0;
                        prm_b    <= {4'd0, u4[3:0]};                  // '0'..'9' -> 0..9
                        prm_tgl  <= ~prm_tgl;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if ((hexp || vidp || scanp)
                                 && len_snap == 7'd6) begin
                        // v7: "PLY hh"/"PLYALL" need byte 5, but snap[7:0] only
                        // lands at the END of this cycle (nonblocking) => defer
                        // the full per-char check to the snix==6 arm below.
                        // st stays 1 for exactly one cycle; no lbuf access.
                        // v9.1: this trigger is unchanged and also covers the
                        // two-digit decimal PLY lines (still P,L,Y + len6).
                        // v10: 同样延后 "VID <10-32>"(需 s5) 与 "SCAN32"(需 s5)。
                        st <= 2'd1;
                    end else if (u0==8'h4C && u1==8'h4F && u2==8'h41 &&
                                 u3==8'h44 && len_snap == 7'd4) begin
                        // v5: "LOAD" — hand byte stream + tx to uart_loader.
                        // NO ack from us: loader answers "RDY" itself.
                        ls_tgl   <= ~ls_tgl;
                        msgcnt   <= msgcnt + 8'd1;
                        st       <= 2'd0;
                    end else if (u0==8'h53 && u1==8'h54 && u2==8'h41 &&
                                 u3==8'h54 && u4==8'h3F) begin
                        kindr <= 3'd2;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd9;
                    end else begin
                        kindr <= 3'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd4;
                    end
                end
                // v7: deferred per-char classification for PLY*/"PLYALL".
                // Reached ONLY via the snix==5 defer arm above (s0..s2 = P,L,Y,
                // len 6). snap[7:0] (byte 5) is valid in snap from here on;
                // snix==6 performs zero lbuf access.
                if (snix == 3'd6) begin
                    if (ply2_ok) begin
                        // v9.1: "PLY <d1d2>" both digits — mask = 10*d1+d2
                        // DECIMAL (1..99), & 8'h7F already inside ply_dec_msk;
                        // BEHAVIOR CHANGE vs v7: "PLY 44" -> 8'h2C (decimal
                        // 44), no longer hex 0x44. Result-0 ("PLY 00") ERRs
                        // via the shared path below (tgl untouched).
                        prm_code <= 4'd3;
                        prm_a    <= 4'd0;
                        prm_b    <= ply_dec_msk;
                        prm_tgl  <= ~prm_tgl;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (ply_ok) begin
                        // "PLY <hh>" — 8-bit subset mask, bit7 forced 0 by
                        // ply_msk; all-zero mask after the clear = illegal ->
                        // falls to the shared ERR path below (tgl untouched).
                        // v9.1: only reachable when at least one of the two
                        // chars is an A-F letter (digits-only went decimal
                        // above), e.g. "PLY 0f" -> 8'h0F, "PLY 7F" -> 8'h7F.
                        prm_code <= 4'd3;
                        prm_a    <= 4'd0;
                        prm_b    <= ply_msk;
                        prm_tgl  <= ~prm_tgl;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (hexp && u3==8'h41 && u4==8'h4C && u5==8'h4C &&
                                 len_snap == 7'd6) begin
                        // "PLYALL" — mask = all found images (executor decides)
                        prm_code <= 4'd4; prm_a <= 4'd0; prm_b <= 8'd0;
                        prm_tgl  <= ~prm_tgl;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (vid2_ok) begin
                        // v10 需求二: "VID <10-32>" 两数字（此处 s5 已有效）。
                        //   vid2_ok 已把值域夹在 0..32；>32 直接落到下面共享 ERR。
                        prm_code <= 4'd8; prm_a <= 4'd0;
                        prm_b    <= vid2_val;                         // 10..32
                        prm_tgl  <= ~prm_tgl;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (scanp && s4 == 8'h33 && s5 == 8'h32 &&
                                 len_snap == 7'd6) begin
                        // v10 需求一: "SCAN32" — 链式扫 32 张（延迟臂，需 s5='2'）
                        prm_code <= 4'd7; prm_a <= 4'd0; prm_b <= 8'd0;
                        prm_tgl  <= ~prm_tgl;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else if (scan2_ok) begin
                        // v10.2: "SCAN10..SCAN31" 两位数深度（码 9，prm_b=10d+e）
                        prm_code <= 4'd9; prm_a <= 4'd0;
                        prm_b    <= scan2_val;
                        prm_tgl  <= ~prm_tgl;
                        kindr <= 3'd0;
                        msgcnt <= msgcnt + 8'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd3;
                    end else begin
                        kindr <= 3'd1;
                        st <= 2'd3; ackix <= 5'd0; acklen <= 5'd4;
                    end
                end
            end

            // ---------------- 2: pairing engine lives AFTER the case (below) -
            2'd3: ;   // (placeholder keeps case item order stable)
            default: ;
            endcase

            // NOTE: st==1 classify branch above also armed MSG path -> the
            // v6 slot engine stays outside the case so it runs every st==2
            // cycle, under the SAME `!de` blanking gate as v3c (display RAM
            // read monopoly during active video is preserved).
            //
            // Per !de cycle, at most ONE slot write + at most ONE nb fetch:
            //   emit slot:  bp>=paylen -> 16'h0000 (blank tail)
            //               else pair  -> {f0,f1}, bp+=2
            //               else       -> {8'h00,f0}, bp+=1
            //   chain:      compact window [f0,f1,f2] = b[bp..bp+2] (hv deep);
            //               consume 0/1/2 from the head + append nb at the tail,
            //               shifted compactly so heads stay valid. A consume-2
            //               (or first pair after reset) leaves hv short => next
            //               cycle(s) are pure fill (wait) cycles: no RAM port
            //               pressure, no byte loss. slot==22 -> commit + OK ack.
            if (st == 2'd2) begin
                if (!de) begin
                    if (slot == 6'd22) begin
                        msg_commit <= 1'b1;                      // last slot was
                        st      <= 2'd3;                         // written last
                        ackix   <= 5'd0;                         // cycle already
                        acklen  <= 5'd3;                         // (OK\r\n ack)
                    end else begin
                        if (emit_go) begin
                            msg_we    <= 1'b1;
                            msg_wslot <= slot[4:0];
                            msg_wcode <= at_end ? 16'h0000
                                       : pair    ? {f0, f1}
                                                 : {8'h00, f0};
                            slot <= slot + 6'd1;
                            bp   <= bp + {6'd0, consume};
                        end
                        if (do_fetch) begin
                            fp <= fp + 8'd1;
                            case (consume)
                            2'd0: case (hv)                    // fill tail hole
                                  2'd0: f0 <= nb;
                                  2'd1: f1 <= nb;
                                  2'd2: f2 <= nb;
                                  default: ;                   // hv==3: no room
                                  endcase
                            2'd1: case (hv)                    // consumed f0
                                  2'd1: f0 <= nb;              // [b0] -> [nb]
                                  2'd2: begin f0 <= f1;
                                              f1 <= nb; end    // -> [b1,nb]
                                  default: begin f0 <= f1;     // hv==3
                                                   f1 <= f2;
                                                   f2 <= nb; end
                                  endcase
                            default: case (hv)                 // consume==2 (hv>=2)
                                  2'd2: f0 <= nb;              // [b0,b1] -> [nb]
                                  default: begin f0 <= f2;     // hv==3
                                                   f1 <= nb; end
                                  endcase
                            endcase
                            hv <= hv - consume + {1'b0, do_fetch};
                        end else if (consume != 2'd0) begin
                            case (consume)
                            2'd1: case (hv)                    // drain, no refill
                                  2'd2:    f0 <= f1;
                                  2'd3: begin f0 <= f1;
                                                f1 <= f2; end
                                  default: ;                   // hv==1 -> empty
                                  endcase
                            default: if (hv == 2'd3) f0 <= f2; // consume==2
                            endcase
                            hv <= hv - consume;
                        end
                    end
                end
            end

            // ---------------- 3: ack stream ----------------------------------
            // v9.1: ackix/acklen are 5-bit now; comparison + step here are
            // the ONLY consumers of their width outside the st1 loaders.
            if (st == 2'd3) begin
                if (!tx_pend) begin
                    tx_start <= 1'b1;
                    tx_pend  <= 1'b1;
                    tx_byte  <= ackb(ackix, kindr, msgcnt);
                end else if (tx_done) begin
                    tx_pend <= 1'b0;
                    if (ackix == acklen) st <= 2'd0;
                    else                 ackix <= ackix + 5'd1;
                end
            end
        end
    end

    // ---- payload length latch (computed at EOL, when llen still valid) ------
    reg [7:0] paylen_r;
    wire [6:0] pay_raw = (llen > 7'd4) ? (llen - 7'd4) : 7'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) paylen_r <= 8'd0;
        else if (st == 2'd0 && rx_vld && rx_byte == 8'h0A)
            paylen_r <= (pay_raw > 7'd44) ? NCOL : {1'b0, pay_raw};
    end
endmodule
