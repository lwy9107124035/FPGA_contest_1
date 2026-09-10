//-----------------------------------------------------------------------------
// osd_banner.v -- self-contained OSD "announcement banner" overlay (ours)
//
//   * Covers the bottom BANNER_H(=64) active lines of a 640x480 picture at
//     full width: darkens the background to half brightness (each RGB channel
//     >> 1, i.e. x0.5) and overlays 2 lines of 16x32 white text.
//   * Text rendered from the classic IBM VGA 8x16 ASCII bitmap font (glyph
//     shapes public domain; byte data extracted from the Linux kernel file
//     lib/fonts/font_8x16.c, font_vga_8x16, GPL-2.0), magnified 2x in X/Y.
//   * Font ROM is embedded as a constant `case` in a Verilog function -- no
//     $readmemh / external .mem file, avoiding TD ROM-file quirks.
//   * Purely combinational: x window compare + 640/16:1 char mux + ROM lookup
//     + 1-bit mask test + 2-level output mux.  No dividers, no arithmetic
//     beyond one subtraction and width compares; timing-trivial at 25MHz.
//
//   Ports:  x,y  = pixel coords of rgb_in while de=1 (0..639 / 0..479)
//           de   = rgb_in pixel valid
//           rgb_in / rgb_out = 24-bit {R,G,B}
//
//   v6 (WP-B, OSD_CJK_CONTRACT): the MSG row is upgraded from 44 ASCII cols
//   to 22 MIXED slots (half-width ASCII + full-width GB2312 whose 16x16
//   dots are fetched from the onboard FLASH via glyph_xcd).  A refresh FSM
//   in the video domain walks the slots on msg_commit, one in-flight xcd
//   transaction at a time, and writes glyph_ram (true 1R1W BRAM).  The
//   LINE0 banner, the EMG cjk16() fixed banner and the red tcol mux are
//   kept EXACTLY as before (contract §7).  See "=== 集成给主线的话 ===".
//-----------------------------------------------------------------------------
// === 集成给主线的话 === (v6 / WP-B)
//
// 1) 端口变化 (module osd_banner):
//    删除:  input we / waddr[6:0] / wdata[7:0]        —— 旧 44 列行缓存写口(契约§1)
//    新增:  input  msg_we, msg_wslot[4:0], msg_wcode[15:0], msg_commit
//           (msg_ink v6 已按契约§1/§2提供, 消隐期写)
//           output xcd_req_v, xcd_addr_v[19:0]
//           input  xcd_new_v, xcd_out_v[255:0], xcd_busy_v, loader_inhibit
//           —— glyph_xcd 的 video 侧 6 根(契约§5), 顶层负责对接。
//    其余端口与参数: 原样; emg_mode/emg_sel 行为不变。
//
// 2) 顶层 (WP-A) 要连:
//      .msg_we(osd_msg_we), .msg_wslot(osd_msg_wslot), .msg_wcode(osd_msg_wcode),
//      .msg_commit(osd_msg_commit)                              <- u_msg_ink v6
//      .xcd_req_v(xcd_req), .xcd_addr_v(xcd_addr),
//      .xcd_new_v(xcd_new), .xcd_out_v(xcd_got),
//      .xcd_busy_v(xcd_busy), .loader_inhibit(loader_active_v)  <- u_xcd / 顶层
//
// 3) 内部结构:
//    - 22x16bit 码槽缓存复制两份: msg_flat_a(渲染读) / msg_flat_b(FSM读),
//      同一写口双备份, 各 1 读者 (TD 铁律)。
//    - glyph_ram[0:351] (16bit x 352 词, 真 BRAM 1R1W): 写口=刷新FSM(G_WR
//      状态连续16拍移位写入), 读口=渲染 (同步读, 地址提前一拍发出, 见下)。
//      HDL-1007 预期: osd_banner 里恰好提取 1 个 RAM, 352x16。msg_flat_a/b
//      必须是纯寄存器+22:1 mux(沿用 v2b 平铺向量+unrolled 写套路), 不应再
//      出现在 RAM 抽取日志; 若 TD 把 msg_flat_* 抽成 RAM 或报数组不支持,
//      停下找我返工。
//    - 刷新FSM (video_clk): 状态 G_IDLE/G_SCAN/G_WAIT/G_TAKE/G_WR。
//      msg_commit 置 dirty -> 逐槽 0..21: 全角槽按契约§4 算 20bit 地址,
//      等 busy_v=0 且 loader_inhibit=0 发 1 拍 req_v; G_WAIT 收 new_v(该拍
//      out_v 仍是旧副本, xcd 在 new_v 拍结束沿才更新 out_v, 故下一拍
//      G_TAKE 搬运 256bit 才安全),
//      G_WR 连写 16 行 -> 下一槽。半角/空槽直接跳过; 无去重
//      (23us x 22 ≈ 0.5ms, 简单压倒 clever)。扫描期间再来 commit:
//      dirty 置位在 case 之后, 赢过完成清零 -> 重扫一遍, 保证最终一致。
//    - 渲染: msg 行仍占原 LINE1 带(banner 下半 dy=32..63, glyph_row 纵向 2x
//      不变)。cix=x/16 (0..21 有效), 槽内列=x%16。半角画槽左 8px(内置
//      8x16 ROM, bit7=最左), 右 8px 空白; 全角读 rd_word 按位 (bit15=槽内
//      第0列); 空/越界=暗背景。BRAM 是同步读, 用"上一拍预发下一像素地址"
//      补齐 1 拍延迟: 消隐期 x 寄存器恒 0 (顶层计数器只在 de=1 走), 该
//      表达式自动为首像素备货, 行尾 x=639 时地址翻到下一行槽0 —— 全程
//      rgb_out 零延迟, 顶层时序完全不用动。
//
// 4) 保留/删除的旧逻辑:
//    - 保留: LINE0 英文横幅、EMG1/2/3 的 cjk16() 固定横幅(旧路径原样服务
//      固定横幅)、emg_mode 红字 tcol=24'hFF3030、banner 半透明底。
//    - 删除: line1f(44列动态行)与 waddr>=44 写路径 —— 它的职责(MSG 底行)
//      由 22 槽行接管。注意视觉差异: 底行半角 ASCII 从 2x 宽(16px/字符)
//      变 1x 宽(8px/字符), 文字块变窄且左对齐, 最宽 352px(22槽);
//      "MSG ALL CLEAR" 回归仍成立(只是字小些)。上电默认行 = 旧
//      LINE1_TEXT 前 22 字节按半角码预置, 首帧即有字, 与旧版行为对齐。
//
// 5) 写窗口: msg_ink v6 只在 !de 消隐写槽, 所以撕裂最多出现在两行之间,
//    与旧版一致; 渲染侧对"缓存没到就画旧的"无等待(契约§6)。
//-----------------------------------------------------------------------------
`default_nettype none

module osd_banner_golden #(
    parameter [11:0] BANNER_Y0  = 12'd416,     // first banner line = 480 - 64
    parameter [11:0] BANNER_H   = 12'd64,      // banner height in lines
    parameter [5:0]  MAX_CHARS  = 6'd44,       // LINE0 cells (v6: msg row = 22x16bit slots now)
    parameter [23:0] TEXT_COLOR = 24'hFFFFFF,  // text color
    // v2: these two 44-byte constants are now only the POWER-ON INITIAL text;
    // the live text lives in tram[] below and is rewritten via UART (msg_ink).
    // v6: LINE1_TEXT doubles as the power-on preset of the 22-slot msg row
    // (its first 22 bytes, loaded as half-width codes); LINE0_TEXT is still
    // what LINE0 renders from directly.
    // LINE0_TEXT = "ANLOGI EG4S20 EMERGENCY INFO TERMINAL V2.0" (MSB byte = leftmost)
    parameter [351:0] LINE0_TEXT = {
        8'h41,8'h4E,8'h4C,8'h4F,8'h47,8'h49,8'h20,8'h45, // ANLOGI E
        8'h47,8'h34,8'h53,8'h32,8'h30,8'h20,8'h45,8'h4D, // G4S20 EM
        8'h45,8'h52,8'h47,8'h45,8'h4E,8'h43,8'h59,8'h20, // ERGENCY
        8'h49,8'h4E,8'h46,8'h4F,8'h20,8'h54,8'h45,8'h52, //  INFO TER
        8'h4D,8'h49,8'h4E,8'h41,8'h4C,8'h20,8'h56,8'h32, // MINAL V2
        8'h2E,8'h30,8'h20,8'h20 // .0
    },
    // LINE1_TEXT = "SYSTEM READY - AWAITING INJECT"
    parameter [351:0] LINE1_TEXT = {
        8'h53,8'h59,8'h53,8'h54,8'h45,8'h4D,8'h20,8'h52, // SYSTEM R
        8'h45,8'h41,8'h44,8'h59,8'h20,8'h2D,8'h20,8'h41, // EADY - A
        8'h57,8'h41,8'h49,8'h54,8'h49,8'h4E,8'h47,8'h20, // WAITING
        8'h49,8'h4E,8'h4A,8'h45,8'h43,8'h54,8'h20,8'h20, //  INJECT
        8'h20,8'h20,8'h20,8'h20,8'h20,8'h20,8'h20,8'h20, //
        8'h20,8'h20,8'h20,8'h20 //
    }
) (
    input  wire        clk,        // pixel clock (video_clk domain, everything here)
    input  wire        rst_n,      // active-low reset
    input  wire        de,         // rgb_in pixel valid
    input  wire [11:0] x,          // pixel column, 0..639 while de
    input  wire [11:0] y,          // pixel row,    0..479 while de
    input  wire [23:0] rgb_in,     // pixel coming from the main design
    output wire [23:0] rgb_out,    // overlaid pixel going to HDMI path
    // v6 message-slot write port from msg_ink (OSD_CJK_CONTRACT §1/§2; fully
    // replaces the old we/waddr/wdata row-cache port.  Caller writes during
    // blanking, exactly like the old we path did.)
    input  wire        msg_we,      // 1-cycle slot write strobe
    input  wire [4:0]  msg_wslot,   // slot number 0..21
    input  wire [15:0] msg_wcode,   // 16'h0000=empty | {00,ascii}=half | {A1..,A1..}=full
    input  wire        msg_commit,  // 1-cycle pulse: all 22 slots written -> refresh
    // v3 emergency CJK line: top banner row switches to big Chinese text
    input  wire        emg_mode,   // 1 -> row0 = full-width CJK phrase (20 cells)
    input  wire [1:0]  emg_sel,    // phrase index 0..2
    // v7.2: text palette index from msg_ink "COL" (same clk domain; 0=white)
    input  wire [2:0]  txt_col_sel,
    // v6 video-side glyph fetch interface (top connects these to glyph_xcd's
    // *_v side, contract §5; addr formula is generated inside this module)
    input  wire        xcd_new_v,       // 1 cycle: fresh 32B glyph in xcd_out_v
    input  wire [255:0] xcd_out_v,      // [255:240]=row0 ... [15:0]=row15, bit15=leftmost
    input  wire        xcd_busy_v,      // 1 = fetch in flight: never issue req_v now
    input  wire        loader_inhibit,  // 1 = OTA font burning: no NEW requests (in-flight finishes)
    output wire        xcd_req_v,       // 1-cycle fetch request pulse
    output wire [19:0] xcd_addr_v       // 32B-aligned FLASH byte address, held stable with req_v
);

    // v3: preset emergency phrases, 20 gid-bytes each (gid0=space), MSB-first
    localparam [159:0] EMG_P0 = { // 台风预警 立即撤离
        8'd1,8'd2,8'd3,8'd4,8'd0,8'd5,8'd6,8'd7,8'd8,8'd0,
        8'd0,8'd0,8'd0,8'd0,8'd0,8'd0,8'd0,8'd0,8'd0,8'd0 };
    localparam [159:0] EMG_P1 = { // 紧急疏散 危险区域 禁止通行
        8'd9,8'd10,8'd11,8'd12,8'd0,8'd13,8'd14,8'd15,8'd16,8'd0,
        8'd24,8'd25,8'd26,8'd27,8'd0,8'd0,8'd0,8'd0,8'd0,8'd0 };
    localparam [159:0] EMG_P2 = { // 集合点 保持冷静
        8'd17,8'd18,8'd19,8'd0,8'd20,8'd21,8'd22,8'd23,8'd0,8'd0,
        8'd0,8'd0,8'd0,8'd0,8'd0,8'd0,8'd0,8'd0,8'd0,8'd0 };

    // ------------------------------------------------------------------------
    // v6: message-line slot cache = 22 x 16-bit codes, as TWO identical FLAT
    // 352-bit vectors (code of slot m lives at [(336-16m) +: 16]; slot 0 is
    // leftmost, MSB-first, same layout trick that kept v2b's line1f out of
    // TD's broken async-RAM inference).  msg_flat_a is the render reader,
    // msg_flat_b the refresh-FSM reader -- one reader per array (TD iron
    // rule: never two reads of one array in the same cycle).  Power-on
    // defaults are serial-loaded from the first 22 bytes of LINE1_TEXT as
    // half-width codes over the first 22 clocks.
    // ------------------------------------------------------------------------
    reg  [351:0] msg_flat_a;
    reg  [351:0] msg_flat_b;
    reg  [4:0]   mi_ix;
    reg          mi_done;
    reg  [4:0]   k_mi;
    reg  [4:0]   k_mw;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msg_flat_a <= 352'd0;
            msg_flat_b <= 352'd0;
            mi_ix      <= 5'd0;
            mi_done    <= 1'b0;
        end else if (!mi_done) begin
            // preset load, one slot per clock (constant part-selects only)
            for (k_mi = 5'd0; k_mi < 5'd22; k_mi = k_mi + 5'd1)
                if (mi_ix == k_mi) begin
                    msg_flat_a[(336 - {k_mi, 4'd0}) +: 16] <= {8'h00, LINE1_TEXT[(344 - {k_mi, 3'b000}) +: 8]};
                    msg_flat_b[(336 - {k_mi, 4'd0}) +: 16] <= {8'h00, LINE1_TEXT[(344 - {k_mi, 3'b000}) +: 8]};
                end
            if (msg_we)         mi_done <= 1'b1;  // a live write aborts preset
            else if (mi_ix == 5'd21) mi_done <= 1'b1;
            else                mi_ix   <= mi_ix + 5'd1;
        end else if (msg_we) begin
            for (k_mw = 5'd0; k_mw < 5'd22; k_mw = k_mw + 5'd1)
                if (msg_wslot == k_mw) begin
                    msg_flat_a[(336 - {k_mw, 4'd0}) +: 16] <= msg_wcode;
                    msg_flat_b[(336 - {k_mw, 4'd0}) +: 16] <= msg_wcode;
                end
        end
    end

    // ------------------------------------------------------------------------
    // v6: glyph dot-matrix BRAM + FLASH refresh FSM (video_clk domain).
    // glyph_ram: 22 slots x 16 rows x 16 bit; word {slot,row}, bit15 = the
    // row's leftmost pixel (HZK16 order, matches xcd_out_v).  Both ports are
    // plain synchronous accesses in reset-free clocked blocks so TD extracts
    // a real 352x16 1R1W BRAM (check HDL-1007 "extracting RAM").  The render
    // read is issued ONE PIXEL AHEAD (see drawing section) so the synchronous
    // word is valid exactly during the pixel it belongs to; rgb_out itself
    // stays zero-cycle pipelined, i.e. top-level timing does not change.
    // ------------------------------------------------------------------------
    reg  [15:0] glyph_ram [0:351];

    // ---- render-side read port (address = NEXT pixel's {slot,row}) ----------
    // While de=1 the raster steps x -> x+1 (wrapping to x=0 / y+1 at 639).
    // While de=0 (blanking) the top counter sits at x=0 with y already =
    // first line of the upcoming row, so issuing {0, row(y)} every blank
    // cycle self-primes the line's first pixel and the word persists.
    wire [11:0] xnp     = (x == 12'd639) ? 12'd0     : (x + 12'd1);
    wire [11:0] ynp     = (x == 12'd639) ? (y + 12'd1) : y;
    wire [11:0] xrd     = de ? xnp : x;
    wire [11:0] yrd     = de ? ynp : y;
    wire [5:0]  cixr    = xrd[9:4];                       // next cell 0..39
    wire [4:0]  slotr   = (cixr >= 6'd22) ? 5'd0 : cixr[4:0]; // clamp OOB (unused)
    wire [11:0] dyr     = yrd - BANNER_Y0;
    wire [8:0]  rd_addr = {slotr, dyr[4:1]};
    reg  [15:0] rd_word;

    always @(posedge clk) begin
        rd_word <= glyph_ram[rd_addr];                    // 1R1W sync read
    end

    // ---- refresh FSM ---------------------------------------------------------
    // G_IDLE: wait for dirty. G_SCAN: classify slot g_s (msg_flat_b copy);
    //   half-width/empty skipped; full-width waits for quiet bus then pulses
    //   req_v with the §4 address. G_WAIT: catch new_v (busy_v clears with
    //   it). G_TAKE: xcd_out_v is stable from the cycle AFTER new_v -- copy
    //   it. G_WR: 16 consecutive writes, MSB row first, then next slot.
    // loader_inhibit blocks NEW reqs only; an in-flight fetch completes.
    localparam [2:0] G_IDLE = 3'd0, G_SCAN = 3'd1, G_WAIT = 3'd2,
                     G_TAKE = 3'd3, G_WR  = 3'd4;

    reg         g_dirty;
    reg  [2:0]  g_st;
    reg  [4:0]  g_s;               // slot under scan
    reg  [3:0]  g_r;               // row being written, 0..15
    reg  [255:0] g_hold;           // 16 rows x 16b from xcd, shifted out MSB first
    reg         req_v_r;
    reg  [19:0] addr_r;
    assign xcd_req_v  = req_v_r;
    assign xcd_addr_v = addr_r;

    // §4 address: qu=hi-A1, wei=lo-A1, addr=((qu*94)+wei)*32  (<=261664, 19b)
    wire [8:0]   g_base = 9'd336 - {g_s, 4'd0};
    wire [15:0]  g_code = msg_flat_b[g_base +: 16];       // FSM's own copy
    wire         g_full = (g_code[15:8] >= 8'hA1) && (g_code[7:0] >= 8'hA1);
    wire [7:0]   g_qu8  = g_code[15:8] - 8'hA1;           // only used when g_full
    wire [7:0]   g_we8  = g_code[7:0]  - 8'hA1;
    wire [13:0]  g_mul  = {7'd0, g_qu8[6:0]} * 14'd94;
    wire [13:0]  g_sum  = g_mul + {7'd0, g_we8[6:0]};
    wire [19:0]  g_addr = {1'b0, g_sum, 5'd0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_dirty <= 1'b0;
            g_st    <= G_IDLE;
            g_s     <= 5'd0;
            g_r     <= 4'd0;
            g_hold  <= 256'd0;
            req_v_r <= 1'b0;
            addr_r  <= 20'd0;
        end else begin
            req_v_r <= 1'b0;                             // default: 1-cycle strobe
            case (g_st)
                G_IDLE: if (g_dirty && !loader_inhibit) begin
                            g_s  <= 5'd0;
                            g_st <= G_SCAN;
                        end
                G_SCAN: if (!g_full) begin
                            // half-width ASCII / empty: no dots to fetch
                            if (g_s == 5'd21) begin
                                g_dirty <= 1'b0;
                                g_st    <= G_IDLE;
                            end else begin
                                g_s <= g_s + 5'd1;
                            end
                        end else if (!loader_inhibit && !xcd_busy_v) begin
                            addr_r  <= g_addr;
                            req_v_r <= 1'b1;             // accepted this edge (busy=0)
                            g_st    <= G_WAIT;
                        end
                G_WAIT: if (xcd_new_v) begin
                            g_st <= G_TAKE;
                            g_r  <= 4'd0;
                        end
                G_TAKE: begin
                            g_hold <= xcd_out_v;         // out_v valid this cycle
                            g_st   <= G_WR;
                        end
                G_WR: begin
                            g_hold <= {g_hold[239:0], 16'd0};   // next row to top
                            if (g_r == 4'd15) begin
                                g_r <= 4'd0;
                                if (g_s == 5'd21) begin
                                    g_dirty <= 1'b0;
                                    g_st    <= G_IDLE;
                                end else begin
                                    g_s  <= g_s + 5'd1;
                                    g_st <= G_SCAN;
                                end
                            end else begin
                                g_r <= g_r + 4'd1;
                            end
                        end
                default: g_st <= G_IDLE;
            endcase
            if (msg_commit) g_dirty <= 1'b1;             // after case: re-arm wins
        end
    end

    // BRAM write port kept in its own reset-free block (clean 1R1W inference)
    wire g_wr_act = (g_st == G_WR);
    always @(posedge clk) begin
        if (g_wr_act)
            glyph_ram[{g_s, g_r}] <= g_hold[255:240];
    end

    // ------------------------------------------------------------------------
    // Embedded IBM VGA 8x16 ASCII font (0x20..0x7E): one byte per glyph row,
    // bit7 = leftmost pixel.  Constant case -> pure ROM logic, no mem file.
    // Declared before use (Verilog-2001 requirement).
    // ------------------------------------------------------------------------
    function [7:0] glyph8x16;
        input [7:0] ch;   // ASCII code
        input [3:0] rw;   // glyph row 0..15, top -> bottom
        case ({ch, rw})
            // 0x20 (space)
            12'h200: glyph8x16 = 8'b00000000;
            12'h201: glyph8x16 = 8'b00000000;
            12'h202: glyph8x16 = 8'b00000000;
            12'h203: glyph8x16 = 8'b00000000;
            12'h204: glyph8x16 = 8'b00000000;
            12'h205: glyph8x16 = 8'b00000000;
            12'h206: glyph8x16 = 8'b00000000;
            12'h207: glyph8x16 = 8'b00000000;
            12'h208: glyph8x16 = 8'b00000000;
            12'h209: glyph8x16 = 8'b00000000;
            12'h20A: glyph8x16 = 8'b00000000;
            12'h20B: glyph8x16 = 8'b00000000;
            12'h20C: glyph8x16 = 8'b00000000;
            12'h20D: glyph8x16 = 8'b00000000;
            12'h20E: glyph8x16 = 8'b00000000;
            12'h20F: glyph8x16 = 8'b00000000;
            // 0x21 '!'
            12'h210: glyph8x16 = 8'b00000000;
            12'h211: glyph8x16 = 8'b00000000;
            12'h212: glyph8x16 = 8'b00011000;
            12'h213: glyph8x16 = 8'b00111100;
            12'h214: glyph8x16 = 8'b00111100;
            12'h215: glyph8x16 = 8'b00111100;
            12'h216: glyph8x16 = 8'b00011000;
            12'h217: glyph8x16 = 8'b00011000;
            12'h218: glyph8x16 = 8'b00011000;
            12'h219: glyph8x16 = 8'b00000000;
            12'h21A: glyph8x16 = 8'b00011000;
            12'h21B: glyph8x16 = 8'b00011000;
            12'h21C: glyph8x16 = 8'b00000000;
            12'h21D: glyph8x16 = 8'b00000000;
            12'h21E: glyph8x16 = 8'b00000000;
            12'h21F: glyph8x16 = 8'b00000000;
            // 0x22 '"'
            12'h220: glyph8x16 = 8'b00000000;
            12'h221: glyph8x16 = 8'b01100110;
            12'h222: glyph8x16 = 8'b01100110;
            12'h223: glyph8x16 = 8'b01100110;
            12'h224: glyph8x16 = 8'b00100100;
            12'h225: glyph8x16 = 8'b00000000;
            12'h226: glyph8x16 = 8'b00000000;
            12'h227: glyph8x16 = 8'b00000000;
            12'h228: glyph8x16 = 8'b00000000;
            12'h229: glyph8x16 = 8'b00000000;
            12'h22A: glyph8x16 = 8'b00000000;
            12'h22B: glyph8x16 = 8'b00000000;
            12'h22C: glyph8x16 = 8'b00000000;
            12'h22D: glyph8x16 = 8'b00000000;
            12'h22E: glyph8x16 = 8'b00000000;
            12'h22F: glyph8x16 = 8'b00000000;
            // 0x23 '#'
            12'h230: glyph8x16 = 8'b00000000;
            12'h231: glyph8x16 = 8'b00000000;
            12'h232: glyph8x16 = 8'b00000000;
            12'h233: glyph8x16 = 8'b01101100;
            12'h234: glyph8x16 = 8'b01101100;
            12'h235: glyph8x16 = 8'b11111110;
            12'h236: glyph8x16 = 8'b01101100;
            12'h237: glyph8x16 = 8'b01101100;
            12'h238: glyph8x16 = 8'b01101100;
            12'h239: glyph8x16 = 8'b11111110;
            12'h23A: glyph8x16 = 8'b01101100;
            12'h23B: glyph8x16 = 8'b01101100;
            12'h23C: glyph8x16 = 8'b00000000;
            12'h23D: glyph8x16 = 8'b00000000;
            12'h23E: glyph8x16 = 8'b00000000;
            12'h23F: glyph8x16 = 8'b00000000;
            // 0x24 '$'
            12'h240: glyph8x16 = 8'b00011000;
            12'h241: glyph8x16 = 8'b00011000;
            12'h242: glyph8x16 = 8'b01111100;
            12'h243: glyph8x16 = 8'b11000110;
            12'h244: glyph8x16 = 8'b11000010;
            12'h245: glyph8x16 = 8'b11000000;
            12'h246: glyph8x16 = 8'b01111100;
            12'h247: glyph8x16 = 8'b00000110;
            12'h248: glyph8x16 = 8'b00000110;
            12'h249: glyph8x16 = 8'b10000110;
            12'h24A: glyph8x16 = 8'b11000110;
            12'h24B: glyph8x16 = 8'b01111100;
            12'h24C: glyph8x16 = 8'b00011000;
            12'h24D: glyph8x16 = 8'b00011000;
            12'h24E: glyph8x16 = 8'b00000000;
            12'h24F: glyph8x16 = 8'b00000000;
            // 0x25 '%'
            12'h250: glyph8x16 = 8'b00000000;
            12'h251: glyph8x16 = 8'b00000000;
            12'h252: glyph8x16 = 8'b00000000;
            12'h253: glyph8x16 = 8'b00000000;
            12'h254: glyph8x16 = 8'b11000010;
            12'h255: glyph8x16 = 8'b11000110;
            12'h256: glyph8x16 = 8'b00001100;
            12'h257: glyph8x16 = 8'b00011000;
            12'h258: glyph8x16 = 8'b00110000;
            12'h259: glyph8x16 = 8'b01100000;
            12'h25A: glyph8x16 = 8'b11000110;
            12'h25B: glyph8x16 = 8'b10000110;
            12'h25C: glyph8x16 = 8'b00000000;
            12'h25D: glyph8x16 = 8'b00000000;
            12'h25E: glyph8x16 = 8'b00000000;
            12'h25F: glyph8x16 = 8'b00000000;
            // 0x26 '&'
            12'h260: glyph8x16 = 8'b00000000;
            12'h261: glyph8x16 = 8'b00000000;
            12'h262: glyph8x16 = 8'b00111000;
            12'h263: glyph8x16 = 8'b01101100;
            12'h264: glyph8x16 = 8'b01101100;
            12'h265: glyph8x16 = 8'b00111000;
            12'h266: glyph8x16 = 8'b01110110;
            12'h267: glyph8x16 = 8'b11011100;
            12'h268: glyph8x16 = 8'b11001100;
            12'h269: glyph8x16 = 8'b11001100;
            12'h26A: glyph8x16 = 8'b11001100;
            12'h26B: glyph8x16 = 8'b01110110;
            12'h26C: glyph8x16 = 8'b00000000;
            12'h26D: glyph8x16 = 8'b00000000;
            12'h26E: glyph8x16 = 8'b00000000;
            12'h26F: glyph8x16 = 8'b00000000;
            // 0x27 '''
            12'h270: glyph8x16 = 8'b00000000;
            12'h271: glyph8x16 = 8'b00110000;
            12'h272: glyph8x16 = 8'b00110000;
            12'h273: glyph8x16 = 8'b00110000;
            12'h274: glyph8x16 = 8'b01100000;
            12'h275: glyph8x16 = 8'b00000000;
            12'h276: glyph8x16 = 8'b00000000;
            12'h277: glyph8x16 = 8'b00000000;
            12'h278: glyph8x16 = 8'b00000000;
            12'h279: glyph8x16 = 8'b00000000;
            12'h27A: glyph8x16 = 8'b00000000;
            12'h27B: glyph8x16 = 8'b00000000;
            12'h27C: glyph8x16 = 8'b00000000;
            12'h27D: glyph8x16 = 8'b00000000;
            12'h27E: glyph8x16 = 8'b00000000;
            12'h27F: glyph8x16 = 8'b00000000;
            // 0x28 '('
            12'h280: glyph8x16 = 8'b00000000;
            12'h281: glyph8x16 = 8'b00000000;
            12'h282: glyph8x16 = 8'b00001100;
            12'h283: glyph8x16 = 8'b00011000;
            12'h284: glyph8x16 = 8'b00110000;
            12'h285: glyph8x16 = 8'b00110000;
            12'h286: glyph8x16 = 8'b00110000;
            12'h287: glyph8x16 = 8'b00110000;
            12'h288: glyph8x16 = 8'b00110000;
            12'h289: glyph8x16 = 8'b00110000;
            12'h28A: glyph8x16 = 8'b00011000;
            12'h28B: glyph8x16 = 8'b00001100;
            12'h28C: glyph8x16 = 8'b00000000;
            12'h28D: glyph8x16 = 8'b00000000;
            12'h28E: glyph8x16 = 8'b00000000;
            12'h28F: glyph8x16 = 8'b00000000;
            // 0x29 ')'
            12'h290: glyph8x16 = 8'b00000000;
            12'h291: glyph8x16 = 8'b00000000;
            12'h292: glyph8x16 = 8'b00110000;
            12'h293: glyph8x16 = 8'b00011000;
            12'h294: glyph8x16 = 8'b00001100;
            12'h295: glyph8x16 = 8'b00001100;
            12'h296: glyph8x16 = 8'b00001100;
            12'h297: glyph8x16 = 8'b00001100;
            12'h298: glyph8x16 = 8'b00001100;
            12'h299: glyph8x16 = 8'b00001100;
            12'h29A: glyph8x16 = 8'b00011000;
            12'h29B: glyph8x16 = 8'b00110000;
            12'h29C: glyph8x16 = 8'b00000000;
            12'h29D: glyph8x16 = 8'b00000000;
            12'h29E: glyph8x16 = 8'b00000000;
            12'h29F: glyph8x16 = 8'b00000000;
            // 0x2A '*'
            12'h2A0: glyph8x16 = 8'b00000000;
            12'h2A1: glyph8x16 = 8'b00000000;
            12'h2A2: glyph8x16 = 8'b00000000;
            12'h2A3: glyph8x16 = 8'b00000000;
            12'h2A4: glyph8x16 = 8'b00000000;
            12'h2A5: glyph8x16 = 8'b01100110;
            12'h2A6: glyph8x16 = 8'b00111100;
            12'h2A7: glyph8x16 = 8'b11111111;
            12'h2A8: glyph8x16 = 8'b00111100;
            12'h2A9: glyph8x16 = 8'b01100110;
            12'h2AA: glyph8x16 = 8'b00000000;
            12'h2AB: glyph8x16 = 8'b00000000;
            12'h2AC: glyph8x16 = 8'b00000000;
            12'h2AD: glyph8x16 = 8'b00000000;
            12'h2AE: glyph8x16 = 8'b00000000;
            12'h2AF: glyph8x16 = 8'b00000000;
            // 0x2B '+'
            12'h2B0: glyph8x16 = 8'b00000000;
            12'h2B1: glyph8x16 = 8'b00000000;
            12'h2B2: glyph8x16 = 8'b00000000;
            12'h2B3: glyph8x16 = 8'b00000000;
            12'h2B4: glyph8x16 = 8'b00000000;
            12'h2B5: glyph8x16 = 8'b00011000;
            12'h2B6: glyph8x16 = 8'b00011000;
            12'h2B7: glyph8x16 = 8'b01111110;
            12'h2B8: glyph8x16 = 8'b00011000;
            12'h2B9: glyph8x16 = 8'b00011000;
            12'h2BA: glyph8x16 = 8'b00000000;
            12'h2BB: glyph8x16 = 8'b00000000;
            12'h2BC: glyph8x16 = 8'b00000000;
            12'h2BD: glyph8x16 = 8'b00000000;
            12'h2BE: glyph8x16 = 8'b00000000;
            12'h2BF: glyph8x16 = 8'b00000000;
            // 0x2C ','
            12'h2C0: glyph8x16 = 8'b00000000;
            12'h2C1: glyph8x16 = 8'b00000000;
            12'h2C2: glyph8x16 = 8'b00000000;
            12'h2C3: glyph8x16 = 8'b00000000;
            12'h2C4: glyph8x16 = 8'b00000000;
            12'h2C5: glyph8x16 = 8'b00000000;
            12'h2C6: glyph8x16 = 8'b00000000;
            12'h2C7: glyph8x16 = 8'b00000000;
            12'h2C8: glyph8x16 = 8'b00000000;
            12'h2C9: glyph8x16 = 8'b00011000;
            12'h2CA: glyph8x16 = 8'b00011000;
            12'h2CB: glyph8x16 = 8'b00011000;
            12'h2CC: glyph8x16 = 8'b00110000;
            12'h2CD: glyph8x16 = 8'b00000000;
            12'h2CE: glyph8x16 = 8'b00000000;
            12'h2CF: glyph8x16 = 8'b00000000;
            // 0x2D '-'
            12'h2D0: glyph8x16 = 8'b00000000;
            12'h2D1: glyph8x16 = 8'b00000000;
            12'h2D2: glyph8x16 = 8'b00000000;
            12'h2D3: glyph8x16 = 8'b00000000;
            12'h2D4: glyph8x16 = 8'b00000000;
            12'h2D5: glyph8x16 = 8'b00000000;
            12'h2D6: glyph8x16 = 8'b00000000;
            12'h2D7: glyph8x16 = 8'b11111110;
            12'h2D8: glyph8x16 = 8'b00000000;
            12'h2D9: glyph8x16 = 8'b00000000;
            12'h2DA: glyph8x16 = 8'b00000000;
            12'h2DB: glyph8x16 = 8'b00000000;
            12'h2DC: glyph8x16 = 8'b00000000;
            12'h2DD: glyph8x16 = 8'b00000000;
            12'h2DE: glyph8x16 = 8'b00000000;
            12'h2DF: glyph8x16 = 8'b00000000;
            // 0x2E '.'
            12'h2E0: glyph8x16 = 8'b00000000;
            12'h2E1: glyph8x16 = 8'b00000000;
            12'h2E2: glyph8x16 = 8'b00000000;
            12'h2E3: glyph8x16 = 8'b00000000;
            12'h2E4: glyph8x16 = 8'b00000000;
            12'h2E5: glyph8x16 = 8'b00000000;
            12'h2E6: glyph8x16 = 8'b00000000;
            12'h2E7: glyph8x16 = 8'b00000000;
            12'h2E8: glyph8x16 = 8'b00000000;
            12'h2E9: glyph8x16 = 8'b00000000;
            12'h2EA: glyph8x16 = 8'b00011000;
            12'h2EB: glyph8x16 = 8'b00011000;
            12'h2EC: glyph8x16 = 8'b00000000;
            12'h2ED: glyph8x16 = 8'b00000000;
            12'h2EE: glyph8x16 = 8'b00000000;
            12'h2EF: glyph8x16 = 8'b00000000;
            // 0x2F '/'
            12'h2F0: glyph8x16 = 8'b00000000;
            12'h2F1: glyph8x16 = 8'b00000000;
            12'h2F2: glyph8x16 = 8'b00000000;
            12'h2F3: glyph8x16 = 8'b00000000;
            12'h2F4: glyph8x16 = 8'b00000010;
            12'h2F5: glyph8x16 = 8'b00000110;
            12'h2F6: glyph8x16 = 8'b00001100;
            12'h2F7: glyph8x16 = 8'b00011000;
            12'h2F8: glyph8x16 = 8'b00110000;
            12'h2F9: glyph8x16 = 8'b01100000;
            12'h2FA: glyph8x16 = 8'b11000000;
            12'h2FB: glyph8x16 = 8'b10000000;
            12'h2FC: glyph8x16 = 8'b00000000;
            12'h2FD: glyph8x16 = 8'b00000000;
            12'h2FE: glyph8x16 = 8'b00000000;
            12'h2FF: glyph8x16 = 8'b00000000;
            // 0x30 '0'
            12'h300: glyph8x16 = 8'b00000000;
            12'h301: glyph8x16 = 8'b00000000;
            12'h302: glyph8x16 = 8'b00111000;
            12'h303: glyph8x16 = 8'b01101100;
            12'h304: glyph8x16 = 8'b11000110;
            12'h305: glyph8x16 = 8'b11000110;
            12'h306: glyph8x16 = 8'b11010110;
            12'h307: glyph8x16 = 8'b11010110;
            12'h308: glyph8x16 = 8'b11000110;
            12'h309: glyph8x16 = 8'b11000110;
            12'h30A: glyph8x16 = 8'b01101100;
            12'h30B: glyph8x16 = 8'b00111000;
            12'h30C: glyph8x16 = 8'b00000000;
            12'h30D: glyph8x16 = 8'b00000000;
            12'h30E: glyph8x16 = 8'b00000000;
            12'h30F: glyph8x16 = 8'b00000000;
            // 0x31 '1'
            12'h310: glyph8x16 = 8'b00000000;
            12'h311: glyph8x16 = 8'b00000000;
            12'h312: glyph8x16 = 8'b00011000;
            12'h313: glyph8x16 = 8'b00111000;
            12'h314: glyph8x16 = 8'b01111000;
            12'h315: glyph8x16 = 8'b00011000;
            12'h316: glyph8x16 = 8'b00011000;
            12'h317: glyph8x16 = 8'b00011000;
            12'h318: glyph8x16 = 8'b00011000;
            12'h319: glyph8x16 = 8'b00011000;
            12'h31A: glyph8x16 = 8'b00011000;
            12'h31B: glyph8x16 = 8'b01111110;
            12'h31C: glyph8x16 = 8'b00000000;
            12'h31D: glyph8x16 = 8'b00000000;
            12'h31E: glyph8x16 = 8'b00000000;
            12'h31F: glyph8x16 = 8'b00000000;
            // 0x32 '2'
            12'h320: glyph8x16 = 8'b00000000;
            12'h321: glyph8x16 = 8'b00000000;
            12'h322: glyph8x16 = 8'b01111100;
            12'h323: glyph8x16 = 8'b11000110;
            12'h324: glyph8x16 = 8'b00000110;
            12'h325: glyph8x16 = 8'b00001100;
            12'h326: glyph8x16 = 8'b00011000;
            12'h327: glyph8x16 = 8'b00110000;
            12'h328: glyph8x16 = 8'b01100000;
            12'h329: glyph8x16 = 8'b11000000;
            12'h32A: glyph8x16 = 8'b11000110;
            12'h32B: glyph8x16 = 8'b11111110;
            12'h32C: glyph8x16 = 8'b00000000;
            12'h32D: glyph8x16 = 8'b00000000;
            12'h32E: glyph8x16 = 8'b00000000;
            12'h32F: glyph8x16 = 8'b00000000;
            // 0x33 '3'
            12'h330: glyph8x16 = 8'b00000000;
            12'h331: glyph8x16 = 8'b00000000;
            12'h332: glyph8x16 = 8'b01111100;
            12'h333: glyph8x16 = 8'b11000110;
            12'h334: glyph8x16 = 8'b00000110;
            12'h335: glyph8x16 = 8'b00000110;
            12'h336: glyph8x16 = 8'b00111100;
            12'h337: glyph8x16 = 8'b00000110;
            12'h338: glyph8x16 = 8'b00000110;
            12'h339: glyph8x16 = 8'b00000110;
            12'h33A: glyph8x16 = 8'b11000110;
            12'h33B: glyph8x16 = 8'b01111100;
            12'h33C: glyph8x16 = 8'b00000000;
            12'h33D: glyph8x16 = 8'b00000000;
            12'h33E: glyph8x16 = 8'b00000000;
            12'h33F: glyph8x16 = 8'b00000000;
            // 0x34 '4'
            12'h340: glyph8x16 = 8'b00000000;
            12'h341: glyph8x16 = 8'b00000000;
            12'h342: glyph8x16 = 8'b00001100;
            12'h343: glyph8x16 = 8'b00011100;
            12'h344: glyph8x16 = 8'b00111100;
            12'h345: glyph8x16 = 8'b01101100;
            12'h346: glyph8x16 = 8'b11001100;
            12'h347: glyph8x16 = 8'b11111110;
            12'h348: glyph8x16 = 8'b00001100;
            12'h349: glyph8x16 = 8'b00001100;
            12'h34A: glyph8x16 = 8'b00001100;
            12'h34B: glyph8x16 = 8'b00011110;
            12'h34C: glyph8x16 = 8'b00000000;
            12'h34D: glyph8x16 = 8'b00000000;
            12'h34E: glyph8x16 = 8'b00000000;
            12'h34F: glyph8x16 = 8'b00000000;
            // 0x35 '5'
            12'h350: glyph8x16 = 8'b00000000;
            12'h351: glyph8x16 = 8'b00000000;
            12'h352: glyph8x16 = 8'b11111110;
            12'h353: glyph8x16 = 8'b11000000;
            12'h354: glyph8x16 = 8'b11000000;
            12'h355: glyph8x16 = 8'b11000000;
            12'h356: glyph8x16 = 8'b11111100;
            12'h357: glyph8x16 = 8'b00000110;
            12'h358: glyph8x16 = 8'b00000110;
            12'h359: glyph8x16 = 8'b00000110;
            12'h35A: glyph8x16 = 8'b11000110;
            12'h35B: glyph8x16 = 8'b01111100;
            12'h35C: glyph8x16 = 8'b00000000;
            12'h35D: glyph8x16 = 8'b00000000;
            12'h35E: glyph8x16 = 8'b00000000;
            12'h35F: glyph8x16 = 8'b00000000;
            // 0x36 '6'
            12'h360: glyph8x16 = 8'b00000000;
            12'h361: glyph8x16 = 8'b00000000;
            12'h362: glyph8x16 = 8'b00111000;
            12'h363: glyph8x16 = 8'b01100000;
            12'h364: glyph8x16 = 8'b11000000;
            12'h365: glyph8x16 = 8'b11000000;
            12'h366: glyph8x16 = 8'b11111100;
            12'h367: glyph8x16 = 8'b11000110;
            12'h368: glyph8x16 = 8'b11000110;
            12'h369: glyph8x16 = 8'b11000110;
            12'h36A: glyph8x16 = 8'b11000110;
            12'h36B: glyph8x16 = 8'b01111100;
            12'h36C: glyph8x16 = 8'b00000000;
            12'h36D: glyph8x16 = 8'b00000000;
            12'h36E: glyph8x16 = 8'b00000000;
            12'h36F: glyph8x16 = 8'b00000000;
            // 0x37 '7'
            12'h370: glyph8x16 = 8'b00000000;
            12'h371: glyph8x16 = 8'b00000000;
            12'h372: glyph8x16 = 8'b11111110;
            12'h373: glyph8x16 = 8'b11000110;
            12'h374: glyph8x16 = 8'b00000110;
            12'h375: glyph8x16 = 8'b00000110;
            12'h376: glyph8x16 = 8'b00001100;
            12'h377: glyph8x16 = 8'b00011000;
            12'h378: glyph8x16 = 8'b00110000;
            12'h379: glyph8x16 = 8'b00110000;
            12'h37A: glyph8x16 = 8'b00110000;
            12'h37B: glyph8x16 = 8'b00110000;
            12'h37C: glyph8x16 = 8'b00000000;
            12'h37D: glyph8x16 = 8'b00000000;
            12'h37E: glyph8x16 = 8'b00000000;
            12'h37F: glyph8x16 = 8'b00000000;
            // 0x38 '8'
            12'h380: glyph8x16 = 8'b00000000;
            12'h381: glyph8x16 = 8'b00000000;
            12'h382: glyph8x16 = 8'b01111100;
            12'h383: glyph8x16 = 8'b11000110;
            12'h384: glyph8x16 = 8'b11000110;
            12'h385: glyph8x16 = 8'b11000110;
            12'h386: glyph8x16 = 8'b01111100;
            12'h387: glyph8x16 = 8'b11000110;
            12'h388: glyph8x16 = 8'b11000110;
            12'h389: glyph8x16 = 8'b11000110;
            12'h38A: glyph8x16 = 8'b11000110;
            12'h38B: glyph8x16 = 8'b01111100;
            12'h38C: glyph8x16 = 8'b00000000;
            12'h38D: glyph8x16 = 8'b00000000;
            12'h38E: glyph8x16 = 8'b00000000;
            12'h38F: glyph8x16 = 8'b00000000;
            // 0x39 '9'
            12'h390: glyph8x16 = 8'b00000000;
            12'h391: glyph8x16 = 8'b00000000;
            12'h392: glyph8x16 = 8'b01111100;
            12'h393: glyph8x16 = 8'b11000110;
            12'h394: glyph8x16 = 8'b11000110;
            12'h395: glyph8x16 = 8'b11000110;
            12'h396: glyph8x16 = 8'b01111110;
            12'h397: glyph8x16 = 8'b00000110;
            12'h398: glyph8x16 = 8'b00000110;
            12'h399: glyph8x16 = 8'b00000110;
            12'h39A: glyph8x16 = 8'b00001100;
            12'h39B: glyph8x16 = 8'b01111000;
            12'h39C: glyph8x16 = 8'b00000000;
            12'h39D: glyph8x16 = 8'b00000000;
            12'h39E: glyph8x16 = 8'b00000000;
            12'h39F: glyph8x16 = 8'b00000000;
            // 0x3A ':'
            12'h3A0: glyph8x16 = 8'b00000000;
            12'h3A1: glyph8x16 = 8'b00000000;
            12'h3A2: glyph8x16 = 8'b00000000;
            12'h3A3: glyph8x16 = 8'b00000000;
            12'h3A4: glyph8x16 = 8'b00011000;
            12'h3A5: glyph8x16 = 8'b00011000;
            12'h3A6: glyph8x16 = 8'b00000000;
            12'h3A7: glyph8x16 = 8'b00000000;
            12'h3A8: glyph8x16 = 8'b00000000;
            12'h3A9: glyph8x16 = 8'b00011000;
            12'h3AA: glyph8x16 = 8'b00011000;
            12'h3AB: glyph8x16 = 8'b00000000;
            12'h3AC: glyph8x16 = 8'b00000000;
            12'h3AD: glyph8x16 = 8'b00000000;
            12'h3AE: glyph8x16 = 8'b00000000;
            12'h3AF: glyph8x16 = 8'b00000000;
            // 0x3B ';'
            12'h3B0: glyph8x16 = 8'b00000000;
            12'h3B1: glyph8x16 = 8'b00000000;
            12'h3B2: glyph8x16 = 8'b00000000;
            12'h3B3: glyph8x16 = 8'b00000000;
            12'h3B4: glyph8x16 = 8'b00011000;
            12'h3B5: glyph8x16 = 8'b00011000;
            12'h3B6: glyph8x16 = 8'b00000000;
            12'h3B7: glyph8x16 = 8'b00000000;
            12'h3B8: glyph8x16 = 8'b00000000;
            12'h3B9: glyph8x16 = 8'b00011000;
            12'h3BA: glyph8x16 = 8'b00011000;
            12'h3BB: glyph8x16 = 8'b00110000;
            12'h3BC: glyph8x16 = 8'b00000000;
            12'h3BD: glyph8x16 = 8'b00000000;
            12'h3BE: glyph8x16 = 8'b00000000;
            12'h3BF: glyph8x16 = 8'b00000000;
            // 0x3C '<'
            12'h3C0: glyph8x16 = 8'b00000000;
            12'h3C1: glyph8x16 = 8'b00000000;
            12'h3C2: glyph8x16 = 8'b00000000;
            12'h3C3: glyph8x16 = 8'b00000110;
            12'h3C4: glyph8x16 = 8'b00001100;
            12'h3C5: glyph8x16 = 8'b00011000;
            12'h3C6: glyph8x16 = 8'b00110000;
            12'h3C7: glyph8x16 = 8'b01100000;
            12'h3C8: glyph8x16 = 8'b00110000;
            12'h3C9: glyph8x16 = 8'b00011000;
            12'h3CA: glyph8x16 = 8'b00001100;
            12'h3CB: glyph8x16 = 8'b00000110;
            12'h3CC: glyph8x16 = 8'b00000000;
            12'h3CD: glyph8x16 = 8'b00000000;
            12'h3CE: glyph8x16 = 8'b00000000;
            12'h3CF: glyph8x16 = 8'b00000000;
            // 0x3D '='
            12'h3D0: glyph8x16 = 8'b00000000;
            12'h3D1: glyph8x16 = 8'b00000000;
            12'h3D2: glyph8x16 = 8'b00000000;
            12'h3D3: glyph8x16 = 8'b00000000;
            12'h3D4: glyph8x16 = 8'b00000000;
            12'h3D5: glyph8x16 = 8'b01111110;
            12'h3D6: glyph8x16 = 8'b00000000;
            12'h3D7: glyph8x16 = 8'b00000000;
            12'h3D8: glyph8x16 = 8'b01111110;
            12'h3D9: glyph8x16 = 8'b00000000;
            12'h3DA: glyph8x16 = 8'b00000000;
            12'h3DB: glyph8x16 = 8'b00000000;
            12'h3DC: glyph8x16 = 8'b00000000;
            12'h3DD: glyph8x16 = 8'b00000000;
            12'h3DE: glyph8x16 = 8'b00000000;
            12'h3DF: glyph8x16 = 8'b00000000;
            // 0x3E '>'
            12'h3E0: glyph8x16 = 8'b00000000;
            12'h3E1: glyph8x16 = 8'b00000000;
            12'h3E2: glyph8x16 = 8'b00000000;
            12'h3E3: glyph8x16 = 8'b01100000;
            12'h3E4: glyph8x16 = 8'b00110000;
            12'h3E5: glyph8x16 = 8'b00011000;
            12'h3E6: glyph8x16 = 8'b00001100;
            12'h3E7: glyph8x16 = 8'b00000110;
            12'h3E8: glyph8x16 = 8'b00001100;
            12'h3E9: glyph8x16 = 8'b00011000;
            12'h3EA: glyph8x16 = 8'b00110000;
            12'h3EB: glyph8x16 = 8'b01100000;
            12'h3EC: glyph8x16 = 8'b00000000;
            12'h3ED: glyph8x16 = 8'b00000000;
            12'h3EE: glyph8x16 = 8'b00000000;
            12'h3EF: glyph8x16 = 8'b00000000;
            // 0x3F '?'
            12'h3F0: glyph8x16 = 8'b00000000;
            12'h3F1: glyph8x16 = 8'b00000000;
            12'h3F2: glyph8x16 = 8'b01111100;
            12'h3F3: glyph8x16 = 8'b11000110;
            12'h3F4: glyph8x16 = 8'b11000110;
            12'h3F5: glyph8x16 = 8'b00001100;
            12'h3F6: glyph8x16 = 8'b00011000;
            12'h3F7: glyph8x16 = 8'b00011000;
            12'h3F8: glyph8x16 = 8'b00011000;
            12'h3F9: glyph8x16 = 8'b00000000;
            12'h3FA: glyph8x16 = 8'b00011000;
            12'h3FB: glyph8x16 = 8'b00011000;
            12'h3FC: glyph8x16 = 8'b00000000;
            12'h3FD: glyph8x16 = 8'b00000000;
            12'h3FE: glyph8x16 = 8'b00000000;
            12'h3FF: glyph8x16 = 8'b00000000;
            // 0x40 '@'
            12'h400: glyph8x16 = 8'b00000000;
            12'h401: glyph8x16 = 8'b00000000;
            12'h402: glyph8x16 = 8'b00000000;
            12'h403: glyph8x16 = 8'b01111100;
            12'h404: glyph8x16 = 8'b11000110;
            12'h405: glyph8x16 = 8'b11000110;
            12'h406: glyph8x16 = 8'b11011110;
            12'h407: glyph8x16 = 8'b11011110;
            12'h408: glyph8x16 = 8'b11011110;
            12'h409: glyph8x16 = 8'b11011100;
            12'h40A: glyph8x16 = 8'b11000000;
            12'h40B: glyph8x16 = 8'b01111100;
            12'h40C: glyph8x16 = 8'b00000000;
            12'h40D: glyph8x16 = 8'b00000000;
            12'h40E: glyph8x16 = 8'b00000000;
            12'h40F: glyph8x16 = 8'b00000000;
            // 0x41 'A'
            12'h410: glyph8x16 = 8'b00000000;
            12'h411: glyph8x16 = 8'b00000000;
            12'h412: glyph8x16 = 8'b00010000;
            12'h413: glyph8x16 = 8'b00111000;
            12'h414: glyph8x16 = 8'b01101100;
            12'h415: glyph8x16 = 8'b11000110;
            12'h416: glyph8x16 = 8'b11000110;
            12'h417: glyph8x16 = 8'b11111110;
            12'h418: glyph8x16 = 8'b11000110;
            12'h419: glyph8x16 = 8'b11000110;
            12'h41A: glyph8x16 = 8'b11000110;
            12'h41B: glyph8x16 = 8'b11000110;
            12'h41C: glyph8x16 = 8'b00000000;
            12'h41D: glyph8x16 = 8'b00000000;
            12'h41E: glyph8x16 = 8'b00000000;
            12'h41F: glyph8x16 = 8'b00000000;
            // 0x42 'B'
            12'h420: glyph8x16 = 8'b00000000;
            12'h421: glyph8x16 = 8'b00000000;
            12'h422: glyph8x16 = 8'b11111100;
            12'h423: glyph8x16 = 8'b01100110;
            12'h424: glyph8x16 = 8'b01100110;
            12'h425: glyph8x16 = 8'b01100110;
            12'h426: glyph8x16 = 8'b01111100;
            12'h427: glyph8x16 = 8'b01100110;
            12'h428: glyph8x16 = 8'b01100110;
            12'h429: glyph8x16 = 8'b01100110;
            12'h42A: glyph8x16 = 8'b01100110;
            12'h42B: glyph8x16 = 8'b11111100;
            12'h42C: glyph8x16 = 8'b00000000;
            12'h42D: glyph8x16 = 8'b00000000;
            12'h42E: glyph8x16 = 8'b00000000;
            12'h42F: glyph8x16 = 8'b00000000;
            // 0x43 'C'
            12'h430: glyph8x16 = 8'b00000000;
            12'h431: glyph8x16 = 8'b00000000;
            12'h432: glyph8x16 = 8'b00111100;
            12'h433: glyph8x16 = 8'b01100110;
            12'h434: glyph8x16 = 8'b11000010;
            12'h435: glyph8x16 = 8'b11000000;
            12'h436: glyph8x16 = 8'b11000000;
            12'h437: glyph8x16 = 8'b11000000;
            12'h438: glyph8x16 = 8'b11000000;
            12'h439: glyph8x16 = 8'b11000010;
            12'h43A: glyph8x16 = 8'b01100110;
            12'h43B: glyph8x16 = 8'b00111100;
            12'h43C: glyph8x16 = 8'b00000000;
            12'h43D: glyph8x16 = 8'b00000000;
            12'h43E: glyph8x16 = 8'b00000000;
            12'h43F: glyph8x16 = 8'b00000000;
            // 0x44 'D'
            12'h440: glyph8x16 = 8'b00000000;
            12'h441: glyph8x16 = 8'b00000000;
            12'h442: glyph8x16 = 8'b11111000;
            12'h443: glyph8x16 = 8'b01101100;
            12'h444: glyph8x16 = 8'b01100110;
            12'h445: glyph8x16 = 8'b01100110;
            12'h446: glyph8x16 = 8'b01100110;
            12'h447: glyph8x16 = 8'b01100110;
            12'h448: glyph8x16 = 8'b01100110;
            12'h449: glyph8x16 = 8'b01100110;
            12'h44A: glyph8x16 = 8'b01101100;
            12'h44B: glyph8x16 = 8'b11111000;
            12'h44C: glyph8x16 = 8'b00000000;
            12'h44D: glyph8x16 = 8'b00000000;
            12'h44E: glyph8x16 = 8'b00000000;
            12'h44F: glyph8x16 = 8'b00000000;
            // 0x45 'E'
            12'h450: glyph8x16 = 8'b00000000;
            12'h451: glyph8x16 = 8'b00000000;
            12'h452: glyph8x16 = 8'b11111110;
            12'h453: glyph8x16 = 8'b01100110;
            12'h454: glyph8x16 = 8'b01100010;
            12'h455: glyph8x16 = 8'b01101000;
            12'h456: glyph8x16 = 8'b01111000;
            12'h457: glyph8x16 = 8'b01101000;
            12'h458: glyph8x16 = 8'b01100000;
            12'h459: glyph8x16 = 8'b01100010;
            12'h45A: glyph8x16 = 8'b01100110;
            12'h45B: glyph8x16 = 8'b11111110;
            12'h45C: glyph8x16 = 8'b00000000;
            12'h45D: glyph8x16 = 8'b00000000;
            12'h45E: glyph8x16 = 8'b00000000;
            12'h45F: glyph8x16 = 8'b00000000;
            // 0x46 'F'
            12'h460: glyph8x16 = 8'b00000000;
            12'h461: glyph8x16 = 8'b00000000;
            12'h462: glyph8x16 = 8'b11111110;
            12'h463: glyph8x16 = 8'b01100110;
            12'h464: glyph8x16 = 8'b01100010;
            12'h465: glyph8x16 = 8'b01101000;
            12'h466: glyph8x16 = 8'b01111000;
            12'h467: glyph8x16 = 8'b01101000;
            12'h468: glyph8x16 = 8'b01100000;
            12'h469: glyph8x16 = 8'b01100000;
            12'h46A: glyph8x16 = 8'b01100000;
            12'h46B: glyph8x16 = 8'b11110000;
            12'h46C: glyph8x16 = 8'b00000000;
            12'h46D: glyph8x16 = 8'b00000000;
            12'h46E: glyph8x16 = 8'b00000000;
            12'h46F: glyph8x16 = 8'b00000000;
            // 0x47 'G'
            12'h470: glyph8x16 = 8'b00000000;
            12'h471: glyph8x16 = 8'b00000000;
            12'h472: glyph8x16 = 8'b00111100;
            12'h473: glyph8x16 = 8'b01100110;
            12'h474: glyph8x16 = 8'b11000010;
            12'h475: glyph8x16 = 8'b11000000;
            12'h476: glyph8x16 = 8'b11000000;
            12'h477: glyph8x16 = 8'b11011110;
            12'h478: glyph8x16 = 8'b11000110;
            12'h479: glyph8x16 = 8'b11000110;
            12'h47A: glyph8x16 = 8'b01100110;
            12'h47B: glyph8x16 = 8'b00111010;
            12'h47C: glyph8x16 = 8'b00000000;
            12'h47D: glyph8x16 = 8'b00000000;
            12'h47E: glyph8x16 = 8'b00000000;
            12'h47F: glyph8x16 = 8'b00000000;
            // 0x48 'H'
            12'h480: glyph8x16 = 8'b00000000;
            12'h481: glyph8x16 = 8'b00000000;
            12'h482: glyph8x16 = 8'b11000110;
            12'h483: glyph8x16 = 8'b11000110;
            12'h484: glyph8x16 = 8'b11000110;
            12'h485: glyph8x16 = 8'b11000110;
            12'h486: glyph8x16 = 8'b11111110;
            12'h487: glyph8x16 = 8'b11000110;
            12'h488: glyph8x16 = 8'b11000110;
            12'h489: glyph8x16 = 8'b11000110;
            12'h48A: glyph8x16 = 8'b11000110;
            12'h48B: glyph8x16 = 8'b11000110;
            12'h48C: glyph8x16 = 8'b00000000;
            12'h48D: glyph8x16 = 8'b00000000;
            12'h48E: glyph8x16 = 8'b00000000;
            12'h48F: glyph8x16 = 8'b00000000;
            // 0x49 'I'
            12'h490: glyph8x16 = 8'b00000000;
            12'h491: glyph8x16 = 8'b00000000;
            12'h492: glyph8x16 = 8'b00111100;
            12'h493: glyph8x16 = 8'b00011000;
            12'h494: glyph8x16 = 8'b00011000;
            12'h495: glyph8x16 = 8'b00011000;
            12'h496: glyph8x16 = 8'b00011000;
            12'h497: glyph8x16 = 8'b00011000;
            12'h498: glyph8x16 = 8'b00011000;
            12'h499: glyph8x16 = 8'b00011000;
            12'h49A: glyph8x16 = 8'b00011000;
            12'h49B: glyph8x16 = 8'b00111100;
            12'h49C: glyph8x16 = 8'b00000000;
            12'h49D: glyph8x16 = 8'b00000000;
            12'h49E: glyph8x16 = 8'b00000000;
            12'h49F: glyph8x16 = 8'b00000000;
            // 0x4A 'J'
            12'h4A0: glyph8x16 = 8'b00000000;
            12'h4A1: glyph8x16 = 8'b00000000;
            12'h4A2: glyph8x16 = 8'b00011110;
            12'h4A3: glyph8x16 = 8'b00001100;
            12'h4A4: glyph8x16 = 8'b00001100;
            12'h4A5: glyph8x16 = 8'b00001100;
            12'h4A6: glyph8x16 = 8'b00001100;
            12'h4A7: glyph8x16 = 8'b00001100;
            12'h4A8: glyph8x16 = 8'b11001100;
            12'h4A9: glyph8x16 = 8'b11001100;
            12'h4AA: glyph8x16 = 8'b11001100;
            12'h4AB: glyph8x16 = 8'b01111000;
            12'h4AC: glyph8x16 = 8'b00000000;
            12'h4AD: glyph8x16 = 8'b00000000;
            12'h4AE: glyph8x16 = 8'b00000000;
            12'h4AF: glyph8x16 = 8'b00000000;
            // 0x4B 'K'
            12'h4B0: glyph8x16 = 8'b00000000;
            12'h4B1: glyph8x16 = 8'b00000000;
            12'h4B2: glyph8x16 = 8'b11100110;
            12'h4B3: glyph8x16 = 8'b01100110;
            12'h4B4: glyph8x16 = 8'b01100110;
            12'h4B5: glyph8x16 = 8'b01101100;
            12'h4B6: glyph8x16 = 8'b01111000;
            12'h4B7: glyph8x16 = 8'b01111000;
            12'h4B8: glyph8x16 = 8'b01101100;
            12'h4B9: glyph8x16 = 8'b01100110;
            12'h4BA: glyph8x16 = 8'b01100110;
            12'h4BB: glyph8x16 = 8'b11100110;
            12'h4BC: glyph8x16 = 8'b00000000;
            12'h4BD: glyph8x16 = 8'b00000000;
            12'h4BE: glyph8x16 = 8'b00000000;
            12'h4BF: glyph8x16 = 8'b00000000;
            // 0x4C 'L'
            12'h4C0: glyph8x16 = 8'b00000000;
            12'h4C1: glyph8x16 = 8'b00000000;
            12'h4C2: glyph8x16 = 8'b11110000;
            12'h4C3: glyph8x16 = 8'b01100000;
            12'h4C4: glyph8x16 = 8'b01100000;
            12'h4C5: glyph8x16 = 8'b01100000;
            12'h4C6: glyph8x16 = 8'b01100000;
            12'h4C7: glyph8x16 = 8'b01100000;
            12'h4C8: glyph8x16 = 8'b01100000;
            12'h4C9: glyph8x16 = 8'b01100010;
            12'h4CA: glyph8x16 = 8'b01100110;
            12'h4CB: glyph8x16 = 8'b11111110;
            12'h4CC: glyph8x16 = 8'b00000000;
            12'h4CD: glyph8x16 = 8'b00000000;
            12'h4CE: glyph8x16 = 8'b00000000;
            12'h4CF: glyph8x16 = 8'b00000000;
            // 0x4D 'M'
            12'h4D0: glyph8x16 = 8'b00000000;
            12'h4D1: glyph8x16 = 8'b00000000;
            12'h4D2: glyph8x16 = 8'b11000110;
            12'h4D3: glyph8x16 = 8'b11101110;
            12'h4D4: glyph8x16 = 8'b11111110;
            12'h4D5: glyph8x16 = 8'b11111110;
            12'h4D6: glyph8x16 = 8'b11010110;
            12'h4D7: glyph8x16 = 8'b11000110;
            12'h4D8: glyph8x16 = 8'b11000110;
            12'h4D9: glyph8x16 = 8'b11000110;
            12'h4DA: glyph8x16 = 8'b11000110;
            12'h4DB: glyph8x16 = 8'b11000110;
            12'h4DC: glyph8x16 = 8'b00000000;
            12'h4DD: glyph8x16 = 8'b00000000;
            12'h4DE: glyph8x16 = 8'b00000000;
            12'h4DF: glyph8x16 = 8'b00000000;
            // 0x4E 'N'
            12'h4E0: glyph8x16 = 8'b00000000;
            12'h4E1: glyph8x16 = 8'b00000000;
            12'h4E2: glyph8x16 = 8'b11000110;
            12'h4E3: glyph8x16 = 8'b11100110;
            12'h4E4: glyph8x16 = 8'b11110110;
            12'h4E5: glyph8x16 = 8'b11111110;
            12'h4E6: glyph8x16 = 8'b11011110;
            12'h4E7: glyph8x16 = 8'b11001110;
            12'h4E8: glyph8x16 = 8'b11000110;
            12'h4E9: glyph8x16 = 8'b11000110;
            12'h4EA: glyph8x16 = 8'b11000110;
            12'h4EB: glyph8x16 = 8'b11000110;
            12'h4EC: glyph8x16 = 8'b00000000;
            12'h4ED: glyph8x16 = 8'b00000000;
            12'h4EE: glyph8x16 = 8'b00000000;
            12'h4EF: glyph8x16 = 8'b00000000;
            // 0x4F 'O'
            12'h4F0: glyph8x16 = 8'b00000000;
            12'h4F1: glyph8x16 = 8'b00000000;
            12'h4F2: glyph8x16 = 8'b01111100;
            12'h4F3: glyph8x16 = 8'b11000110;
            12'h4F4: glyph8x16 = 8'b11000110;
            12'h4F5: glyph8x16 = 8'b11000110;
            12'h4F6: glyph8x16 = 8'b11000110;
            12'h4F7: glyph8x16 = 8'b11000110;
            12'h4F8: glyph8x16 = 8'b11000110;
            12'h4F9: glyph8x16 = 8'b11000110;
            12'h4FA: glyph8x16 = 8'b11000110;
            12'h4FB: glyph8x16 = 8'b01111100;
            12'h4FC: glyph8x16 = 8'b00000000;
            12'h4FD: glyph8x16 = 8'b00000000;
            12'h4FE: glyph8x16 = 8'b00000000;
            12'h4FF: glyph8x16 = 8'b00000000;
            // 0x50 'P'
            12'h500: glyph8x16 = 8'b00000000;
            12'h501: glyph8x16 = 8'b00000000;
            12'h502: glyph8x16 = 8'b11111100;
            12'h503: glyph8x16 = 8'b01100110;
            12'h504: glyph8x16 = 8'b01100110;
            12'h505: glyph8x16 = 8'b01100110;
            12'h506: glyph8x16 = 8'b01111100;
            12'h507: glyph8x16 = 8'b01100000;
            12'h508: glyph8x16 = 8'b01100000;
            12'h509: glyph8x16 = 8'b01100000;
            12'h50A: glyph8x16 = 8'b01100000;
            12'h50B: glyph8x16 = 8'b11110000;
            12'h50C: glyph8x16 = 8'b00000000;
            12'h50D: glyph8x16 = 8'b00000000;
            12'h50E: glyph8x16 = 8'b00000000;
            12'h50F: glyph8x16 = 8'b00000000;
            // 0x51 'Q'
            12'h510: glyph8x16 = 8'b00000000;
            12'h511: glyph8x16 = 8'b00000000;
            12'h512: glyph8x16 = 8'b01111100;
            12'h513: glyph8x16 = 8'b11000110;
            12'h514: glyph8x16 = 8'b11000110;
            12'h515: glyph8x16 = 8'b11000110;
            12'h516: glyph8x16 = 8'b11000110;
            12'h517: glyph8x16 = 8'b11000110;
            12'h518: glyph8x16 = 8'b11000110;
            12'h519: glyph8x16 = 8'b11010110;
            12'h51A: glyph8x16 = 8'b11011110;
            12'h51B: glyph8x16 = 8'b01111100;
            12'h51C: glyph8x16 = 8'b00001100;
            12'h51D: glyph8x16 = 8'b00001110;
            12'h51E: glyph8x16 = 8'b00000000;
            12'h51F: glyph8x16 = 8'b00000000;
            // 0x52 'R'
            12'h520: glyph8x16 = 8'b00000000;
            12'h521: glyph8x16 = 8'b00000000;
            12'h522: glyph8x16 = 8'b11111100;
            12'h523: glyph8x16 = 8'b01100110;
            12'h524: glyph8x16 = 8'b01100110;
            12'h525: glyph8x16 = 8'b01100110;
            12'h526: glyph8x16 = 8'b01111100;
            12'h527: glyph8x16 = 8'b01101100;
            12'h528: glyph8x16 = 8'b01100110;
            12'h529: glyph8x16 = 8'b01100110;
            12'h52A: glyph8x16 = 8'b01100110;
            12'h52B: glyph8x16 = 8'b11100110;
            12'h52C: glyph8x16 = 8'b00000000;
            12'h52D: glyph8x16 = 8'b00000000;
            12'h52E: glyph8x16 = 8'b00000000;
            12'h52F: glyph8x16 = 8'b00000000;
            // 0x53 'S'
            12'h530: glyph8x16 = 8'b00000000;
            12'h531: glyph8x16 = 8'b00000000;
            12'h532: glyph8x16 = 8'b01111100;
            12'h533: glyph8x16 = 8'b11000110;
            12'h534: glyph8x16 = 8'b11000110;
            12'h535: glyph8x16 = 8'b01100000;
            12'h536: glyph8x16 = 8'b00111000;
            12'h537: glyph8x16 = 8'b00001100;
            12'h538: glyph8x16 = 8'b00000110;
            12'h539: glyph8x16 = 8'b11000110;
            12'h53A: glyph8x16 = 8'b11000110;
            12'h53B: glyph8x16 = 8'b01111100;
            12'h53C: glyph8x16 = 8'b00000000;
            12'h53D: glyph8x16 = 8'b00000000;
            12'h53E: glyph8x16 = 8'b00000000;
            12'h53F: glyph8x16 = 8'b00000000;
            // 0x54 'T'
            12'h540: glyph8x16 = 8'b00000000;
            12'h541: glyph8x16 = 8'b00000000;
            12'h542: glyph8x16 = 8'b01111110;
            12'h543: glyph8x16 = 8'b01111110;
            12'h544: glyph8x16 = 8'b01011010;
            12'h545: glyph8x16 = 8'b00011000;
            12'h546: glyph8x16 = 8'b00011000;
            12'h547: glyph8x16 = 8'b00011000;
            12'h548: glyph8x16 = 8'b00011000;
            12'h549: glyph8x16 = 8'b00011000;
            12'h54A: glyph8x16 = 8'b00011000;
            12'h54B: glyph8x16 = 8'b00111100;
            12'h54C: glyph8x16 = 8'b00000000;
            12'h54D: glyph8x16 = 8'b00000000;
            12'h54E: glyph8x16 = 8'b00000000;
            12'h54F: glyph8x16 = 8'b00000000;
            // 0x55 'U'
            12'h550: glyph8x16 = 8'b00000000;
            12'h551: glyph8x16 = 8'b00000000;
            12'h552: glyph8x16 = 8'b11000110;
            12'h553: glyph8x16 = 8'b11000110;
            12'h554: glyph8x16 = 8'b11000110;
            12'h555: glyph8x16 = 8'b11000110;
            12'h556: glyph8x16 = 8'b11000110;
            12'h557: glyph8x16 = 8'b11000110;
            12'h558: glyph8x16 = 8'b11000110;
            12'h559: glyph8x16 = 8'b11000110;
            12'h55A: glyph8x16 = 8'b11000110;
            12'h55B: glyph8x16 = 8'b01111100;
            12'h55C: glyph8x16 = 8'b00000000;
            12'h55D: glyph8x16 = 8'b00000000;
            12'h55E: glyph8x16 = 8'b00000000;
            12'h55F: glyph8x16 = 8'b00000000;
            // 0x56 'V'
            12'h560: glyph8x16 = 8'b00000000;
            12'h561: glyph8x16 = 8'b00000000;
            12'h562: glyph8x16 = 8'b11000110;
            12'h563: glyph8x16 = 8'b11000110;
            12'h564: glyph8x16 = 8'b11000110;
            12'h565: glyph8x16 = 8'b11000110;
            12'h566: glyph8x16 = 8'b11000110;
            12'h567: glyph8x16 = 8'b11000110;
            12'h568: glyph8x16 = 8'b11000110;
            12'h569: glyph8x16 = 8'b01101100;
            12'h56A: glyph8x16 = 8'b00111000;
            12'h56B: glyph8x16 = 8'b00010000;
            12'h56C: glyph8x16 = 8'b00000000;
            12'h56D: glyph8x16 = 8'b00000000;
            12'h56E: glyph8x16 = 8'b00000000;
            12'h56F: glyph8x16 = 8'b00000000;
            // 0x57 'W'
            12'h570: glyph8x16 = 8'b00000000;
            12'h571: glyph8x16 = 8'b00000000;
            12'h572: glyph8x16 = 8'b11000110;
            12'h573: glyph8x16 = 8'b11000110;
            12'h574: glyph8x16 = 8'b11000110;
            12'h575: glyph8x16 = 8'b11000110;
            12'h576: glyph8x16 = 8'b11010110;
            12'h577: glyph8x16 = 8'b11010110;
            12'h578: glyph8x16 = 8'b11010110;
            12'h579: glyph8x16 = 8'b11111110;
            12'h57A: glyph8x16 = 8'b11101110;
            12'h57B: glyph8x16 = 8'b01101100;
            12'h57C: glyph8x16 = 8'b00000000;
            12'h57D: glyph8x16 = 8'b00000000;
            12'h57E: glyph8x16 = 8'b00000000;
            12'h57F: glyph8x16 = 8'b00000000;
            // 0x58 'X'
            12'h580: glyph8x16 = 8'b00000000;
            12'h581: glyph8x16 = 8'b00000000;
            12'h582: glyph8x16 = 8'b11000110;
            12'h583: glyph8x16 = 8'b11000110;
            12'h584: glyph8x16 = 8'b01101100;
            12'h585: glyph8x16 = 8'b01111100;
            12'h586: glyph8x16 = 8'b00111000;
            12'h587: glyph8x16 = 8'b00111000;
            12'h588: glyph8x16 = 8'b01111100;
            12'h589: glyph8x16 = 8'b01101100;
            12'h58A: glyph8x16 = 8'b11000110;
            12'h58B: glyph8x16 = 8'b11000110;
            12'h58C: glyph8x16 = 8'b00000000;
            12'h58D: glyph8x16 = 8'b00000000;
            12'h58E: glyph8x16 = 8'b00000000;
            12'h58F: glyph8x16 = 8'b00000000;
            // 0x59 'Y'
            12'h590: glyph8x16 = 8'b00000000;
            12'h591: glyph8x16 = 8'b00000000;
            12'h592: glyph8x16 = 8'b01100110;
            12'h593: glyph8x16 = 8'b01100110;
            12'h594: glyph8x16 = 8'b01100110;
            12'h595: glyph8x16 = 8'b01100110;
            12'h596: glyph8x16 = 8'b00111100;
            12'h597: glyph8x16 = 8'b00011000;
            12'h598: glyph8x16 = 8'b00011000;
            12'h599: glyph8x16 = 8'b00011000;
            12'h59A: glyph8x16 = 8'b00011000;
            12'h59B: glyph8x16 = 8'b00111100;
            12'h59C: glyph8x16 = 8'b00000000;
            12'h59D: glyph8x16 = 8'b00000000;
            12'h59E: glyph8x16 = 8'b00000000;
            12'h59F: glyph8x16 = 8'b00000000;
            // 0x5A 'Z'
            12'h5A0: glyph8x16 = 8'b00000000;
            12'h5A1: glyph8x16 = 8'b00000000;
            12'h5A2: glyph8x16 = 8'b11111110;
            12'h5A3: glyph8x16 = 8'b11000110;
            12'h5A4: glyph8x16 = 8'b10000110;
            12'h5A5: glyph8x16 = 8'b00001100;
            12'h5A6: glyph8x16 = 8'b00011000;
            12'h5A7: glyph8x16 = 8'b00110000;
            12'h5A8: glyph8x16 = 8'b01100000;
            12'h5A9: glyph8x16 = 8'b11000010;
            12'h5AA: glyph8x16 = 8'b11000110;
            12'h5AB: glyph8x16 = 8'b11111110;
            12'h5AC: glyph8x16 = 8'b00000000;
            12'h5AD: glyph8x16 = 8'b00000000;
            12'h5AE: glyph8x16 = 8'b00000000;
            12'h5AF: glyph8x16 = 8'b00000000;
            // 0x5B '['
            12'h5B0: glyph8x16 = 8'b00000000;
            12'h5B1: glyph8x16 = 8'b00000000;
            12'h5B2: glyph8x16 = 8'b00111100;
            12'h5B3: glyph8x16 = 8'b00110000;
            12'h5B4: glyph8x16 = 8'b00110000;
            12'h5B5: glyph8x16 = 8'b00110000;
            12'h5B6: glyph8x16 = 8'b00110000;
            12'h5B7: glyph8x16 = 8'b00110000;
            12'h5B8: glyph8x16 = 8'b00110000;
            12'h5B9: glyph8x16 = 8'b00110000;
            12'h5BA: glyph8x16 = 8'b00110000;
            12'h5BB: glyph8x16 = 8'b00111100;
            12'h5BC: glyph8x16 = 8'b00000000;
            12'h5BD: glyph8x16 = 8'b00000000;
            12'h5BE: glyph8x16 = 8'b00000000;
            12'h5BF: glyph8x16 = 8'b00000000;
            // 0x5C '\'
            12'h5C0: glyph8x16 = 8'b00000000;
            12'h5C1: glyph8x16 = 8'b00000000;
            12'h5C2: glyph8x16 = 8'b00000000;
            12'h5C3: glyph8x16 = 8'b10000000;
            12'h5C4: glyph8x16 = 8'b11000000;
            12'h5C5: glyph8x16 = 8'b11100000;
            12'h5C6: glyph8x16 = 8'b01110000;
            12'h5C7: glyph8x16 = 8'b00111000;
            12'h5C8: glyph8x16 = 8'b00011100;
            12'h5C9: glyph8x16 = 8'b00001110;
            12'h5CA: glyph8x16 = 8'b00000110;
            12'h5CB: glyph8x16 = 8'b00000010;
            12'h5CC: glyph8x16 = 8'b00000000;
            12'h5CD: glyph8x16 = 8'b00000000;
            12'h5CE: glyph8x16 = 8'b00000000;
            12'h5CF: glyph8x16 = 8'b00000000;
            // 0x5D ']'
            12'h5D0: glyph8x16 = 8'b00000000;
            12'h5D1: glyph8x16 = 8'b00000000;
            12'h5D2: glyph8x16 = 8'b00111100;
            12'h5D3: glyph8x16 = 8'b00001100;
            12'h5D4: glyph8x16 = 8'b00001100;
            12'h5D5: glyph8x16 = 8'b00001100;
            12'h5D6: glyph8x16 = 8'b00001100;
            12'h5D7: glyph8x16 = 8'b00001100;
            12'h5D8: glyph8x16 = 8'b00001100;
            12'h5D9: glyph8x16 = 8'b00001100;
            12'h5DA: glyph8x16 = 8'b00001100;
            12'h5DB: glyph8x16 = 8'b00111100;
            12'h5DC: glyph8x16 = 8'b00000000;
            12'h5DD: glyph8x16 = 8'b00000000;
            12'h5DE: glyph8x16 = 8'b00000000;
            12'h5DF: glyph8x16 = 8'b00000000;
            // 0x5E '^'
            12'h5E0: glyph8x16 = 8'b00010000;
            12'h5E1: glyph8x16 = 8'b00111000;
            12'h5E2: glyph8x16 = 8'b01101100;
            12'h5E3: glyph8x16 = 8'b11000110;
            12'h5E4: glyph8x16 = 8'b00000000;
            12'h5E5: glyph8x16 = 8'b00000000;
            12'h5E6: glyph8x16 = 8'b00000000;
            12'h5E7: glyph8x16 = 8'b00000000;
            12'h5E8: glyph8x16 = 8'b00000000;
            12'h5E9: glyph8x16 = 8'b00000000;
            12'h5EA: glyph8x16 = 8'b00000000;
            12'h5EB: glyph8x16 = 8'b00000000;
            12'h5EC: glyph8x16 = 8'b00000000;
            12'h5ED: glyph8x16 = 8'b00000000;
            12'h5EE: glyph8x16 = 8'b00000000;
            12'h5EF: glyph8x16 = 8'b00000000;
            // 0x5F '_'
            12'h5F0: glyph8x16 = 8'b00000000;
            12'h5F1: glyph8x16 = 8'b00000000;
            12'h5F2: glyph8x16 = 8'b00000000;
            12'h5F3: glyph8x16 = 8'b00000000;
            12'h5F4: glyph8x16 = 8'b00000000;
            12'h5F5: glyph8x16 = 8'b00000000;
            12'h5F6: glyph8x16 = 8'b00000000;
            12'h5F7: glyph8x16 = 8'b00000000;
            12'h5F8: glyph8x16 = 8'b00000000;
            12'h5F9: glyph8x16 = 8'b00000000;
            12'h5FA: glyph8x16 = 8'b00000000;
            12'h5FB: glyph8x16 = 8'b00000000;
            12'h5FC: glyph8x16 = 8'b00000000;
            12'h5FD: glyph8x16 = 8'b11111111;
            12'h5FE: glyph8x16 = 8'b00000000;
            12'h5FF: glyph8x16 = 8'b00000000;
            // 0x60 '`'
            12'h600: glyph8x16 = 8'b00000000;
            12'h601: glyph8x16 = 8'b00110000;
            12'h602: glyph8x16 = 8'b00011000;
            12'h603: glyph8x16 = 8'b00001100;
            12'h604: glyph8x16 = 8'b00000000;
            12'h605: glyph8x16 = 8'b00000000;
            12'h606: glyph8x16 = 8'b00000000;
            12'h607: glyph8x16 = 8'b00000000;
            12'h608: glyph8x16 = 8'b00000000;
            12'h609: glyph8x16 = 8'b00000000;
            12'h60A: glyph8x16 = 8'b00000000;
            12'h60B: glyph8x16 = 8'b00000000;
            12'h60C: glyph8x16 = 8'b00000000;
            12'h60D: glyph8x16 = 8'b00000000;
            12'h60E: glyph8x16 = 8'b00000000;
            12'h60F: glyph8x16 = 8'b00000000;
            // 0x61 'a'
            12'h610: glyph8x16 = 8'b00000000;
            12'h611: glyph8x16 = 8'b00000000;
            12'h612: glyph8x16 = 8'b00000000;
            12'h613: glyph8x16 = 8'b00000000;
            12'h614: glyph8x16 = 8'b00000000;
            12'h615: glyph8x16 = 8'b01111000;
            12'h616: glyph8x16 = 8'b00001100;
            12'h617: glyph8x16 = 8'b01111100;
            12'h618: glyph8x16 = 8'b11001100;
            12'h619: glyph8x16 = 8'b11001100;
            12'h61A: glyph8x16 = 8'b11001100;
            12'h61B: glyph8x16 = 8'b01110110;
            12'h61C: glyph8x16 = 8'b00000000;
            12'h61D: glyph8x16 = 8'b00000000;
            12'h61E: glyph8x16 = 8'b00000000;
            12'h61F: glyph8x16 = 8'b00000000;
            // 0x62 'b'
            12'h620: glyph8x16 = 8'b00000000;
            12'h621: glyph8x16 = 8'b00000000;
            12'h622: glyph8x16 = 8'b11100000;
            12'h623: glyph8x16 = 8'b01100000;
            12'h624: glyph8x16 = 8'b01100000;
            12'h625: glyph8x16 = 8'b01111000;
            12'h626: glyph8x16 = 8'b01101100;
            12'h627: glyph8x16 = 8'b01100110;
            12'h628: glyph8x16 = 8'b01100110;
            12'h629: glyph8x16 = 8'b01100110;
            12'h62A: glyph8x16 = 8'b01100110;
            12'h62B: glyph8x16 = 8'b01111100;
            12'h62C: glyph8x16 = 8'b00000000;
            12'h62D: glyph8x16 = 8'b00000000;
            12'h62E: glyph8x16 = 8'b00000000;
            12'h62F: glyph8x16 = 8'b00000000;
            // 0x63 'c'
            12'h630: glyph8x16 = 8'b00000000;
            12'h631: glyph8x16 = 8'b00000000;
            12'h632: glyph8x16 = 8'b00000000;
            12'h633: glyph8x16 = 8'b00000000;
            12'h634: glyph8x16 = 8'b00000000;
            12'h635: glyph8x16 = 8'b01111100;
            12'h636: glyph8x16 = 8'b11000110;
            12'h637: glyph8x16 = 8'b11000000;
            12'h638: glyph8x16 = 8'b11000000;
            12'h639: glyph8x16 = 8'b11000000;
            12'h63A: glyph8x16 = 8'b11000110;
            12'h63B: glyph8x16 = 8'b01111100;
            12'h63C: glyph8x16 = 8'b00000000;
            12'h63D: glyph8x16 = 8'b00000000;
            12'h63E: glyph8x16 = 8'b00000000;
            12'h63F: glyph8x16 = 8'b00000000;
            // 0x64 'd'
            12'h640: glyph8x16 = 8'b00000000;
            12'h641: glyph8x16 = 8'b00000000;
            12'h642: glyph8x16 = 8'b00011100;
            12'h643: glyph8x16 = 8'b00001100;
            12'h644: glyph8x16 = 8'b00001100;
            12'h645: glyph8x16 = 8'b00111100;
            12'h646: glyph8x16 = 8'b01101100;
            12'h647: glyph8x16 = 8'b11001100;
            12'h648: glyph8x16 = 8'b11001100;
            12'h649: glyph8x16 = 8'b11001100;
            12'h64A: glyph8x16 = 8'b11001100;
            12'h64B: glyph8x16 = 8'b01110110;
            12'h64C: glyph8x16 = 8'b00000000;
            12'h64D: glyph8x16 = 8'b00000000;
            12'h64E: glyph8x16 = 8'b00000000;
            12'h64F: glyph8x16 = 8'b00000000;
            // 0x65 'e'
            12'h650: glyph8x16 = 8'b00000000;
            12'h651: glyph8x16 = 8'b00000000;
            12'h652: glyph8x16 = 8'b00000000;
            12'h653: glyph8x16 = 8'b00000000;
            12'h654: glyph8x16 = 8'b00000000;
            12'h655: glyph8x16 = 8'b01111100;
            12'h656: glyph8x16 = 8'b11000110;
            12'h657: glyph8x16 = 8'b11111110;
            12'h658: glyph8x16 = 8'b11000000;
            12'h659: glyph8x16 = 8'b11000000;
            12'h65A: glyph8x16 = 8'b11000110;
            12'h65B: glyph8x16 = 8'b01111100;
            12'h65C: glyph8x16 = 8'b00000000;
            12'h65D: glyph8x16 = 8'b00000000;
            12'h65E: glyph8x16 = 8'b00000000;
            12'h65F: glyph8x16 = 8'b00000000;
            // 0x66 'f'
            12'h660: glyph8x16 = 8'b00000000;
            12'h661: glyph8x16 = 8'b00000000;
            12'h662: glyph8x16 = 8'b00011100;
            12'h663: glyph8x16 = 8'b00110110;
            12'h664: glyph8x16 = 8'b00110010;
            12'h665: glyph8x16 = 8'b00110000;
            12'h666: glyph8x16 = 8'b01111000;
            12'h667: glyph8x16 = 8'b00110000;
            12'h668: glyph8x16 = 8'b00110000;
            12'h669: glyph8x16 = 8'b00110000;
            12'h66A: glyph8x16 = 8'b00110000;
            12'h66B: glyph8x16 = 8'b01111000;
            12'h66C: glyph8x16 = 8'b00000000;
            12'h66D: glyph8x16 = 8'b00000000;
            12'h66E: glyph8x16 = 8'b00000000;
            12'h66F: glyph8x16 = 8'b00000000;
            // 0x67 'g'
            12'h670: glyph8x16 = 8'b00000000;
            12'h671: glyph8x16 = 8'b00000000;
            12'h672: glyph8x16 = 8'b00000000;
            12'h673: glyph8x16 = 8'b00000000;
            12'h674: glyph8x16 = 8'b00000000;
            12'h675: glyph8x16 = 8'b01110110;
            12'h676: glyph8x16 = 8'b11001100;
            12'h677: glyph8x16 = 8'b11001100;
            12'h678: glyph8x16 = 8'b11001100;
            12'h679: glyph8x16 = 8'b11001100;
            12'h67A: glyph8x16 = 8'b11001100;
            12'h67B: glyph8x16 = 8'b01111100;
            12'h67C: glyph8x16 = 8'b00001100;
            12'h67D: glyph8x16 = 8'b11001100;
            12'h67E: glyph8x16 = 8'b01111000;
            12'h67F: glyph8x16 = 8'b00000000;
            // 0x68 'h'
            12'h680: glyph8x16 = 8'b00000000;
            12'h681: glyph8x16 = 8'b00000000;
            12'h682: glyph8x16 = 8'b11100000;
            12'h683: glyph8x16 = 8'b01100000;
            12'h684: glyph8x16 = 8'b01100000;
            12'h685: glyph8x16 = 8'b01101100;
            12'h686: glyph8x16 = 8'b01110110;
            12'h687: glyph8x16 = 8'b01100110;
            12'h688: glyph8x16 = 8'b01100110;
            12'h689: glyph8x16 = 8'b01100110;
            12'h68A: glyph8x16 = 8'b01100110;
            12'h68B: glyph8x16 = 8'b11100110;
            12'h68C: glyph8x16 = 8'b00000000;
            12'h68D: glyph8x16 = 8'b00000000;
            12'h68E: glyph8x16 = 8'b00000000;
            12'h68F: glyph8x16 = 8'b00000000;
            // 0x69 'i'
            12'h690: glyph8x16 = 8'b00000000;
            12'h691: glyph8x16 = 8'b00000000;
            12'h692: glyph8x16 = 8'b00011000;
            12'h693: glyph8x16 = 8'b00011000;
            12'h694: glyph8x16 = 8'b00000000;
            12'h695: glyph8x16 = 8'b00111000;
            12'h696: glyph8x16 = 8'b00011000;
            12'h697: glyph8x16 = 8'b00011000;
            12'h698: glyph8x16 = 8'b00011000;
            12'h699: glyph8x16 = 8'b00011000;
            12'h69A: glyph8x16 = 8'b00011000;
            12'h69B: glyph8x16 = 8'b00111100;
            12'h69C: glyph8x16 = 8'b00000000;
            12'h69D: glyph8x16 = 8'b00000000;
            12'h69E: glyph8x16 = 8'b00000000;
            12'h69F: glyph8x16 = 8'b00000000;
            // 0x6A 'j'
            12'h6A0: glyph8x16 = 8'b00000000;
            12'h6A1: glyph8x16 = 8'b00000000;
            12'h6A2: glyph8x16 = 8'b00000110;
            12'h6A3: glyph8x16 = 8'b00000110;
            12'h6A4: glyph8x16 = 8'b00000000;
            12'h6A5: glyph8x16 = 8'b00001110;
            12'h6A6: glyph8x16 = 8'b00000110;
            12'h6A7: glyph8x16 = 8'b00000110;
            12'h6A8: glyph8x16 = 8'b00000110;
            12'h6A9: glyph8x16 = 8'b00000110;
            12'h6AA: glyph8x16 = 8'b00000110;
            12'h6AB: glyph8x16 = 8'b00000110;
            12'h6AC: glyph8x16 = 8'b01100110;
            12'h6AD: glyph8x16 = 8'b01100110;
            12'h6AE: glyph8x16 = 8'b00111100;
            12'h6AF: glyph8x16 = 8'b00000000;
            // 0x6B 'k'
            12'h6B0: glyph8x16 = 8'b00000000;
            12'h6B1: glyph8x16 = 8'b00000000;
            12'h6B2: glyph8x16 = 8'b11100000;
            12'h6B3: glyph8x16 = 8'b01100000;
            12'h6B4: glyph8x16 = 8'b01100000;
            12'h6B5: glyph8x16 = 8'b01100110;
            12'h6B6: glyph8x16 = 8'b01101100;
            12'h6B7: glyph8x16 = 8'b01111000;
            12'h6B8: glyph8x16 = 8'b01111000;
            12'h6B9: glyph8x16 = 8'b01101100;
            12'h6BA: glyph8x16 = 8'b01100110;
            12'h6BB: glyph8x16 = 8'b11100110;
            12'h6BC: glyph8x16 = 8'b00000000;
            12'h6BD: glyph8x16 = 8'b00000000;
            12'h6BE: glyph8x16 = 8'b00000000;
            12'h6BF: glyph8x16 = 8'b00000000;
            // 0x6C 'l'
            12'h6C0: glyph8x16 = 8'b00000000;
            12'h6C1: glyph8x16 = 8'b00000000;
            12'h6C2: glyph8x16 = 8'b00111000;
            12'h6C3: glyph8x16 = 8'b00011000;
            12'h6C4: glyph8x16 = 8'b00011000;
            12'h6C5: glyph8x16 = 8'b00011000;
            12'h6C6: glyph8x16 = 8'b00011000;
            12'h6C7: glyph8x16 = 8'b00011000;
            12'h6C8: glyph8x16 = 8'b00011000;
            12'h6C9: glyph8x16 = 8'b00011000;
            12'h6CA: glyph8x16 = 8'b00011000;
            12'h6CB: glyph8x16 = 8'b00111100;
            12'h6CC: glyph8x16 = 8'b00000000;
            12'h6CD: glyph8x16 = 8'b00000000;
            12'h6CE: glyph8x16 = 8'b00000000;
            12'h6CF: glyph8x16 = 8'b00000000;
            // 0x6D 'm'
            12'h6D0: glyph8x16 = 8'b00000000;
            12'h6D1: glyph8x16 = 8'b00000000;
            12'h6D2: glyph8x16 = 8'b00000000;
            12'h6D3: glyph8x16 = 8'b00000000;
            12'h6D4: glyph8x16 = 8'b00000000;
            12'h6D5: glyph8x16 = 8'b11101100;
            12'h6D6: glyph8x16 = 8'b11111110;
            12'h6D7: glyph8x16 = 8'b11010110;
            12'h6D8: glyph8x16 = 8'b11010110;
            12'h6D9: glyph8x16 = 8'b11010110;
            12'h6DA: glyph8x16 = 8'b11010110;
            12'h6DB: glyph8x16 = 8'b11000110;
            12'h6DC: glyph8x16 = 8'b00000000;
            12'h6DD: glyph8x16 = 8'b00000000;
            12'h6DE: glyph8x16 = 8'b00000000;
            12'h6DF: glyph8x16 = 8'b00000000;
            // 0x6E 'n'
            12'h6E0: glyph8x16 = 8'b00000000;
            12'h6E1: glyph8x16 = 8'b00000000;
            12'h6E2: glyph8x16 = 8'b00000000;
            12'h6E3: glyph8x16 = 8'b00000000;
            12'h6E4: glyph8x16 = 8'b00000000;
            12'h6E5: glyph8x16 = 8'b11011100;
            12'h6E6: glyph8x16 = 8'b01100110;
            12'h6E7: glyph8x16 = 8'b01100110;
            12'h6E8: glyph8x16 = 8'b01100110;
            12'h6E9: glyph8x16 = 8'b01100110;
            12'h6EA: glyph8x16 = 8'b01100110;
            12'h6EB: glyph8x16 = 8'b01100110;
            12'h6EC: glyph8x16 = 8'b00000000;
            12'h6ED: glyph8x16 = 8'b00000000;
            12'h6EE: glyph8x16 = 8'b00000000;
            12'h6EF: glyph8x16 = 8'b00000000;
            // 0x6F 'o'
            12'h6F0: glyph8x16 = 8'b00000000;
            12'h6F1: glyph8x16 = 8'b00000000;
            12'h6F2: glyph8x16 = 8'b00000000;
            12'h6F3: glyph8x16 = 8'b00000000;
            12'h6F4: glyph8x16 = 8'b00000000;
            12'h6F5: glyph8x16 = 8'b01111100;
            12'h6F6: glyph8x16 = 8'b11000110;
            12'h6F7: glyph8x16 = 8'b11000110;
            12'h6F8: glyph8x16 = 8'b11000110;
            12'h6F9: glyph8x16 = 8'b11000110;
            12'h6FA: glyph8x16 = 8'b11000110;
            12'h6FB: glyph8x16 = 8'b01111100;
            12'h6FC: glyph8x16 = 8'b00000000;
            12'h6FD: glyph8x16 = 8'b00000000;
            12'h6FE: glyph8x16 = 8'b00000000;
            12'h6FF: glyph8x16 = 8'b00000000;
            // 0x70 'p'
            12'h700: glyph8x16 = 8'b00000000;
            12'h701: glyph8x16 = 8'b00000000;
            12'h702: glyph8x16 = 8'b00000000;
            12'h703: glyph8x16 = 8'b00000000;
            12'h704: glyph8x16 = 8'b00000000;
            12'h705: glyph8x16 = 8'b11011100;
            12'h706: glyph8x16 = 8'b01100110;
            12'h707: glyph8x16 = 8'b01100110;
            12'h708: glyph8x16 = 8'b01100110;
            12'h709: glyph8x16 = 8'b01100110;
            12'h70A: glyph8x16 = 8'b01100110;
            12'h70B: glyph8x16 = 8'b01111100;
            12'h70C: glyph8x16 = 8'b01100000;
            12'h70D: glyph8x16 = 8'b01100000;
            12'h70E: glyph8x16 = 8'b11110000;
            12'h70F: glyph8x16 = 8'b00000000;
            // 0x71 'q'
            12'h710: glyph8x16 = 8'b00000000;
            12'h711: glyph8x16 = 8'b00000000;
            12'h712: glyph8x16 = 8'b00000000;
            12'h713: glyph8x16 = 8'b00000000;
            12'h714: glyph8x16 = 8'b00000000;
            12'h715: glyph8x16 = 8'b01110110;
            12'h716: glyph8x16 = 8'b11001100;
            12'h717: glyph8x16 = 8'b11001100;
            12'h718: glyph8x16 = 8'b11001100;
            12'h719: glyph8x16 = 8'b11001100;
            12'h71A: glyph8x16 = 8'b11001100;
            12'h71B: glyph8x16 = 8'b01111100;
            12'h71C: glyph8x16 = 8'b00001100;
            12'h71D: glyph8x16 = 8'b00001100;
            12'h71E: glyph8x16 = 8'b00011110;
            12'h71F: glyph8x16 = 8'b00000000;
            // 0x72 'r'
            12'h720: glyph8x16 = 8'b00000000;
            12'h721: glyph8x16 = 8'b00000000;
            12'h722: glyph8x16 = 8'b00000000;
            12'h723: glyph8x16 = 8'b00000000;
            12'h724: glyph8x16 = 8'b00000000;
            12'h725: glyph8x16 = 8'b11011100;
            12'h726: glyph8x16 = 8'b01110110;
            12'h727: glyph8x16 = 8'b01100110;
            12'h728: glyph8x16 = 8'b01100000;
            12'h729: glyph8x16 = 8'b01100000;
            12'h72A: glyph8x16 = 8'b01100000;
            12'h72B: glyph8x16 = 8'b11110000;
            12'h72C: glyph8x16 = 8'b00000000;
            12'h72D: glyph8x16 = 8'b00000000;
            12'h72E: glyph8x16 = 8'b00000000;
            12'h72F: glyph8x16 = 8'b00000000;
            // 0x73 's'
            12'h730: glyph8x16 = 8'b00000000;
            12'h731: glyph8x16 = 8'b00000000;
            12'h732: glyph8x16 = 8'b00000000;
            12'h733: glyph8x16 = 8'b00000000;
            12'h734: glyph8x16 = 8'b00000000;
            12'h735: glyph8x16 = 8'b01111100;
            12'h736: glyph8x16 = 8'b11000110;
            12'h737: glyph8x16 = 8'b01100000;
            12'h738: glyph8x16 = 8'b00111000;
            12'h739: glyph8x16 = 8'b00001100;
            12'h73A: glyph8x16 = 8'b11000110;
            12'h73B: glyph8x16 = 8'b01111100;
            12'h73C: glyph8x16 = 8'b00000000;
            12'h73D: glyph8x16 = 8'b00000000;
            12'h73E: glyph8x16 = 8'b00000000;
            12'h73F: glyph8x16 = 8'b00000000;
            // 0x74 't'
            12'h740: glyph8x16 = 8'b00000000;
            12'h741: glyph8x16 = 8'b00000000;
            12'h742: glyph8x16 = 8'b00010000;
            12'h743: glyph8x16 = 8'b00110000;
            12'h744: glyph8x16 = 8'b00110000;
            12'h745: glyph8x16 = 8'b11111100;
            12'h746: glyph8x16 = 8'b00110000;
            12'h747: glyph8x16 = 8'b00110000;
            12'h748: glyph8x16 = 8'b00110000;
            12'h749: glyph8x16 = 8'b00110000;
            12'h74A: glyph8x16 = 8'b00110110;
            12'h74B: glyph8x16 = 8'b00011100;
            12'h74C: glyph8x16 = 8'b00000000;
            12'h74D: glyph8x16 = 8'b00000000;
            12'h74E: glyph8x16 = 8'b00000000;
            12'h74F: glyph8x16 = 8'b00000000;
            // 0x75 'u'
            12'h750: glyph8x16 = 8'b00000000;
            12'h751: glyph8x16 = 8'b00000000;
            12'h752: glyph8x16 = 8'b00000000;
            12'h753: glyph8x16 = 8'b00000000;
            12'h754: glyph8x16 = 8'b00000000;
            12'h755: glyph8x16 = 8'b11001100;
            12'h756: glyph8x16 = 8'b11001100;
            12'h757: glyph8x16 = 8'b11001100;
            12'h758: glyph8x16 = 8'b11001100;
            12'h759: glyph8x16 = 8'b11001100;
            12'h75A: glyph8x16 = 8'b11001100;
            12'h75B: glyph8x16 = 8'b01110110;
            12'h75C: glyph8x16 = 8'b00000000;
            12'h75D: glyph8x16 = 8'b00000000;
            12'h75E: glyph8x16 = 8'b00000000;
            12'h75F: glyph8x16 = 8'b00000000;
            // 0x76 'v'
            12'h760: glyph8x16 = 8'b00000000;
            12'h761: glyph8x16 = 8'b00000000;
            12'h762: glyph8x16 = 8'b00000000;
            12'h763: glyph8x16 = 8'b00000000;
            12'h764: glyph8x16 = 8'b00000000;
            12'h765: glyph8x16 = 8'b11000110;
            12'h766: glyph8x16 = 8'b11000110;
            12'h767: glyph8x16 = 8'b11000110;
            12'h768: glyph8x16 = 8'b11000110;
            12'h769: glyph8x16 = 8'b11000110;
            12'h76A: glyph8x16 = 8'b01101100;
            12'h76B: glyph8x16 = 8'b00111000;
            12'h76C: glyph8x16 = 8'b00000000;
            12'h76D: glyph8x16 = 8'b00000000;
            12'h76E: glyph8x16 = 8'b00000000;
            12'h76F: glyph8x16 = 8'b00000000;
            // 0x77 'w'
            12'h770: glyph8x16 = 8'b00000000;
            12'h771: glyph8x16 = 8'b00000000;
            12'h772: glyph8x16 = 8'b00000000;
            12'h773: glyph8x16 = 8'b00000000;
            12'h774: glyph8x16 = 8'b00000000;
            12'h775: glyph8x16 = 8'b11000110;
            12'h776: glyph8x16 = 8'b11000110;
            12'h777: glyph8x16 = 8'b11010110;
            12'h778: glyph8x16 = 8'b11010110;
            12'h779: glyph8x16 = 8'b11010110;
            12'h77A: glyph8x16 = 8'b11111110;
            12'h77B: glyph8x16 = 8'b01101100;
            12'h77C: glyph8x16 = 8'b00000000;
            12'h77D: glyph8x16 = 8'b00000000;
            12'h77E: glyph8x16 = 8'b00000000;
            12'h77F: glyph8x16 = 8'b00000000;
            // 0x78 'x'
            12'h780: glyph8x16 = 8'b00000000;
            12'h781: glyph8x16 = 8'b00000000;
            12'h782: glyph8x16 = 8'b00000000;
            12'h783: glyph8x16 = 8'b00000000;
            12'h784: glyph8x16 = 8'b00000000;
            12'h785: glyph8x16 = 8'b11000110;
            12'h786: glyph8x16 = 8'b01101100;
            12'h787: glyph8x16 = 8'b00111000;
            12'h788: glyph8x16 = 8'b00111000;
            12'h789: glyph8x16 = 8'b00111000;
            12'h78A: glyph8x16 = 8'b01101100;
            12'h78B: glyph8x16 = 8'b11000110;
            12'h78C: glyph8x16 = 8'b00000000;
            12'h78D: glyph8x16 = 8'b00000000;
            12'h78E: glyph8x16 = 8'b00000000;
            12'h78F: glyph8x16 = 8'b00000000;
            // 0x79 'y'
            12'h790: glyph8x16 = 8'b00000000;
            12'h791: glyph8x16 = 8'b00000000;
            12'h792: glyph8x16 = 8'b00000000;
            12'h793: glyph8x16 = 8'b00000000;
            12'h794: glyph8x16 = 8'b00000000;
            12'h795: glyph8x16 = 8'b11000110;
            12'h796: glyph8x16 = 8'b11000110;
            12'h797: glyph8x16 = 8'b11000110;
            12'h798: glyph8x16 = 8'b11000110;
            12'h799: glyph8x16 = 8'b11000110;
            12'h79A: glyph8x16 = 8'b11000110;
            12'h79B: glyph8x16 = 8'b01111110;
            12'h79C: glyph8x16 = 8'b00000110;
            12'h79D: glyph8x16 = 8'b00001100;
            12'h79E: glyph8x16 = 8'b11111000;
            12'h79F: glyph8x16 = 8'b00000000;
            // 0x7A 'z'
            12'h7A0: glyph8x16 = 8'b00000000;
            12'h7A1: glyph8x16 = 8'b00000000;
            12'h7A2: glyph8x16 = 8'b00000000;
            12'h7A3: glyph8x16 = 8'b00000000;
            12'h7A4: glyph8x16 = 8'b00000000;
            12'h7A5: glyph8x16 = 8'b11111110;
            12'h7A6: glyph8x16 = 8'b11001100;
            12'h7A7: glyph8x16 = 8'b00011000;
            12'h7A8: glyph8x16 = 8'b00110000;
            12'h7A9: glyph8x16 = 8'b01100000;
            12'h7AA: glyph8x16 = 8'b11000110;
            12'h7AB: glyph8x16 = 8'b11111110;
            12'h7AC: glyph8x16 = 8'b00000000;
            12'h7AD: glyph8x16 = 8'b00000000;
            12'h7AE: glyph8x16 = 8'b00000000;
            12'h7AF: glyph8x16 = 8'b00000000;
            // 0x7B '{'
            12'h7B0: glyph8x16 = 8'b00000000;
            12'h7B1: glyph8x16 = 8'b00000000;
            12'h7B2: glyph8x16 = 8'b00001110;
            12'h7B3: glyph8x16 = 8'b00011000;
            12'h7B4: glyph8x16 = 8'b00011000;
            12'h7B5: glyph8x16 = 8'b00011000;
            12'h7B6: glyph8x16 = 8'b01110000;
            12'h7B7: glyph8x16 = 8'b00011000;
            12'h7B8: glyph8x16 = 8'b00011000;
            12'h7B9: glyph8x16 = 8'b00011000;
            12'h7BA: glyph8x16 = 8'b00011000;
            12'h7BB: glyph8x16 = 8'b00001110;
            12'h7BC: glyph8x16 = 8'b00000000;
            12'h7BD: glyph8x16 = 8'b00000000;
            12'h7BE: glyph8x16 = 8'b00000000;
            12'h7BF: glyph8x16 = 8'b00000000;
            // 0x7C '|'
            12'h7C0: glyph8x16 = 8'b00000000;
            12'h7C1: glyph8x16 = 8'b00000000;
            12'h7C2: glyph8x16 = 8'b00011000;
            12'h7C3: glyph8x16 = 8'b00011000;
            12'h7C4: glyph8x16 = 8'b00011000;
            12'h7C5: glyph8x16 = 8'b00011000;
            12'h7C6: glyph8x16 = 8'b00011000;
            12'h7C7: glyph8x16 = 8'b00011000;
            12'h7C8: glyph8x16 = 8'b00011000;
            12'h7C9: glyph8x16 = 8'b00011000;
            12'h7CA: glyph8x16 = 8'b00011000;
            12'h7CB: glyph8x16 = 8'b00011000;
            12'h7CC: glyph8x16 = 8'b00000000;
            12'h7CD: glyph8x16 = 8'b00000000;
            12'h7CE: glyph8x16 = 8'b00000000;
            12'h7CF: glyph8x16 = 8'b00000000;
            // 0x7D '}'
            12'h7D0: glyph8x16 = 8'b00000000;
            12'h7D1: glyph8x16 = 8'b00000000;
            12'h7D2: glyph8x16 = 8'b01110000;
            12'h7D3: glyph8x16 = 8'b00011000;
            12'h7D4: glyph8x16 = 8'b00011000;
            12'h7D5: glyph8x16 = 8'b00011000;
            12'h7D6: glyph8x16 = 8'b00001110;
            12'h7D7: glyph8x16 = 8'b00011000;
            12'h7D8: glyph8x16 = 8'b00011000;
            12'h7D9: glyph8x16 = 8'b00011000;
            12'h7DA: glyph8x16 = 8'b00011000;
            12'h7DB: glyph8x16 = 8'b01110000;
            12'h7DC: glyph8x16 = 8'b00000000;
            12'h7DD: glyph8x16 = 8'b00000000;
            12'h7DE: glyph8x16 = 8'b00000000;
            12'h7DF: glyph8x16 = 8'b00000000;
            // 0x7E '~'
            12'h7E0: glyph8x16 = 8'b00000000;
            12'h7E1: glyph8x16 = 8'b01110110;
            12'h7E2: glyph8x16 = 8'b11011100;
            12'h7E3: glyph8x16 = 8'b00000000;
            12'h7E4: glyph8x16 = 8'b00000000;
            12'h7E5: glyph8x16 = 8'b00000000;
            12'h7E6: glyph8x16 = 8'b00000000;
            12'h7E7: glyph8x16 = 8'b00000000;
            12'h7E8: glyph8x16 = 8'b00000000;
            12'h7E9: glyph8x16 = 8'b00000000;
            12'h7EA: glyph8x16 = 8'b00000000;
            12'h7EB: glyph8x16 = 8'b00000000;
            12'h7EC: glyph8x16 = 8'b00000000;
            12'h7ED: glyph8x16 = 8'b00000000;
            12'h7EE: glyph8x16 = 8'b00000000;
            12'h7EF: glyph8x16 = 8'b00000000;
            default:     glyph8x16 = 8'h00;
        endcase
    endfunction

    // >>> CJK-ROM-BEGIN (auto-generated by tools/inject_cjk.py, 勿手改) >>>
    function [15:0] cjk16;
        input [4:0] gid;
        input [3:0] rw;
        case ({gid, rw})
            9'd0: cjk16 = 16'h0000; // \" \" row 0
            9'd1: cjk16 = 16'h0000; // \" \" row 1
            9'd2: cjk16 = 16'h0000; // \" \" row 2
            9'd3: cjk16 = 16'h0000; // \" \" row 3
            9'd4: cjk16 = 16'h0000; // \" \" row 4
            9'd5: cjk16 = 16'h0000; // \" \" row 5
            9'd6: cjk16 = 16'h0000; // \" \" row 6
            9'd7: cjk16 = 16'h0000; // \" \" row 7
            9'd8: cjk16 = 16'h0000; // \" \" row 8
            9'd9: cjk16 = 16'h0000; // \" \" row 9
            9'd10: cjk16 = 16'h0000; // \" \" row 10
            9'd11: cjk16 = 16'h0000; // \" \" row 11
            9'd12: cjk16 = 16'h0000; // \" \" row 12
            9'd13: cjk16 = 16'h0000; // \" \" row 13
            9'd14: cjk16 = 16'h0000; // \" \" row 14
            9'd15: cjk16 = 16'h0000; // \" \" row 15
            9'd16: cjk16 = 16'h0200; // \"台\" row 0
            9'd17: cjk16 = 16'h0200; // \"台\" row 1
            9'd18: cjk16 = 16'h0400; // \"台\" row 2
            9'd19: cjk16 = 16'h0820; // \"台\" row 3
            9'd20: cjk16 = 16'h1010; // \"台\" row 4
            9'd21: cjk16 = 16'h2008; // \"台\" row 5
            9'd22: cjk16 = 16'h7FFC; // \"台\" row 6
            9'd23: cjk16 = 16'h2004; // \"台\" row 7
            9'd24: cjk16 = 16'h0000; // \"台\" row 8
            9'd25: cjk16 = 16'h1FF0; // \"台\" row 9
            9'd26: cjk16 = 16'h1010; // \"台\" row 10
            9'd27: cjk16 = 16'h1010; // \"台\" row 11
            9'd28: cjk16 = 16'h1010; // \"台\" row 12
            9'd29: cjk16 = 16'h1010; // \"台\" row 13
            9'd30: cjk16 = 16'h1FF0; // \"台\" row 14
            9'd31: cjk16 = 16'h1010; // \"台\" row 15
            9'd32: cjk16 = 16'h0000; // \"风\" row 0
            9'd33: cjk16 = 16'h3FF0; // \"风\" row 1
            9'd34: cjk16 = 16'h2010; // \"风\" row 2
            9'd35: cjk16 = 16'h2010; // \"风\" row 3
            9'd36: cjk16 = 16'h2850; // \"风\" row 4
            9'd37: cjk16 = 16'h2450; // \"风\" row 5
            9'd38: cjk16 = 16'h2290; // \"风\" row 6
            9'd39: cjk16 = 16'h2290; // \"风\" row 7
            9'd40: cjk16 = 16'h2110; // \"风\" row 8
            9'd41: cjk16 = 16'h2110; // \"风\" row 9
            9'd42: cjk16 = 16'h2290; // \"风\" row 10
            9'd43: cjk16 = 16'h2292; // \"风\" row 11
            9'd44: cjk16 = 16'h244A; // \"风\" row 12
            9'd45: cjk16 = 16'h484A; // \"风\" row 13
            9'd46: cjk16 = 16'h4006; // \"风\" row 14
            9'd47: cjk16 = 16'h8002; // \"风\" row 15
            9'd48: cjk16 = 16'h0000; // \"预\" row 0
            9'd49: cjk16 = 16'hF9FE; // \"预\" row 1
            9'd50: cjk16 = 16'h0820; // \"预\" row 2
            9'd51: cjk16 = 16'h5040; // \"预\" row 3
            9'd52: cjk16 = 16'h21FC; // \"预\" row 4
            9'd53: cjk16 = 16'h1104; // \"预\" row 5
            9'd54: cjk16 = 16'hFD24; // \"预\" row 6
            9'd55: cjk16 = 16'h2524; // \"预\" row 7
            9'd56: cjk16 = 16'h2924; // \"预\" row 8
            9'd57: cjk16 = 16'h2124; // \"预\" row 9
            9'd58: cjk16 = 16'h2124; // \"预\" row 10
            9'd59: cjk16 = 16'h2144; // \"预\" row 11
            9'd60: cjk16 = 16'h2050; // \"预\" row 12
            9'd61: cjk16 = 16'h2088; // \"预\" row 13
            9'd62: cjk16 = 16'hA104; // \"预\" row 14
            9'd63: cjk16 = 16'h4202; // \"预\" row 15
            9'd64: cjk16 = 16'h2420; // \"警\" row 0
            9'd65: cjk16 = 16'hFF20; // \"警\" row 1
            9'd66: cjk16 = 16'h247E; // \"警\" row 2
            9'd67: cjk16 = 16'h7EC4; // \"警\" row 3
            9'd68: cjk16 = 16'h8228; // \"警\" row 4
            9'd69: cjk16 = 16'h7A10; // \"警\" row 5
            9'd70: cjk16 = 16'h4A28; // \"警\" row 6
            9'd71: cjk16 = 16'h7AC6; // \"警\" row 7
            9'd72: cjk16 = 16'h0500; // \"警\" row 8
            9'd73: cjk16 = 16'hFFFE; // \"警\" row 9
            9'd74: cjk16 = 16'h0000; // \"警\" row 10
            9'd75: cjk16 = 16'h3FF8; // \"警\" row 11
            9'd76: cjk16 = 16'h0000; // \"警\" row 12
            9'd77: cjk16 = 16'h3FF8; // \"警\" row 13
            9'd78: cjk16 = 16'h2008; // \"警\" row 14
            9'd79: cjk16 = 16'h3FF8; // \"警\" row 15
            9'd80: cjk16 = 16'h0200; // \"立\" row 0
            9'd81: cjk16 = 16'h0100; // \"立\" row 1
            9'd82: cjk16 = 16'h0100; // \"立\" row 2
            9'd83: cjk16 = 16'h0000; // \"立\" row 3
            9'd84: cjk16 = 16'h7FFC; // \"立\" row 4
            9'd85: cjk16 = 16'h0000; // \"立\" row 5
            9'd86: cjk16 = 16'h0010; // \"立\" row 6
            9'd87: cjk16 = 16'h1010; // \"立\" row 7
            9'd88: cjk16 = 16'h0820; // \"立\" row 8
            9'd89: cjk16 = 16'h0820; // \"立\" row 9
            9'd90: cjk16 = 16'h0440; // \"立\" row 10
            9'd91: cjk16 = 16'h0440; // \"立\" row 11
            9'd92: cjk16 = 16'h0480; // \"立\" row 12
            9'd93: cjk16 = 16'h0000; // \"立\" row 13
            9'd94: cjk16 = 16'hFFFE; // \"立\" row 14
            9'd95: cjk16 = 16'h0000; // \"立\" row 15
            9'd96: cjk16 = 16'h0000; // \"即\" row 0
            9'd97: cjk16 = 16'h7E7C; // \"即\" row 1
            9'd98: cjk16 = 16'h4244; // \"即\" row 2
            9'd99: cjk16 = 16'h4244; // \"即\" row 3
            9'd100: cjk16 = 16'h7E44; // \"即\" row 4
            9'd101: cjk16 = 16'h4244; // \"即\" row 5
            9'd102: cjk16 = 16'h4244; // \"即\" row 6
            9'd103: cjk16 = 16'h7E44; // \"即\" row 7
            9'd104: cjk16 = 16'h4044; // \"即\" row 8
            9'd105: cjk16 = 16'h4844; // \"即\" row 9
            9'd106: cjk16 = 16'h4454; // \"即\" row 10
            9'd107: cjk16 = 16'h4A48; // \"即\" row 11
            9'd108: cjk16 = 16'h5240; // \"即\" row 12
            9'd109: cjk16 = 16'h6040; // \"即\" row 13
            9'd110: cjk16 = 16'h0040; // \"即\" row 14
            9'd111: cjk16 = 16'h0040; // \"即\" row 15
            9'd112: cjk16 = 16'h2208; // \"撤\" row 0
            9'd113: cjk16 = 16'h2108; // \"撤\" row 1
            9'd114: cjk16 = 16'h27C8; // \"撤\" row 2
            9'd115: cjk16 = 16'h2210; // \"撤\" row 3
            9'd116: cjk16 = 16'hF49E; // \"撤\" row 4
            9'd117: cjk16 = 16'h2FD4; // \"撤\" row 5
            9'd118: cjk16 = 16'h2064; // \"撤\" row 6
            9'd119: cjk16 = 16'h2794; // \"撤\" row 7
            9'd120: cjk16 = 16'h3494; // \"撤\" row 8
            9'd121: cjk16 = 16'hE794; // \"撤\" row 9
            9'd122: cjk16 = 16'h2494; // \"撤\" row 10
            9'd123: cjk16 = 16'h2788; // \"撤\" row 11
            9'd124: cjk16 = 16'h2488; // \"撤\" row 12
            9'd125: cjk16 = 16'h2494; // \"撤\" row 13
            9'd126: cjk16 = 16'hA4A4; // \"撤\" row 14
            9'd127: cjk16 = 16'h45C2; // \"撤\" row 15
            9'd128: cjk16 = 16'h0200; // \"离\" row 0
            9'd129: cjk16 = 16'h0100; // \"离\" row 1
            9'd130: cjk16 = 16'hFFFE; // \"离\" row 2
            9'd131: cjk16 = 16'h0000; // \"离\" row 3
            9'd132: cjk16 = 16'h1450; // \"离\" row 4
            9'd133: cjk16 = 16'h1390; // \"离\" row 5
            9'd134: cjk16 = 16'h1450; // \"离\" row 6
            9'd135: cjk16 = 16'h1FF0; // \"离\" row 7
            9'd136: cjk16 = 16'h0100; // \"离\" row 8
            9'd137: cjk16 = 16'h7FFC; // \"离\" row 9
            9'd138: cjk16 = 16'h4204; // \"离\" row 10
            9'd139: cjk16 = 16'h4444; // \"离\" row 11
            9'd140: cjk16 = 16'h4FE4; // \"离\" row 12
            9'd141: cjk16 = 16'h4424; // \"离\" row 13
            9'd142: cjk16 = 16'h4014; // \"离\" row 14
            9'd143: cjk16 = 16'h4008; // \"离\" row 15
            9'd144: cjk16 = 16'h0400; // \"紧\" row 0
            9'd145: cjk16 = 16'h25FC; // \"紧\" row 1
            9'd146: cjk16 = 16'h2488; // \"紧\" row 2
            9'd147: cjk16 = 16'h2450; // \"紧\" row 3
            9'd148: cjk16 = 16'h2420; // \"紧\" row 4
            9'd149: cjk16 = 16'h2450; // \"紧\" row 5
            9'd150: cjk16 = 16'h028C; // \"紧\" row 6
            9'd151: cjk16 = 16'h0420; // \"紧\" row 7
            9'd152: cjk16 = 16'h1FC0; // \"紧\" row 8
            9'd153: cjk16 = 16'h0180; // \"紧\" row 9
            9'd154: cjk16 = 16'h0610; // \"紧\" row 10
            9'd155: cjk16 = 16'h3FF8; // \"紧\" row 11
            9'd156: cjk16 = 16'h0108; // \"紧\" row 12
            9'd157: cjk16 = 16'h1120; // \"紧\" row 13
            9'd158: cjk16 = 16'h2510; // \"紧\" row 14
            9'd159: cjk16 = 16'h4208; // \"紧\" row 15
            9'd160: cjk16 = 16'h0800; // \"急\" row 0
            9'd161: cjk16 = 16'h0FE0; // \"急\" row 1
            9'd162: cjk16 = 16'h1020; // \"急\" row 2
            9'd163: cjk16 = 16'h2040; // \"急\" row 3
            9'd164: cjk16 = 16'h5FF8; // \"急\" row 4
            9'd165: cjk16 = 16'h0008; // \"急\" row 5
            9'd166: cjk16 = 16'h0008; // \"急\" row 6
            9'd167: cjk16 = 16'h1FF8; // \"急\" row 7
            9'd168: cjk16 = 16'h0008; // \"急\" row 8
            9'd169: cjk16 = 16'h0008; // \"急\" row 9
            9'd170: cjk16 = 16'h3FF8; // \"急\" row 10
            9'd171: cjk16 = 16'h0200; // \"急\" row 11
            9'd172: cjk16 = 16'h5104; // \"急\" row 12
            9'd173: cjk16 = 16'h5112; // \"急\" row 13
            9'd174: cjk16 = 16'h9012; // \"急\" row 14
            9'd175: cjk16 = 16'h0FF0; // \"急\" row 15
            9'd176: cjk16 = 16'h0020; // \"疏\" row 0
            9'd177: cjk16 = 16'h0010; // \"疏\" row 1
            9'd178: cjk16 = 16'h7DFE; // \"疏\" row 2
            9'd179: cjk16 = 16'h0420; // \"疏\" row 3
            9'd180: cjk16 = 16'h0848; // \"疏\" row 4
            9'd181: cjk16 = 16'h1084; // \"疏\" row 5
            9'd182: cjk16 = 16'h51FE; // \"疏\" row 6
            9'd183: cjk16 = 16'h5002; // \"疏\" row 7
            9'd184: cjk16 = 16'h5CA8; // \"疏\" row 8
            9'd185: cjk16 = 16'h50A8; // \"疏\" row 9
            9'd186: cjk16 = 16'h50A8; // \"疏\" row 10
            9'd187: cjk16 = 16'h50A8; // \"疏\" row 11
            9'd188: cjk16 = 16'h5D2A; // \"疏\" row 12
            9'd189: cjk16 = 16'h712A; // \"疏\" row 13
            9'd190: cjk16 = 16'hC22A; // \"疏\" row 14
            9'd191: cjk16 = 16'h0406; // \"疏\" row 15
            9'd192: cjk16 = 16'h2420; // \"散\" row 0
            9'd193: cjk16 = 16'h2420; // \"散\" row 1
            9'd194: cjk16 = 16'h7E20; // \"散\" row 2
            9'd195: cjk16 = 16'h243E; // \"散\" row 3
            9'd196: cjk16 = 16'h2444; // \"散\" row 4
            9'd197: cjk16 = 16'hFF44; // \"散\" row 5
            9'd198: cjk16 = 16'h0044; // \"散\" row 6
            9'd199: cjk16 = 16'h7EA4; // \"散\" row 7
            9'd200: cjk16 = 16'h4228; // \"散\" row 8
            9'd201: cjk16 = 16'h7E28; // \"散\" row 9
            9'd202: cjk16 = 16'h4210; // \"散\" row 10
            9'd203: cjk16 = 16'h7E10; // \"散\" row 11
            9'd204: cjk16 = 16'h4228; // \"散\" row 12
            9'd205: cjk16 = 16'h4228; // \"散\" row 13
            9'd206: cjk16 = 16'h4A44; // \"散\" row 14
            9'd207: cjk16 = 16'h4482; // \"散\" row 15
            9'd208: cjk16 = 16'h0400; // \"危\" row 0
            9'd209: cjk16 = 16'h0400; // \"危\" row 1
            9'd210: cjk16 = 16'h0FF0; // \"危\" row 2
            9'd211: cjk16 = 16'h1010; // \"危\" row 3
            9'd212: cjk16 = 16'h2020; // \"危\" row 4
            9'd213: cjk16 = 16'h5FFC; // \"危\" row 5
            9'd214: cjk16 = 16'h1000; // \"危\" row 6
            9'd215: cjk16 = 16'h13F0; // \"危\" row 7
            9'd216: cjk16 = 16'h1210; // \"危\" row 8
            9'd217: cjk16 = 16'h1210; // \"危\" row 9
            9'd218: cjk16 = 16'h1250; // \"危\" row 10
            9'd219: cjk16 = 16'h1220; // \"危\" row 11
            9'd220: cjk16 = 16'h2204; // \"危\" row 12
            9'd221: cjk16 = 16'h2204; // \"危\" row 13
            9'd222: cjk16 = 16'h41FC; // \"危\" row 14
            9'd223: cjk16 = 16'h8000; // \"危\" row 15
            9'd224: cjk16 = 16'h0040; // \"险\" row 0
            9'd225: cjk16 = 16'h7840; // \"险\" row 1
            9'd226: cjk16 = 16'h48A0; // \"险\" row 2
            9'd227: cjk16 = 16'h50A0; // \"险\" row 3
            9'd228: cjk16 = 16'h5110; // \"险\" row 4
            9'd229: cjk16 = 16'h6208; // \"险\" row 5
            9'd230: cjk16 = 16'h55F6; // \"险\" row 6
            9'd231: cjk16 = 16'h4800; // \"险\" row 7
            9'd232: cjk16 = 16'h4888; // \"险\" row 8
            9'd233: cjk16 = 16'h4848; // \"险\" row 9
            9'd234: cjk16 = 16'h6A48; // \"险\" row 10
            9'd235: cjk16 = 16'h5150; // \"险\" row 11
            9'd236: cjk16 = 16'h4110; // \"险\" row 12
            9'd237: cjk16 = 16'h4020; // \"险\" row 13
            9'd238: cjk16 = 16'h47FE; // \"险\" row 14
            9'd239: cjk16 = 16'h4000; // \"险\" row 15
            9'd240: cjk16 = 16'h0000; // \"区\" row 0
            9'd241: cjk16 = 16'h7FFC; // \"区\" row 1
            9'd242: cjk16 = 16'h4000; // \"区\" row 2
            9'd243: cjk16 = 16'h4010; // \"区\" row 3
            9'd244: cjk16 = 16'h4410; // \"区\" row 4
            9'd245: cjk16 = 16'h4220; // \"区\" row 5
            9'd246: cjk16 = 16'h4140; // \"区\" row 6
            9'd247: cjk16 = 16'h4080; // \"区\" row 7
            9'd248: cjk16 = 16'h4140; // \"区\" row 8
            9'd249: cjk16 = 16'h4220; // \"区\" row 9
            9'd250: cjk16 = 16'h4410; // \"区\" row 10
            9'd251: cjk16 = 16'h4810; // \"区\" row 11
            9'd252: cjk16 = 16'h4000; // \"区\" row 12
            9'd253: cjk16 = 16'h4000; // \"区\" row 13
            9'd254: cjk16 = 16'h7FFE; // \"区\" row 14
            9'd255: cjk16 = 16'h0000; // \"区\" row 15
            9'd256: cjk16 = 16'h2014; // \"域\" row 0
            9'd257: cjk16 = 16'h2012; // \"域\" row 1
            9'd258: cjk16 = 16'h2010; // \"域\" row 2
            9'd259: cjk16 = 16'h27FE; // \"域\" row 3
            9'd260: cjk16 = 16'h2010; // \"域\" row 4
            9'd261: cjk16 = 16'hF810; // \"域\" row 5
            9'd262: cjk16 = 16'h23D2; // \"域\" row 6
            9'd263: cjk16 = 16'h2252; // \"域\" row 7
            9'd264: cjk16 = 16'h2252; // \"域\" row 8
            9'd265: cjk16 = 16'h2254; // \"域\" row 9
            9'd266: cjk16 = 16'h23D4; // \"域\" row 10
            9'd267: cjk16 = 16'h3808; // \"域\" row 11
            9'd268: cjk16 = 16'hE0EA; // \"域\" row 12
            9'd269: cjk16 = 16'h471A; // \"域\" row 13
            9'd270: cjk16 = 16'h0226; // \"域\" row 14
            9'd271: cjk16 = 16'h0042; // \"域\" row 15
            9'd272: cjk16 = 16'h0900; // \"集\" row 0
            9'd273: cjk16 = 16'h0880; // \"集\" row 1
            9'd274: cjk16 = 16'h1FFC; // \"集\" row 2
            9'd275: cjk16 = 16'h3080; // \"集\" row 3
            9'd276: cjk16 = 16'h5FF8; // \"集\" row 4
            9'd277: cjk16 = 16'h9080; // \"集\" row 5
            9'd278: cjk16 = 16'h1FF8; // \"集\" row 6
            9'd279: cjk16 = 16'h1080; // \"集\" row 7
            9'd280: cjk16 = 16'h1FFC; // \"集\" row 8
            9'd281: cjk16 = 16'h1100; // \"集\" row 9
            9'd282: cjk16 = 16'hFFFE; // \"集\" row 10
            9'd283: cjk16 = 16'h0540; // \"集\" row 11
            9'd284: cjk16 = 16'h0920; // \"集\" row 12
            9'd285: cjk16 = 16'h3118; // \"集\" row 13
            9'd286: cjk16 = 16'hC106; // \"集\" row 14
            9'd287: cjk16 = 16'h0100; // \"集\" row 15
            9'd288: cjk16 = 16'h0100; // \"合\" row 0
            9'd289: cjk16 = 16'h0100; // \"合\" row 1
            9'd290: cjk16 = 16'h0280; // \"合\" row 2
            9'd291: cjk16 = 16'h0440; // \"合\" row 3
            9'd292: cjk16 = 16'h0820; // \"合\" row 4
            9'd293: cjk16 = 16'h3018; // \"合\" row 5
            9'd294: cjk16 = 16'hCFE6; // \"合\" row 6
            9'd295: cjk16 = 16'h0000; // \"合\" row 7
            9'd296: cjk16 = 16'h0000; // \"合\" row 8
            9'd297: cjk16 = 16'h1FF0; // \"合\" row 9
            9'd298: cjk16 = 16'h1010; // \"合\" row 10
            9'd299: cjk16 = 16'h1010; // \"合\" row 11
            9'd300: cjk16 = 16'h1010; // \"合\" row 12
            9'd301: cjk16 = 16'h1010; // \"合\" row 13
            9'd302: cjk16 = 16'h1FF0; // \"合\" row 14
            9'd303: cjk16 = 16'h1010; // \"合\" row 15
            9'd304: cjk16 = 16'h0200; // \"点\" row 0
            9'd305: cjk16 = 16'h0200; // \"点\" row 1
            9'd306: cjk16 = 16'h0200; // \"点\" row 2
            9'd307: cjk16 = 16'h03FC; // \"点\" row 3
            9'd308: cjk16 = 16'h0200; // \"点\" row 4
            9'd309: cjk16 = 16'h0200; // \"点\" row 5
            9'd310: cjk16 = 16'h3FF0; // \"点\" row 6
            9'd311: cjk16 = 16'h2010; // \"点\" row 7
            9'd312: cjk16 = 16'h2010; // \"点\" row 8
            9'd313: cjk16 = 16'h2010; // \"点\" row 9
            9'd314: cjk16 = 16'h3FF0; // \"点\" row 10
            9'd315: cjk16 = 16'h0000; // \"点\" row 11
            9'd316: cjk16 = 16'h2488; // \"点\" row 12
            9'd317: cjk16 = 16'h2244; // \"点\" row 13
            9'd318: cjk16 = 16'h4244; // \"点\" row 14
            9'd319: cjk16 = 16'h8004; // \"点\" row 15
            9'd320: cjk16 = 16'h0800; // \"保\" row 0
            9'd321: cjk16 = 16'h0BF8; // \"保\" row 1
            9'd322: cjk16 = 16'h0A08; // \"保\" row 2
            9'd323: cjk16 = 16'h1208; // \"保\" row 3
            9'd324: cjk16 = 16'h1208; // \"保\" row 4
            9'd325: cjk16 = 16'h33F8; // \"保\" row 5
            9'd326: cjk16 = 16'h3040; // \"保\" row 6
            9'd327: cjk16 = 16'h5040; // \"保\" row 7
            9'd328: cjk16 = 16'h97FC; // \"保\" row 8
            9'd329: cjk16 = 16'h10E0; // \"保\" row 9
            9'd330: cjk16 = 16'h1150; // \"保\" row 10
            9'd331: cjk16 = 16'h1248; // \"保\" row 11
            9'd332: cjk16 = 16'h1444; // \"保\" row 12
            9'd333: cjk16 = 16'h1842; // \"保\" row 13
            9'd334: cjk16 = 16'h1040; // \"保\" row 14
            9'd335: cjk16 = 16'h1040; // \"保\" row 15
            9'd336: cjk16 = 16'h1020; // \"持\" row 0
            9'd337: cjk16 = 16'h1020; // \"持\" row 1
            9'd338: cjk16 = 16'h1020; // \"持\" row 2
            9'd339: cjk16 = 16'h11FC; // \"持\" row 3
            9'd340: cjk16 = 16'hFC20; // \"持\" row 4
            9'd341: cjk16 = 16'h1020; // \"持\" row 5
            9'd342: cjk16 = 16'h13FE; // \"持\" row 6
            9'd343: cjk16 = 16'h1008; // \"持\" row 7
            9'd344: cjk16 = 16'h1808; // \"持\" row 8
            9'd345: cjk16 = 16'h33FE; // \"持\" row 9
            9'd346: cjk16 = 16'hD008; // \"持\" row 10
            9'd347: cjk16 = 16'h1088; // \"持\" row 11
            9'd348: cjk16 = 16'h1048; // \"持\" row 12
            9'd349: cjk16 = 16'h1008; // \"持\" row 13
            9'd350: cjk16 = 16'h5028; // \"持\" row 14
            9'd351: cjk16 = 16'h2010; // \"持\" row 15
            9'd352: cjk16 = 16'h0040; // \"冷\" row 0
            9'd353: cjk16 = 16'h4040; // \"冷\" row 1
            9'd354: cjk16 = 16'h20A0; // \"冷\" row 2
            9'd355: cjk16 = 16'h20A0; // \"冷\" row 3
            9'd356: cjk16 = 16'h0110; // \"冷\" row 4
            9'd357: cjk16 = 16'h0248; // \"冷\" row 5
            9'd358: cjk16 = 16'h1426; // \"冷\" row 6
            9'd359: cjk16 = 16'h1020; // \"冷\" row 7
            9'd360: cjk16 = 16'h23F8; // \"冷\" row 8
            9'd361: cjk16 = 16'hE008; // \"冷\" row 9
            9'd362: cjk16 = 16'h2010; // \"冷\" row 10
            9'd363: cjk16 = 16'h2110; // \"冷\" row 11
            9'd364: cjk16 = 16'h20A0; // \"冷\" row 12
            9'd365: cjk16 = 16'h2040; // \"冷\" row 13
            9'd366: cjk16 = 16'h2020; // \"冷\" row 14
            9'd367: cjk16 = 16'h0020; // \"冷\" row 15
            9'd368: cjk16 = 16'h1040; // \"静\" row 0
            9'd369: cjk16 = 16'h1040; // \"静\" row 1
            9'd370: cjk16 = 16'hFE78; // \"静\" row 2
            9'd371: cjk16 = 16'h1088; // \"静\" row 3
            9'd372: cjk16 = 16'h7C10; // \"静\" row 4
            9'd373: cjk16 = 16'h11FC; // \"静\" row 5
            9'd374: cjk16 = 16'hFE24; // \"静\" row 6
            9'd375: cjk16 = 16'h0024; // \"静\" row 7
            9'd376: cjk16 = 16'h7DFE; // \"静\" row 8
            9'd377: cjk16 = 16'h4424; // \"静\" row 9
            9'd378: cjk16 = 16'h7C24; // \"静\" row 10
            9'd379: cjk16 = 16'h45FC; // \"静\" row 11
            9'd380: cjk16 = 16'h7C24; // \"静\" row 12
            9'd381: cjk16 = 16'h4420; // \"静\" row 13
            9'd382: cjk16 = 16'h54A0; // \"静\" row 14
            9'd383: cjk16 = 16'h4840; // \"静\" row 15
            9'd384: cjk16 = 16'h0820; // \"禁\" row 0
            9'd385: cjk16 = 16'h0820; // \"禁\" row 1
            9'd386: cjk16 = 16'h7EFC; // \"禁\" row 2
            9'd387: cjk16 = 16'h0820; // \"禁\" row 3
            9'd388: cjk16 = 16'h1C70; // \"禁\" row 4
            9'd389: cjk16 = 16'h2AA8; // \"禁\" row 5
            9'd390: cjk16 = 16'hC826; // \"禁\" row 6
            9'd391: cjk16 = 16'h0000; // \"禁\" row 7
            9'd392: cjk16 = 16'h3FF8; // \"禁\" row 8
            9'd393: cjk16 = 16'h0000; // \"禁\" row 9
            9'd394: cjk16 = 16'h0000; // \"禁\" row 10
            9'd395: cjk16 = 16'hFFFE; // \"禁\" row 11
            9'd396: cjk16 = 16'h0100; // \"禁\" row 12
            9'd397: cjk16 = 16'h1110; // \"禁\" row 13
            9'd398: cjk16 = 16'h2508; // \"禁\" row 14
            9'd399: cjk16 = 16'h4204; // \"禁\" row 15
            9'd400: cjk16 = 16'h0100; // \"止\" row 0
            9'd401: cjk16 = 16'h0100; // \"止\" row 1
            9'd402: cjk16 = 16'h0100; // \"止\" row 2
            9'd403: cjk16 = 16'h0100; // \"止\" row 3
            9'd404: cjk16 = 16'h1100; // \"止\" row 4
            9'd405: cjk16 = 16'h1100; // \"止\" row 5
            9'd406: cjk16 = 16'h11F8; // \"止\" row 6
            9'd407: cjk16 = 16'h1100; // \"止\" row 7
            9'd408: cjk16 = 16'h1100; // \"止\" row 8
            9'd409: cjk16 = 16'h1100; // \"止\" row 9
            9'd410: cjk16 = 16'h1100; // \"止\" row 10
            9'd411: cjk16 = 16'h1100; // \"止\" row 11
            9'd412: cjk16 = 16'h1100; // \"止\" row 12
            9'd413: cjk16 = 16'h1100; // \"止\" row 13
            9'd414: cjk16 = 16'hFFFE; // \"止\" row 14
            9'd415: cjk16 = 16'h0000; // \"止\" row 15
            9'd416: cjk16 = 16'h0000; // \"通\" row 0
            9'd417: cjk16 = 16'h47F8; // \"通\" row 1
            9'd418: cjk16 = 16'h2010; // \"通\" row 2
            9'd419: cjk16 = 16'h21A0; // \"通\" row 3
            9'd420: cjk16 = 16'h0040; // \"通\" row 4
            9'd421: cjk16 = 16'h07FC; // \"通\" row 5
            9'd422: cjk16 = 16'hE444; // \"通\" row 6
            9'd423: cjk16 = 16'h2444; // \"通\" row 7
            9'd424: cjk16 = 16'h27FC; // \"通\" row 8
            9'd425: cjk16 = 16'h2444; // \"通\" row 9
            9'd426: cjk16 = 16'h2444; // \"通\" row 10
            9'd427: cjk16 = 16'h27FC; // \"通\" row 11
            9'd428: cjk16 = 16'h2444; // \"通\" row 12
            9'd429: cjk16 = 16'h2454; // \"通\" row 13
            9'd430: cjk16 = 16'h5408; // \"通\" row 14
            9'd431: cjk16 = 16'h8FFE; // \"通\" row 15
            9'd432: cjk16 = 16'h0800; // \"行\" row 0
            9'd433: cjk16 = 16'h09FC; // \"行\" row 1
            9'd434: cjk16 = 16'h1000; // \"行\" row 2
            9'd435: cjk16 = 16'h2000; // \"行\" row 3
            9'd436: cjk16 = 16'h4800; // \"行\" row 4
            9'd437: cjk16 = 16'h0800; // \"行\" row 5
            9'd438: cjk16 = 16'h13FE; // \"行\" row 6
            9'd439: cjk16 = 16'h3020; // \"行\" row 7
            9'd440: cjk16 = 16'h5020; // \"行\" row 8
            9'd441: cjk16 = 16'h9020; // \"行\" row 9
            9'd442: cjk16 = 16'h1020; // \"行\" row 10
            9'd443: cjk16 = 16'h1020; // \"行\" row 11
            9'd444: cjk16 = 16'h1020; // \"行\" row 12
            9'd445: cjk16 = 16'h1020; // \"行\" row 13
            9'd446: cjk16 = 16'h10A0; // \"行\" row 14
            9'd447: cjk16 = 16'h1040; // \"行\" row 15
            default: cjk16 = 16'h0000;
        endcase
    endfunction
    // <<< CJK-ROM-END

    // ------------------------------------------------------------------------
    // Geometry / addressing
    // ------------------------------------------------------------------------
    wire [11:0] dy        = y - BANNER_Y0;             // unsigned wrap: y < Y0 gives dy >= 4096
    wire        in_banner = de && (dy < BANNER_H);
    wire        line_sel  = dy[5];                     // rows 0..31 -> LINE0, 32..63 -> LINE1
    wire [3:0]  glyph_row = dy[4:1];                   // 2x vertical scale

    wire [5:0]  char_ix   = x[9:4];                    // x / 16  (0..39 inside 640 px)
    wire [2:0]  glyph_col = x[3:1];                    // 2x horizontal scale

    wire [5:0]  cx    = (char_ix >= MAX_CHARS) ? (MAX_CHARS - 6'd1) : char_ix;
    wire [8:0]  cbase = ({3'd0, MAX_CHARS} - 9'd1 - {3'd0, cx}) * 9'd8;   // v1-proven mapping
    wire [7:0]  ch    = LINE0_TEXT[cbase +: 8];  // v6: LINE0 only; msg row decoded below

    wire [7:0]  glyph   = glyph8x16(ch, glyph_row);
    wire [7:0]  mask    = 8'h80 >> glyph_col;          // bit7 = leftmost pixel

    // v3 CJK row0: full-width 32px cells, same combinational style (no RAM infer)
    wire [4:0]   cix2     = x[9:5];                            // 0..19 cell column
    wire [159:0] emg_ph   = (emg_sel == 2'd0) ? EMG_P0 :
                            (emg_sel == 2'd1) ? EMG_P1 : EMG_P2;
    wire [8:0]   ebase    = 9'd152 - {cix2, 3'b000};           // MSB-first byte pick (160bit vec, byte k at 8*(19-k))
    wire [7:0]   egid     = emg_ph[ebase +: 8];
    wire [15:0]  cjk_bits = cjk16(egid[4:0], glyph_row);
    wire [15:0]  cjk_msk  = 16'h8000 >> {1'b0, x[4:1]};
    wire         cjk_on   = |(cjk_bits & cjk_msk);

    wire         row0_emg = emg_mode && !line_sel;

    // v6 MSG row (line_sel band): 22 mixed slots, 16px each.  Per current
    // pixel: cell = x/16, col-in-cell = x%16; glyph_row = dy[4:1] gives the
    // usual 2x vertical scale over the 32-line band.  Half-width = built-in
    // 8x16 ROM drawn in the slot's LEFT 8px (right 8px blank); full-width =
    // rd_word (the 1R1W BRAM word, pre-issued one pixel ahead) tested
    // bit-parallel, bit15 = cell column 0; empty/out-of-range = background.
    wire        cell_ok   = (char_ix < 6'd22);
    wire [5:0]  mx        = cell_ok ? char_ix : 6'd21;
    wire [8:0]  mbase     = 9'd336 - {mx[4:0], 4'd0};
    wire [15:0] mcode     = msg_flat_a[mbase +: 16];
    wire        m_half    = (mcode[15:8] == 8'h00) && (mcode[7:0] != 8'h00);
    wire        m_full    = (mcode[15:8] >= 8'hA1) && (mcode[7:0] >= 8'hA1);
    wire [7:0]  mglyph8   = glyph8x16(mcode[7:0], glyph_row);
    wire        m_half_on = !x[3] && |(mglyph8 & (8'h80 >> x[2:0])); // LEFT 8px only
    wire        m_full_on = |(rd_word  & (16'h8000 >> x[3:0]));  // bit15 = leftmost
    wire        msg_on    = line_sel && cell_ok
                          && ((m_half && m_half_on) || (m_full && m_full_on));

    wire         text_on  = row0_emg ? cjk_on
                       :  line_sel   ? msg_on
                       :               |(glyph & mask);

    // background: each 8-bit channel x 0.5 (shift only)
    // v5c: emergency = red text (international alert convention), normal = user
    // palette (v7.2 "COL": 0 white,1 red,2 green,3 yellow,4 cyan,5 magenta,6 blue,7 orange)
    wire [23:0] pal_col =
          (txt_col_sel==3'd0) ? 24'hFFFFFF :
          (txt_col_sel==3'd1) ? 24'hFF3030 :
          (txt_col_sel==3'd2) ? 24'h40FF70 :
          (txt_col_sel==3'd3) ? 24'hFFE000 :
          (txt_col_sel==3'd4) ? 24'h40E0FF :
          (txt_col_sel==3'd5) ? 24'hFF50C8 :
          (txt_col_sel==3'd6) ? 24'h60A0FF :
                                24'hFF9040;               // 7 = orange
    wire [23:0] tcol = emg_mode ? 24'hFF3030 : pal_col;
    wire [23:0] bg_dark = { {1'b0, rgb_in[23:17]},
                            {1'b0, rgb_in[15:9]},
                            {1'b0, rgb_in[7:1]}  };

    assign rgb_out = !in_banner ? rgb_in
                   :  text_on   ? tcol
                   :              bg_dark;

endmodule

`default_nettype wire
