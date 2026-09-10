//-----------------------------------------------------------------------------
// osd_banner.v -- self-contained OSD "announcement banner" overlay (ours)
//
//   * Covers the bottom BANNER_H(=64) active lines of a 640x480 picture at
//     full width: darkens the background to half brightness (each RGB channel
//     >> 1, i.e. x0.5) and overlays 2 lines of 16x32 white text.
//   * Text rendered from the classic IBM VGA 8x16 ASCII bitmap font (glyph
//     shapes public domain; byte data extracted from the Linux kernel file
//     lib/fonts/font_8x16.c, font_vga_8x16, GPL-2.0), magnified 2x in X/Y.
//   * ASCII 8x16 font ROM: a 4096x8 `ascii_rom` array with a plain `initial`
//     per-word load (vendor picture_ram.v style, TD infer_rom=ON -> BRAM).
//     No $readmemh / external .mem file, avoiding TD ROM-file quirks.
//   * Purely combinational EXCEPT the two BRAM reads: x window compare +
//     640/16:1 char mux + sync ROM lookup (address pre-issued one pixel
//     ahead) + 1-bit mask test + 2-level output mux.  rgb_out stays
//     zero-delay; no dividers; timing-trivial at 25MHz.
//
//   v8: glyph8x16() combinational case -> ascii_rom 4096x8 BRAM (see 3).
//     Rendering behaviour is bit-identical; only the storage moved to BRAM.
//   Ports:  x,y  = pixel coords of rgb_in while de=1 (0..639 / 0..479)
//           de   = rgb_in pixel valid
//           rgb_in / rgb_out = 24-bit {R,G,B}
//
//   v6 (WP-B, OSD_CJK_CONTRACT): the MSG row is upgraded from 44 ASCII cols
//   to 22 MIXED slots (half-width ASCII + full-width GB2312 whose 16x16
//   dots are fetched from the onboard FLASH via glyph_xcd).  A refresh FSM
//   in the video domain walks the slots on msg_commit, one in-flight xcd
//   transaction at a time, and writes glyph_ram (true 1R1W BRAM) 与 4096x8
//   同步 ROM ascii_rom（v8, 取代旧 glyph8x16 组合 case 省 LUT, initial 数组
//   逐词加载）。The
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
//    - 22x16bit 码槽缓存复制三份(v8): msg_flat_a(渲染读) / msg_flat_b(FSM读)
//      / msg_flat_c(ascii_rom 预发地址读), 同一写口三备份, 各 1 读者 (TD 铁律)。
//    - glyph_ram[0:351] (16bit x 352 词, 真 BRAM 1R1W): 写口=刷新FSM(G_WR
//      状态连续16拍移位写入), 读口=渲染 (同步读, 地址提前一拍发出, 见下)。
//    - ascii_rom[0:4095] (8bit x 4096 词, 纯 ROM, v8): 数据=原 glyph8x16 表
//      逐词 initial; 读口与 glyph_ram 同一 always 块、同一预发节拍, 地址=
//      下一像素 (band, 码, 行), 复用 xrd/yrd/cixr/slotr/dyr 现有信号。
//      HDL-1007 预期: osd_banner 里恰好提取 2 个 RAM: glyph_ram(352x16
//      1R1W) 与 ascii_rom(4096x8, 日志应见 extracting RAM for identifier
//      'ascii_rom')。msg_flat_a/b/c 必须是纯寄存器+22:1 mux(沿用 v2b 平铺
//      向量+unrolled 写套路; v8 起 c 份唯一读者=ROM 预发地址), 不应再出现
//      在 RAM 抽取日志; 若 TD 把 msg_flat_* 抽成 RAM 或报数组不支持,
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
//      8x16 BRAM ROM, bit7=最左), 右 8px 空白; 全角读 rd_word 按位 (bit15=槽内
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

module osd_banner #(
    parameter [11:0] BANNER_Y0  = 12'd416,     // first banner line = 480 - 64
    parameter [11:0] BANNER_H   = 12'd64,      // banner height in lines
    parameter [5:0]  MAX_CHARS  = 6'd44,       // LINE0 cells (v6: msg row = 22x16bit slots now)
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
    input  wire [2:0]  sr_spd,      // v10.3 MSG row marquee px/frame (0=static)
    input  wire        col_exec,     // v10.1: 1-cycle COL execute strobe (unlocks emg red)
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
    // v6: message-line slot cache = 22 x 16-bit codes, as THREE identical FLAT (v8)
    // 352-bit vectors (code of slot m lives at [(336-16m) +: 16]; slot 0 is
    // leftmost, MSB-first, same layout trick that kept v2b's line1f out of
    // TD's broken async-RAM inference).  msg_flat_a is the render reader,
    // msg_flat_b the refresh-FSM reader, msg_flat_c the ascii_rom pre-address
    // reader -- one reader per copy (TD iron
    // rule: never two reads of one array in the same cycle).  Power-on
    // defaults are serial-loaded from the first 22 bytes of LINE1_TEXT as
    // half-width codes over the first 22 clocks.
    // ------------------------------------------------------------------------
    reg  [351:0] msg_flat_a;
    reg  [351:0] msg_flat_b;
    reg  [351:0] msg_flat_c;   // v8: 3rd copy, sole reader = ascii_rom pre-address
    reg  [4:0]   mi_ix;
    reg          mi_done;
    reg  [4:0]   k_mi;
    reg  [4:0]   k_mw;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msg_flat_a <= 352'd0;
            msg_flat_b <= 352'd0;
            msg_flat_c <= 352'd0;
            mi_ix      <= 5'd0;
            mi_done    <= 1'b0;
        end else if (!mi_done) begin
            // preset load, one slot per clock (constant part-selects only)
            for (k_mi = 5'd0; k_mi < 5'd22; k_mi = k_mi + 5'd1)
                if (mi_ix == k_mi) begin
                    msg_flat_a[(336 - {k_mi, 4'd0}) +: 16] <= {8'h00, LINE1_TEXT[(344 - {k_mi, 3'b000}) +: 8]};
                    msg_flat_b[(336 - {k_mi, 4'd0}) +: 16] <= {8'h00, LINE1_TEXT[(344 - {k_mi, 3'b000}) +: 8]};
                    msg_flat_c[(336 - {k_mi, 4'd0}) +: 16] <= {8'h00, LINE1_TEXT[(344 - {k_mi, 3'b000}) +: 8]};
                end
            if (msg_we)         mi_done <= 1'b1;  // a live write aborts preset
            else if (mi_ix == 5'd21) mi_done <= 1'b1;
            else                mi_ix   <= mi_ix + 5'd1;
        end else if (msg_we) begin
            for (k_mw = 5'd0; k_mw < 5'd22; k_mw = k_mw + 5'd1)
                if (msg_wslot == k_mw) begin
                    msg_flat_a[(336 - {k_mw, 4'd0}) +: 16] <= msg_wcode;
                    msg_flat_b[(336 - {k_mw, 4'd0}) +: 16] <= msg_wcode;
                    msg_flat_c[(336 - {k_mw, 4'd0}) +: 16] <= msg_wcode;
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

    // ---- v10.3 ext1: smooth marquee on the MSG row --------------------
    // msg_off advances sr_spd px once per frame; MSG-band geometry is
    // evaluated at wx=(x+msg_off) mod 352, so the ticker glides pixel by
    // pixel (no char-jump).  sr_spd==0 => msg_wrap = identity => pixels
    // bit-identical to v10.2 (golden regression safe).
    reg  [9:0] msg_off;
    wire       frame_top = de && (x == 12'd0) && (y == 12'd0);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)              msg_off <= 10'd0;
        else if (sr_spd != 3'd0 && frame_top) begin
            if (msg_off + {7'd0, sr_spd} >= 10'd352) msg_off <= msg_off + {7'd0, sr_spd} - 10'd352;
            else                                     msg_off <= msg_off + {7'd0, sr_spd};
        end
    end
    function automatic [9:0] msg_wrap; input [9:0] xv; reg [9:0] t;
    begin
        if (msg_off == 10'd0) msg_wrap = xv;  // identity while un-scrolled (incl. z sr_spd)
        else begin
            t = xv + msg_off;
            if (t >= 10'd352) t = t - 10'd352;
            if (t >= 10'd352) t = t - 10'd352;
            msg_wrap = t;
        end
    end
    endfunction

    // ---- render-side read port (address = NEXT pixel's {slot,row}) ----------
    // While de=1 the raster steps x -> x+1 (wrapping to x=0 / y+1 at 639).
    // While de=0 (blanking) the top counter sits at x=0 with y already =
    // first line of the upcoming row, so issuing {0, row(y)} every blank
    // cycle self-primes the line's first pixel and the word persists.
    wire [11:0] xnp     = (x == 12'd639) ? 12'd0     : (x + 12'd1);
    wire [11:0] ynp     = (x == 12'd639) ? (y + 12'd1) : y;
    wire [11:0] xrd     = de ? xnp : x;
    wire [11:0] yrd     = de ? ynp : y;
    wire [5:0]  cixr    = xrd[9:4];                     // next cell, LINE0 raw
    wire [9:0]  mcxr    = msg_wrap(xrd[9:0]);             // v10.3 scrolled next-px MSG x
    wire [4:0]  slotr   = (mcxr >= 10'd352) ? 5'd0 : mcxr[8:4];  // MSG cell from scroll window
    wire [11:0] dyr     = yrd - BANNER_Y0;
    wire [8:0]  rd_addr = {slotr, dyr[4:1]};
    reg  [15:0] rd_word;

    // ---- ASCII font BRAM ROM (v8) ------------------------------------------
    // ------------------------------------------------------------------------
    // v8: ASCII 8x16 font as a 4096x8 synchronous ROM (BRAM target).  Exact
    // replacement of the old glyph8x16() combinational case (same data, same
    // semantics: addr={ch[7:0],row[3:0]}, row0 = TOP, bit7 = leftmost pixel).
    // Unlisted codes (0x00..0x1F, 0x7F..0xFF) carry the old case default
    // 8'h00, so a BRAM readback equals glyph8x16() at ALL 4096 addresses.
    // `initial` per-word load style mirrors vendor DEMO/30_LCD_ATK
    // picture_ram.v; TD infer_rom (default ON) extracts it -- watch HDL-1007
    // for "extracting RAM for identifier 'ascii_rom'".  Single reader
    // (render pre-issue below); no write port.
    // ------------------------------------------------------------------------
    reg [7:0] ascii_rom [0:4095];

    initial begin
        // 0x00 -
        ascii_rom[12'h000] = 8'h00;
        ascii_rom[12'h001] = 8'h00;
        ascii_rom[12'h002] = 8'h00;
        ascii_rom[12'h003] = 8'h00;
        ascii_rom[12'h004] = 8'h00;
        ascii_rom[12'h005] = 8'h00;
        ascii_rom[12'h006] = 8'h00;
        ascii_rom[12'h007] = 8'h00;
        ascii_rom[12'h008] = 8'h00;
        ascii_rom[12'h009] = 8'h00;
        ascii_rom[12'h00A] = 8'h00;
        ascii_rom[12'h00B] = 8'h00;
        ascii_rom[12'h00C] = 8'h00;
        ascii_rom[12'h00D] = 8'h00;
        ascii_rom[12'h00E] = 8'h00;
        ascii_rom[12'h00F] = 8'h00;
        // 0x01 -
        ascii_rom[12'h010] = 8'h00;
        ascii_rom[12'h011] = 8'h00;
        ascii_rom[12'h012] = 8'h00;
        ascii_rom[12'h013] = 8'h00;
        ascii_rom[12'h014] = 8'h00;
        ascii_rom[12'h015] = 8'h00;
        ascii_rom[12'h016] = 8'h00;
        ascii_rom[12'h017] = 8'h00;
        ascii_rom[12'h018] = 8'h00;
        ascii_rom[12'h019] = 8'h00;
        ascii_rom[12'h01A] = 8'h00;
        ascii_rom[12'h01B] = 8'h00;
        ascii_rom[12'h01C] = 8'h00;
        ascii_rom[12'h01D] = 8'h00;
        ascii_rom[12'h01E] = 8'h00;
        ascii_rom[12'h01F] = 8'h00;
        // 0x02 -
        ascii_rom[12'h020] = 8'h00;
        ascii_rom[12'h021] = 8'h00;
        ascii_rom[12'h022] = 8'h00;
        ascii_rom[12'h023] = 8'h00;
        ascii_rom[12'h024] = 8'h00;
        ascii_rom[12'h025] = 8'h00;
        ascii_rom[12'h026] = 8'h00;
        ascii_rom[12'h027] = 8'h00;
        ascii_rom[12'h028] = 8'h00;
        ascii_rom[12'h029] = 8'h00;
        ascii_rom[12'h02A] = 8'h00;
        ascii_rom[12'h02B] = 8'h00;
        ascii_rom[12'h02C] = 8'h00;
        ascii_rom[12'h02D] = 8'h00;
        ascii_rom[12'h02E] = 8'h00;
        ascii_rom[12'h02F] = 8'h00;
        // 0x03 -
        ascii_rom[12'h030] = 8'h00;
        ascii_rom[12'h031] = 8'h00;
        ascii_rom[12'h032] = 8'h00;
        ascii_rom[12'h033] = 8'h00;
        ascii_rom[12'h034] = 8'h00;
        ascii_rom[12'h035] = 8'h00;
        ascii_rom[12'h036] = 8'h00;
        ascii_rom[12'h037] = 8'h00;
        ascii_rom[12'h038] = 8'h00;
        ascii_rom[12'h039] = 8'h00;
        ascii_rom[12'h03A] = 8'h00;
        ascii_rom[12'h03B] = 8'h00;
        ascii_rom[12'h03C] = 8'h00;
        ascii_rom[12'h03D] = 8'h00;
        ascii_rom[12'h03E] = 8'h00;
        ascii_rom[12'h03F] = 8'h00;
        // 0x04 -
        ascii_rom[12'h040] = 8'h00;
        ascii_rom[12'h041] = 8'h00;
        ascii_rom[12'h042] = 8'h00;
        ascii_rom[12'h043] = 8'h00;
        ascii_rom[12'h044] = 8'h00;
        ascii_rom[12'h045] = 8'h00;
        ascii_rom[12'h046] = 8'h00;
        ascii_rom[12'h047] = 8'h00;
        ascii_rom[12'h048] = 8'h00;
        ascii_rom[12'h049] = 8'h00;
        ascii_rom[12'h04A] = 8'h00;
        ascii_rom[12'h04B] = 8'h00;
        ascii_rom[12'h04C] = 8'h00;
        ascii_rom[12'h04D] = 8'h00;
        ascii_rom[12'h04E] = 8'h00;
        ascii_rom[12'h04F] = 8'h00;
        // 0x05 -
        ascii_rom[12'h050] = 8'h00;
        ascii_rom[12'h051] = 8'h00;
        ascii_rom[12'h052] = 8'h00;
        ascii_rom[12'h053] = 8'h00;
        ascii_rom[12'h054] = 8'h00;
        ascii_rom[12'h055] = 8'h00;
        ascii_rom[12'h056] = 8'h00;
        ascii_rom[12'h057] = 8'h00;
        ascii_rom[12'h058] = 8'h00;
        ascii_rom[12'h059] = 8'h00;
        ascii_rom[12'h05A] = 8'h00;
        ascii_rom[12'h05B] = 8'h00;
        ascii_rom[12'h05C] = 8'h00;
        ascii_rom[12'h05D] = 8'h00;
        ascii_rom[12'h05E] = 8'h00;
        ascii_rom[12'h05F] = 8'h00;
        // 0x06 -
        ascii_rom[12'h060] = 8'h00;
        ascii_rom[12'h061] = 8'h00;
        ascii_rom[12'h062] = 8'h00;
        ascii_rom[12'h063] = 8'h00;
        ascii_rom[12'h064] = 8'h00;
        ascii_rom[12'h065] = 8'h00;
        ascii_rom[12'h066] = 8'h00;
        ascii_rom[12'h067] = 8'h00;
        ascii_rom[12'h068] = 8'h00;
        ascii_rom[12'h069] = 8'h00;
        ascii_rom[12'h06A] = 8'h00;
        ascii_rom[12'h06B] = 8'h00;
        ascii_rom[12'h06C] = 8'h00;
        ascii_rom[12'h06D] = 8'h00;
        ascii_rom[12'h06E] = 8'h00;
        ascii_rom[12'h06F] = 8'h00;
        // 0x07 -
        ascii_rom[12'h070] = 8'h00;
        ascii_rom[12'h071] = 8'h00;
        ascii_rom[12'h072] = 8'h00;
        ascii_rom[12'h073] = 8'h00;
        ascii_rom[12'h074] = 8'h00;
        ascii_rom[12'h075] = 8'h00;
        ascii_rom[12'h076] = 8'h00;
        ascii_rom[12'h077] = 8'h00;
        ascii_rom[12'h078] = 8'h00;
        ascii_rom[12'h079] = 8'h00;
        ascii_rom[12'h07A] = 8'h00;
        ascii_rom[12'h07B] = 8'h00;
        ascii_rom[12'h07C] = 8'h00;
        ascii_rom[12'h07D] = 8'h00;
        ascii_rom[12'h07E] = 8'h00;
        ascii_rom[12'h07F] = 8'h00;
        // 0x08 -
        ascii_rom[12'h080] = 8'h00;
        ascii_rom[12'h081] = 8'h00;
        ascii_rom[12'h082] = 8'h00;
        ascii_rom[12'h083] = 8'h00;
        ascii_rom[12'h084] = 8'h00;
        ascii_rom[12'h085] = 8'h00;
        ascii_rom[12'h086] = 8'h00;
        ascii_rom[12'h087] = 8'h00;
        ascii_rom[12'h088] = 8'h00;
        ascii_rom[12'h089] = 8'h00;
        ascii_rom[12'h08A] = 8'h00;
        ascii_rom[12'h08B] = 8'h00;
        ascii_rom[12'h08C] = 8'h00;
        ascii_rom[12'h08D] = 8'h00;
        ascii_rom[12'h08E] = 8'h00;
        ascii_rom[12'h08F] = 8'h00;
        // 0x09 -
        ascii_rom[12'h090] = 8'h00;
        ascii_rom[12'h091] = 8'h00;
        ascii_rom[12'h092] = 8'h00;
        ascii_rom[12'h093] = 8'h00;
        ascii_rom[12'h094] = 8'h00;
        ascii_rom[12'h095] = 8'h00;
        ascii_rom[12'h096] = 8'h00;
        ascii_rom[12'h097] = 8'h00;
        ascii_rom[12'h098] = 8'h00;
        ascii_rom[12'h099] = 8'h00;
        ascii_rom[12'h09A] = 8'h00;
        ascii_rom[12'h09B] = 8'h00;
        ascii_rom[12'h09C] = 8'h00;
        ascii_rom[12'h09D] = 8'h00;
        ascii_rom[12'h09E] = 8'h00;
        ascii_rom[12'h09F] = 8'h00;
        // 0x0A -
        ascii_rom[12'h0A0] = 8'h00;
        ascii_rom[12'h0A1] = 8'h00;
        ascii_rom[12'h0A2] = 8'h00;
        ascii_rom[12'h0A3] = 8'h00;
        ascii_rom[12'h0A4] = 8'h00;
        ascii_rom[12'h0A5] = 8'h00;
        ascii_rom[12'h0A6] = 8'h00;
        ascii_rom[12'h0A7] = 8'h00;
        ascii_rom[12'h0A8] = 8'h00;
        ascii_rom[12'h0A9] = 8'h00;
        ascii_rom[12'h0AA] = 8'h00;
        ascii_rom[12'h0AB] = 8'h00;
        ascii_rom[12'h0AC] = 8'h00;
        ascii_rom[12'h0AD] = 8'h00;
        ascii_rom[12'h0AE] = 8'h00;
        ascii_rom[12'h0AF] = 8'h00;
        // 0x0B -
        ascii_rom[12'h0B0] = 8'h00;
        ascii_rom[12'h0B1] = 8'h00;
        ascii_rom[12'h0B2] = 8'h00;
        ascii_rom[12'h0B3] = 8'h00;
        ascii_rom[12'h0B4] = 8'h00;
        ascii_rom[12'h0B5] = 8'h00;
        ascii_rom[12'h0B6] = 8'h00;
        ascii_rom[12'h0B7] = 8'h00;
        ascii_rom[12'h0B8] = 8'h00;
        ascii_rom[12'h0B9] = 8'h00;
        ascii_rom[12'h0BA] = 8'h00;
        ascii_rom[12'h0BB] = 8'h00;
        ascii_rom[12'h0BC] = 8'h00;
        ascii_rom[12'h0BD] = 8'h00;
        ascii_rom[12'h0BE] = 8'h00;
        ascii_rom[12'h0BF] = 8'h00;
        // 0x0C -
        ascii_rom[12'h0C0] = 8'h00;
        ascii_rom[12'h0C1] = 8'h00;
        ascii_rom[12'h0C2] = 8'h00;
        ascii_rom[12'h0C3] = 8'h00;
        ascii_rom[12'h0C4] = 8'h00;
        ascii_rom[12'h0C5] = 8'h00;
        ascii_rom[12'h0C6] = 8'h00;
        ascii_rom[12'h0C7] = 8'h00;
        ascii_rom[12'h0C8] = 8'h00;
        ascii_rom[12'h0C9] = 8'h00;
        ascii_rom[12'h0CA] = 8'h00;
        ascii_rom[12'h0CB] = 8'h00;
        ascii_rom[12'h0CC] = 8'h00;
        ascii_rom[12'h0CD] = 8'h00;
        ascii_rom[12'h0CE] = 8'h00;
        ascii_rom[12'h0CF] = 8'h00;
        // 0x0D -
        ascii_rom[12'h0D0] = 8'h00;
        ascii_rom[12'h0D1] = 8'h00;
        ascii_rom[12'h0D2] = 8'h00;
        ascii_rom[12'h0D3] = 8'h00;
        ascii_rom[12'h0D4] = 8'h00;
        ascii_rom[12'h0D5] = 8'h00;
        ascii_rom[12'h0D6] = 8'h00;
        ascii_rom[12'h0D7] = 8'h00;
        ascii_rom[12'h0D8] = 8'h00;
        ascii_rom[12'h0D9] = 8'h00;
        ascii_rom[12'h0DA] = 8'h00;
        ascii_rom[12'h0DB] = 8'h00;
        ascii_rom[12'h0DC] = 8'h00;
        ascii_rom[12'h0DD] = 8'h00;
        ascii_rom[12'h0DE] = 8'h00;
        ascii_rom[12'h0DF] = 8'h00;
        // 0x0E -
        ascii_rom[12'h0E0] = 8'h00;
        ascii_rom[12'h0E1] = 8'h00;
        ascii_rom[12'h0E2] = 8'h00;
        ascii_rom[12'h0E3] = 8'h00;
        ascii_rom[12'h0E4] = 8'h00;
        ascii_rom[12'h0E5] = 8'h00;
        ascii_rom[12'h0E6] = 8'h00;
        ascii_rom[12'h0E7] = 8'h00;
        ascii_rom[12'h0E8] = 8'h00;
        ascii_rom[12'h0E9] = 8'h00;
        ascii_rom[12'h0EA] = 8'h00;
        ascii_rom[12'h0EB] = 8'h00;
        ascii_rom[12'h0EC] = 8'h00;
        ascii_rom[12'h0ED] = 8'h00;
        ascii_rom[12'h0EE] = 8'h00;
        ascii_rom[12'h0EF] = 8'h00;
        // 0x0F -
        ascii_rom[12'h0F0] = 8'h00;
        ascii_rom[12'h0F1] = 8'h00;
        ascii_rom[12'h0F2] = 8'h00;
        ascii_rom[12'h0F3] = 8'h00;
        ascii_rom[12'h0F4] = 8'h00;
        ascii_rom[12'h0F5] = 8'h00;
        ascii_rom[12'h0F6] = 8'h00;
        ascii_rom[12'h0F7] = 8'h00;
        ascii_rom[12'h0F8] = 8'h00;
        ascii_rom[12'h0F9] = 8'h00;
        ascii_rom[12'h0FA] = 8'h00;
        ascii_rom[12'h0FB] = 8'h00;
        ascii_rom[12'h0FC] = 8'h00;
        ascii_rom[12'h0FD] = 8'h00;
        ascii_rom[12'h0FE] = 8'h00;
        ascii_rom[12'h0FF] = 8'h00;
        // 0x10 -
        ascii_rom[12'h100] = 8'h00;
        ascii_rom[12'h101] = 8'h00;
        ascii_rom[12'h102] = 8'h00;
        ascii_rom[12'h103] = 8'h00;
        ascii_rom[12'h104] = 8'h00;
        ascii_rom[12'h105] = 8'h00;
        ascii_rom[12'h106] = 8'h00;
        ascii_rom[12'h107] = 8'h00;
        ascii_rom[12'h108] = 8'h00;
        ascii_rom[12'h109] = 8'h00;
        ascii_rom[12'h10A] = 8'h00;
        ascii_rom[12'h10B] = 8'h00;
        ascii_rom[12'h10C] = 8'h00;
        ascii_rom[12'h10D] = 8'h00;
        ascii_rom[12'h10E] = 8'h00;
        ascii_rom[12'h10F] = 8'h00;
        // 0x11 -
        ascii_rom[12'h110] = 8'h00;
        ascii_rom[12'h111] = 8'h00;
        ascii_rom[12'h112] = 8'h00;
        ascii_rom[12'h113] = 8'h00;
        ascii_rom[12'h114] = 8'h00;
        ascii_rom[12'h115] = 8'h00;
        ascii_rom[12'h116] = 8'h00;
        ascii_rom[12'h117] = 8'h00;
        ascii_rom[12'h118] = 8'h00;
        ascii_rom[12'h119] = 8'h00;
        ascii_rom[12'h11A] = 8'h00;
        ascii_rom[12'h11B] = 8'h00;
        ascii_rom[12'h11C] = 8'h00;
        ascii_rom[12'h11D] = 8'h00;
        ascii_rom[12'h11E] = 8'h00;
        ascii_rom[12'h11F] = 8'h00;
        // 0x12 -
        ascii_rom[12'h120] = 8'h00;
        ascii_rom[12'h121] = 8'h00;
        ascii_rom[12'h122] = 8'h00;
        ascii_rom[12'h123] = 8'h00;
        ascii_rom[12'h124] = 8'h00;
        ascii_rom[12'h125] = 8'h00;
        ascii_rom[12'h126] = 8'h00;
        ascii_rom[12'h127] = 8'h00;
        ascii_rom[12'h128] = 8'h00;
        ascii_rom[12'h129] = 8'h00;
        ascii_rom[12'h12A] = 8'h00;
        ascii_rom[12'h12B] = 8'h00;
        ascii_rom[12'h12C] = 8'h00;
        ascii_rom[12'h12D] = 8'h00;
        ascii_rom[12'h12E] = 8'h00;
        ascii_rom[12'h12F] = 8'h00;
        // 0x13 -
        ascii_rom[12'h130] = 8'h00;
        ascii_rom[12'h131] = 8'h00;
        ascii_rom[12'h132] = 8'h00;
        ascii_rom[12'h133] = 8'h00;
        ascii_rom[12'h134] = 8'h00;
        ascii_rom[12'h135] = 8'h00;
        ascii_rom[12'h136] = 8'h00;
        ascii_rom[12'h137] = 8'h00;
        ascii_rom[12'h138] = 8'h00;
        ascii_rom[12'h139] = 8'h00;
        ascii_rom[12'h13A] = 8'h00;
        ascii_rom[12'h13B] = 8'h00;
        ascii_rom[12'h13C] = 8'h00;
        ascii_rom[12'h13D] = 8'h00;
        ascii_rom[12'h13E] = 8'h00;
        ascii_rom[12'h13F] = 8'h00;
        // 0x14 -
        ascii_rom[12'h140] = 8'h00;
        ascii_rom[12'h141] = 8'h00;
        ascii_rom[12'h142] = 8'h00;
        ascii_rom[12'h143] = 8'h00;
        ascii_rom[12'h144] = 8'h00;
        ascii_rom[12'h145] = 8'h00;
        ascii_rom[12'h146] = 8'h00;
        ascii_rom[12'h147] = 8'h00;
        ascii_rom[12'h148] = 8'h00;
        ascii_rom[12'h149] = 8'h00;
        ascii_rom[12'h14A] = 8'h00;
        ascii_rom[12'h14B] = 8'h00;
        ascii_rom[12'h14C] = 8'h00;
        ascii_rom[12'h14D] = 8'h00;
        ascii_rom[12'h14E] = 8'h00;
        ascii_rom[12'h14F] = 8'h00;
        // 0x15 -
        ascii_rom[12'h150] = 8'h00;
        ascii_rom[12'h151] = 8'h00;
        ascii_rom[12'h152] = 8'h00;
        ascii_rom[12'h153] = 8'h00;
        ascii_rom[12'h154] = 8'h00;
        ascii_rom[12'h155] = 8'h00;
        ascii_rom[12'h156] = 8'h00;
        ascii_rom[12'h157] = 8'h00;
        ascii_rom[12'h158] = 8'h00;
        ascii_rom[12'h159] = 8'h00;
        ascii_rom[12'h15A] = 8'h00;
        ascii_rom[12'h15B] = 8'h00;
        ascii_rom[12'h15C] = 8'h00;
        ascii_rom[12'h15D] = 8'h00;
        ascii_rom[12'h15E] = 8'h00;
        ascii_rom[12'h15F] = 8'h00;
        // 0x16 -
        ascii_rom[12'h160] = 8'h00;
        ascii_rom[12'h161] = 8'h00;
        ascii_rom[12'h162] = 8'h00;
        ascii_rom[12'h163] = 8'h00;
        ascii_rom[12'h164] = 8'h00;
        ascii_rom[12'h165] = 8'h00;
        ascii_rom[12'h166] = 8'h00;
        ascii_rom[12'h167] = 8'h00;
        ascii_rom[12'h168] = 8'h00;
        ascii_rom[12'h169] = 8'h00;
        ascii_rom[12'h16A] = 8'h00;
        ascii_rom[12'h16B] = 8'h00;
        ascii_rom[12'h16C] = 8'h00;
        ascii_rom[12'h16D] = 8'h00;
        ascii_rom[12'h16E] = 8'h00;
        ascii_rom[12'h16F] = 8'h00;
        // 0x17 -
        ascii_rom[12'h170] = 8'h00;
        ascii_rom[12'h171] = 8'h00;
        ascii_rom[12'h172] = 8'h00;
        ascii_rom[12'h173] = 8'h00;
        ascii_rom[12'h174] = 8'h00;
        ascii_rom[12'h175] = 8'h00;
        ascii_rom[12'h176] = 8'h00;
        ascii_rom[12'h177] = 8'h00;
        ascii_rom[12'h178] = 8'h00;
        ascii_rom[12'h179] = 8'h00;
        ascii_rom[12'h17A] = 8'h00;
        ascii_rom[12'h17B] = 8'h00;
        ascii_rom[12'h17C] = 8'h00;
        ascii_rom[12'h17D] = 8'h00;
        ascii_rom[12'h17E] = 8'h00;
        ascii_rom[12'h17F] = 8'h00;
        // 0x18 -
        ascii_rom[12'h180] = 8'h00;
        ascii_rom[12'h181] = 8'h00;
        ascii_rom[12'h182] = 8'h00;
        ascii_rom[12'h183] = 8'h00;
        ascii_rom[12'h184] = 8'h00;
        ascii_rom[12'h185] = 8'h00;
        ascii_rom[12'h186] = 8'h00;
        ascii_rom[12'h187] = 8'h00;
        ascii_rom[12'h188] = 8'h00;
        ascii_rom[12'h189] = 8'h00;
        ascii_rom[12'h18A] = 8'h00;
        ascii_rom[12'h18B] = 8'h00;
        ascii_rom[12'h18C] = 8'h00;
        ascii_rom[12'h18D] = 8'h00;
        ascii_rom[12'h18E] = 8'h00;
        ascii_rom[12'h18F] = 8'h00;
        // 0x19 -
        ascii_rom[12'h190] = 8'h00;
        ascii_rom[12'h191] = 8'h00;
        ascii_rom[12'h192] = 8'h00;
        ascii_rom[12'h193] = 8'h00;
        ascii_rom[12'h194] = 8'h00;
        ascii_rom[12'h195] = 8'h00;
        ascii_rom[12'h196] = 8'h00;
        ascii_rom[12'h197] = 8'h00;
        ascii_rom[12'h198] = 8'h00;
        ascii_rom[12'h199] = 8'h00;
        ascii_rom[12'h19A] = 8'h00;
        ascii_rom[12'h19B] = 8'h00;
        ascii_rom[12'h19C] = 8'h00;
        ascii_rom[12'h19D] = 8'h00;
        ascii_rom[12'h19E] = 8'h00;
        ascii_rom[12'h19F] = 8'h00;
        // 0x1A -
        ascii_rom[12'h1A0] = 8'h00;
        ascii_rom[12'h1A1] = 8'h00;
        ascii_rom[12'h1A2] = 8'h00;
        ascii_rom[12'h1A3] = 8'h00;
        ascii_rom[12'h1A4] = 8'h00;
        ascii_rom[12'h1A5] = 8'h00;
        ascii_rom[12'h1A6] = 8'h00;
        ascii_rom[12'h1A7] = 8'h00;
        ascii_rom[12'h1A8] = 8'h00;
        ascii_rom[12'h1A9] = 8'h00;
        ascii_rom[12'h1AA] = 8'h00;
        ascii_rom[12'h1AB] = 8'h00;
        ascii_rom[12'h1AC] = 8'h00;
        ascii_rom[12'h1AD] = 8'h00;
        ascii_rom[12'h1AE] = 8'h00;
        ascii_rom[12'h1AF] = 8'h00;
        // 0x1B -
        ascii_rom[12'h1B0] = 8'h00;
        ascii_rom[12'h1B1] = 8'h00;
        ascii_rom[12'h1B2] = 8'h00;
        ascii_rom[12'h1B3] = 8'h00;
        ascii_rom[12'h1B4] = 8'h00;
        ascii_rom[12'h1B5] = 8'h00;
        ascii_rom[12'h1B6] = 8'h00;
        ascii_rom[12'h1B7] = 8'h00;
        ascii_rom[12'h1B8] = 8'h00;
        ascii_rom[12'h1B9] = 8'h00;
        ascii_rom[12'h1BA] = 8'h00;
        ascii_rom[12'h1BB] = 8'h00;
        ascii_rom[12'h1BC] = 8'h00;
        ascii_rom[12'h1BD] = 8'h00;
        ascii_rom[12'h1BE] = 8'h00;
        ascii_rom[12'h1BF] = 8'h00;
        // 0x1C -
        ascii_rom[12'h1C0] = 8'h00;
        ascii_rom[12'h1C1] = 8'h00;
        ascii_rom[12'h1C2] = 8'h00;
        ascii_rom[12'h1C3] = 8'h00;
        ascii_rom[12'h1C4] = 8'h00;
        ascii_rom[12'h1C5] = 8'h00;
        ascii_rom[12'h1C6] = 8'h00;
        ascii_rom[12'h1C7] = 8'h00;
        ascii_rom[12'h1C8] = 8'h00;
        ascii_rom[12'h1C9] = 8'h00;
        ascii_rom[12'h1CA] = 8'h00;
        ascii_rom[12'h1CB] = 8'h00;
        ascii_rom[12'h1CC] = 8'h00;
        ascii_rom[12'h1CD] = 8'h00;
        ascii_rom[12'h1CE] = 8'h00;
        ascii_rom[12'h1CF] = 8'h00;
        // 0x1D -
        ascii_rom[12'h1D0] = 8'h00;
        ascii_rom[12'h1D1] = 8'h00;
        ascii_rom[12'h1D2] = 8'h00;
        ascii_rom[12'h1D3] = 8'h00;
        ascii_rom[12'h1D4] = 8'h00;
        ascii_rom[12'h1D5] = 8'h00;
        ascii_rom[12'h1D6] = 8'h00;
        ascii_rom[12'h1D7] = 8'h00;
        ascii_rom[12'h1D8] = 8'h00;
        ascii_rom[12'h1D9] = 8'h00;
        ascii_rom[12'h1DA] = 8'h00;
        ascii_rom[12'h1DB] = 8'h00;
        ascii_rom[12'h1DC] = 8'h00;
        ascii_rom[12'h1DD] = 8'h00;
        ascii_rom[12'h1DE] = 8'h00;
        ascii_rom[12'h1DF] = 8'h00;
        // 0x1E -
        ascii_rom[12'h1E0] = 8'h00;
        ascii_rom[12'h1E1] = 8'h00;
        ascii_rom[12'h1E2] = 8'h00;
        ascii_rom[12'h1E3] = 8'h00;
        ascii_rom[12'h1E4] = 8'h00;
        ascii_rom[12'h1E5] = 8'h00;
        ascii_rom[12'h1E6] = 8'h00;
        ascii_rom[12'h1E7] = 8'h00;
        ascii_rom[12'h1E8] = 8'h00;
        ascii_rom[12'h1E9] = 8'h00;
        ascii_rom[12'h1EA] = 8'h00;
        ascii_rom[12'h1EB] = 8'h00;
        ascii_rom[12'h1EC] = 8'h00;
        ascii_rom[12'h1ED] = 8'h00;
        ascii_rom[12'h1EE] = 8'h00;
        ascii_rom[12'h1EF] = 8'h00;
        // 0x1F -
        ascii_rom[12'h1F0] = 8'h00;
        ascii_rom[12'h1F1] = 8'h00;
        ascii_rom[12'h1F2] = 8'h00;
        ascii_rom[12'h1F3] = 8'h00;
        ascii_rom[12'h1F4] = 8'h00;
        ascii_rom[12'h1F5] = 8'h00;
        ascii_rom[12'h1F6] = 8'h00;
        ascii_rom[12'h1F7] = 8'h00;
        ascii_rom[12'h1F8] = 8'h00;
        ascii_rom[12'h1F9] = 8'h00;
        ascii_rom[12'h1FA] = 8'h00;
        ascii_rom[12'h1FB] = 8'h00;
        ascii_rom[12'h1FC] = 8'h00;
        ascii_rom[12'h1FD] = 8'h00;
        ascii_rom[12'h1FE] = 8'h00;
        ascii_rom[12'h1FF] = 8'h00;
        // 0x20 space
        ascii_rom[12'h200] = 8'h00;
        ascii_rom[12'h201] = 8'h00;
        ascii_rom[12'h202] = 8'h00;
        ascii_rom[12'h203] = 8'h00;
        ascii_rom[12'h204] = 8'h00;
        ascii_rom[12'h205] = 8'h00;
        ascii_rom[12'h206] = 8'h00;
        ascii_rom[12'h207] = 8'h00;
        ascii_rom[12'h208] = 8'h00;
        ascii_rom[12'h209] = 8'h00;
        ascii_rom[12'h20A] = 8'h00;
        ascii_rom[12'h20B] = 8'h00;
        ascii_rom[12'h20C] = 8'h00;
        ascii_rom[12'h20D] = 8'h00;
        ascii_rom[12'h20E] = 8'h00;
        ascii_rom[12'h20F] = 8'h00;
        // 0x21 !
        ascii_rom[12'h210] = 8'h00;
        ascii_rom[12'h211] = 8'h00;
        ascii_rom[12'h212] = 8'h18;
        ascii_rom[12'h213] = 8'h3C;
        ascii_rom[12'h214] = 8'h3C;
        ascii_rom[12'h215] = 8'h3C;
        ascii_rom[12'h216] = 8'h18;
        ascii_rom[12'h217] = 8'h18;
        ascii_rom[12'h218] = 8'h18;
        ascii_rom[12'h219] = 8'h00;
        ascii_rom[12'h21A] = 8'h18;
        ascii_rom[12'h21B] = 8'h18;
        ascii_rom[12'h21C] = 8'h00;
        ascii_rom[12'h21D] = 8'h00;
        ascii_rom[12'h21E] = 8'h00;
        ascii_rom[12'h21F] = 8'h00;
        // 0x22 "
        ascii_rom[12'h220] = 8'h00;
        ascii_rom[12'h221] = 8'h66;
        ascii_rom[12'h222] = 8'h66;
        ascii_rom[12'h223] = 8'h66;
        ascii_rom[12'h224] = 8'h24;
        ascii_rom[12'h225] = 8'h00;
        ascii_rom[12'h226] = 8'h00;
        ascii_rom[12'h227] = 8'h00;
        ascii_rom[12'h228] = 8'h00;
        ascii_rom[12'h229] = 8'h00;
        ascii_rom[12'h22A] = 8'h00;
        ascii_rom[12'h22B] = 8'h00;
        ascii_rom[12'h22C] = 8'h00;
        ascii_rom[12'h22D] = 8'h00;
        ascii_rom[12'h22E] = 8'h00;
        ascii_rom[12'h22F] = 8'h00;
        // 0x23 #
        ascii_rom[12'h230] = 8'h00;
        ascii_rom[12'h231] = 8'h00;
        ascii_rom[12'h232] = 8'h00;
        ascii_rom[12'h233] = 8'h6C;
        ascii_rom[12'h234] = 8'h6C;
        ascii_rom[12'h235] = 8'hFE;
        ascii_rom[12'h236] = 8'h6C;
        ascii_rom[12'h237] = 8'h6C;
        ascii_rom[12'h238] = 8'h6C;
        ascii_rom[12'h239] = 8'hFE;
        ascii_rom[12'h23A] = 8'h6C;
        ascii_rom[12'h23B] = 8'h6C;
        ascii_rom[12'h23C] = 8'h00;
        ascii_rom[12'h23D] = 8'h00;
        ascii_rom[12'h23E] = 8'h00;
        ascii_rom[12'h23F] = 8'h00;
        // 0x24 $
        ascii_rom[12'h240] = 8'h18;
        ascii_rom[12'h241] = 8'h18;
        ascii_rom[12'h242] = 8'h7C;
        ascii_rom[12'h243] = 8'hC6;
        ascii_rom[12'h244] = 8'hC2;
        ascii_rom[12'h245] = 8'hC0;
        ascii_rom[12'h246] = 8'h7C;
        ascii_rom[12'h247] = 8'h06;
        ascii_rom[12'h248] = 8'h06;
        ascii_rom[12'h249] = 8'h86;
        ascii_rom[12'h24A] = 8'hC6;
        ascii_rom[12'h24B] = 8'h7C;
        ascii_rom[12'h24C] = 8'h18;
        ascii_rom[12'h24D] = 8'h18;
        ascii_rom[12'h24E] = 8'h00;
        ascii_rom[12'h24F] = 8'h00;
        // 0x25 %
        ascii_rom[12'h250] = 8'h00;
        ascii_rom[12'h251] = 8'h00;
        ascii_rom[12'h252] = 8'h00;
        ascii_rom[12'h253] = 8'h00;
        ascii_rom[12'h254] = 8'hC2;
        ascii_rom[12'h255] = 8'hC6;
        ascii_rom[12'h256] = 8'h0C;
        ascii_rom[12'h257] = 8'h18;
        ascii_rom[12'h258] = 8'h30;
        ascii_rom[12'h259] = 8'h60;
        ascii_rom[12'h25A] = 8'hC6;
        ascii_rom[12'h25B] = 8'h86;
        ascii_rom[12'h25C] = 8'h00;
        ascii_rom[12'h25D] = 8'h00;
        ascii_rom[12'h25E] = 8'h00;
        ascii_rom[12'h25F] = 8'h00;
        // 0x26 &
        ascii_rom[12'h260] = 8'h00;
        ascii_rom[12'h261] = 8'h00;
        ascii_rom[12'h262] = 8'h38;
        ascii_rom[12'h263] = 8'h6C;
        ascii_rom[12'h264] = 8'h6C;
        ascii_rom[12'h265] = 8'h38;
        ascii_rom[12'h266] = 8'h76;
        ascii_rom[12'h267] = 8'hDC;
        ascii_rom[12'h268] = 8'hCC;
        ascii_rom[12'h269] = 8'hCC;
        ascii_rom[12'h26A] = 8'hCC;
        ascii_rom[12'h26B] = 8'h76;
        ascii_rom[12'h26C] = 8'h00;
        ascii_rom[12'h26D] = 8'h00;
        ascii_rom[12'h26E] = 8'h00;
        ascii_rom[12'h26F] = 8'h00;
        // 0x27 '
        ascii_rom[12'h270] = 8'h00;
        ascii_rom[12'h271] = 8'h30;
        ascii_rom[12'h272] = 8'h30;
        ascii_rom[12'h273] = 8'h30;
        ascii_rom[12'h274] = 8'h60;
        ascii_rom[12'h275] = 8'h00;
        ascii_rom[12'h276] = 8'h00;
        ascii_rom[12'h277] = 8'h00;
        ascii_rom[12'h278] = 8'h00;
        ascii_rom[12'h279] = 8'h00;
        ascii_rom[12'h27A] = 8'h00;
        ascii_rom[12'h27B] = 8'h00;
        ascii_rom[12'h27C] = 8'h00;
        ascii_rom[12'h27D] = 8'h00;
        ascii_rom[12'h27E] = 8'h00;
        ascii_rom[12'h27F] = 8'h00;
        // 0x28 (
        ascii_rom[12'h280] = 8'h00;
        ascii_rom[12'h281] = 8'h00;
        ascii_rom[12'h282] = 8'h0C;
        ascii_rom[12'h283] = 8'h18;
        ascii_rom[12'h284] = 8'h30;
        ascii_rom[12'h285] = 8'h30;
        ascii_rom[12'h286] = 8'h30;
        ascii_rom[12'h287] = 8'h30;
        ascii_rom[12'h288] = 8'h30;
        ascii_rom[12'h289] = 8'h30;
        ascii_rom[12'h28A] = 8'h18;
        ascii_rom[12'h28B] = 8'h0C;
        ascii_rom[12'h28C] = 8'h00;
        ascii_rom[12'h28D] = 8'h00;
        ascii_rom[12'h28E] = 8'h00;
        ascii_rom[12'h28F] = 8'h00;
        // 0x29 )
        ascii_rom[12'h290] = 8'h00;
        ascii_rom[12'h291] = 8'h00;
        ascii_rom[12'h292] = 8'h30;
        ascii_rom[12'h293] = 8'h18;
        ascii_rom[12'h294] = 8'h0C;
        ascii_rom[12'h295] = 8'h0C;
        ascii_rom[12'h296] = 8'h0C;
        ascii_rom[12'h297] = 8'h0C;
        ascii_rom[12'h298] = 8'h0C;
        ascii_rom[12'h299] = 8'h0C;
        ascii_rom[12'h29A] = 8'h18;
        ascii_rom[12'h29B] = 8'h30;
        ascii_rom[12'h29C] = 8'h00;
        ascii_rom[12'h29D] = 8'h00;
        ascii_rom[12'h29E] = 8'h00;
        ascii_rom[12'h29F] = 8'h00;
        // 0x2A *
        ascii_rom[12'h2A0] = 8'h00;
        ascii_rom[12'h2A1] = 8'h00;
        ascii_rom[12'h2A2] = 8'h00;
        ascii_rom[12'h2A3] = 8'h00;
        ascii_rom[12'h2A4] = 8'h00;
        ascii_rom[12'h2A5] = 8'h66;
        ascii_rom[12'h2A6] = 8'h3C;
        ascii_rom[12'h2A7] = 8'hFF;
        ascii_rom[12'h2A8] = 8'h3C;
        ascii_rom[12'h2A9] = 8'h66;
        ascii_rom[12'h2AA] = 8'h00;
        ascii_rom[12'h2AB] = 8'h00;
        ascii_rom[12'h2AC] = 8'h00;
        ascii_rom[12'h2AD] = 8'h00;
        ascii_rom[12'h2AE] = 8'h00;
        ascii_rom[12'h2AF] = 8'h00;
        // 0x2B +
        ascii_rom[12'h2B0] = 8'h00;
        ascii_rom[12'h2B1] = 8'h00;
        ascii_rom[12'h2B2] = 8'h00;
        ascii_rom[12'h2B3] = 8'h00;
        ascii_rom[12'h2B4] = 8'h00;
        ascii_rom[12'h2B5] = 8'h18;
        ascii_rom[12'h2B6] = 8'h18;
        ascii_rom[12'h2B7] = 8'h7E;
        ascii_rom[12'h2B8] = 8'h18;
        ascii_rom[12'h2B9] = 8'h18;
        ascii_rom[12'h2BA] = 8'h00;
        ascii_rom[12'h2BB] = 8'h00;
        ascii_rom[12'h2BC] = 8'h00;
        ascii_rom[12'h2BD] = 8'h00;
        ascii_rom[12'h2BE] = 8'h00;
        ascii_rom[12'h2BF] = 8'h00;
        // 0x2C ,
        ascii_rom[12'h2C0] = 8'h00;
        ascii_rom[12'h2C1] = 8'h00;
        ascii_rom[12'h2C2] = 8'h00;
        ascii_rom[12'h2C3] = 8'h00;
        ascii_rom[12'h2C4] = 8'h00;
        ascii_rom[12'h2C5] = 8'h00;
        ascii_rom[12'h2C6] = 8'h00;
        ascii_rom[12'h2C7] = 8'h00;
        ascii_rom[12'h2C8] = 8'h00;
        ascii_rom[12'h2C9] = 8'h18;
        ascii_rom[12'h2CA] = 8'h18;
        ascii_rom[12'h2CB] = 8'h18;
        ascii_rom[12'h2CC] = 8'h30;
        ascii_rom[12'h2CD] = 8'h00;
        ascii_rom[12'h2CE] = 8'h00;
        ascii_rom[12'h2CF] = 8'h00;
        // 0x2D -
        ascii_rom[12'h2D0] = 8'h00;
        ascii_rom[12'h2D1] = 8'h00;
        ascii_rom[12'h2D2] = 8'h00;
        ascii_rom[12'h2D3] = 8'h00;
        ascii_rom[12'h2D4] = 8'h00;
        ascii_rom[12'h2D5] = 8'h00;
        ascii_rom[12'h2D6] = 8'h00;
        ascii_rom[12'h2D7] = 8'hFE;
        ascii_rom[12'h2D8] = 8'h00;
        ascii_rom[12'h2D9] = 8'h00;
        ascii_rom[12'h2DA] = 8'h00;
        ascii_rom[12'h2DB] = 8'h00;
        ascii_rom[12'h2DC] = 8'h00;
        ascii_rom[12'h2DD] = 8'h00;
        ascii_rom[12'h2DE] = 8'h00;
        ascii_rom[12'h2DF] = 8'h00;
        // 0x2E .
        ascii_rom[12'h2E0] = 8'h00;
        ascii_rom[12'h2E1] = 8'h00;
        ascii_rom[12'h2E2] = 8'h00;
        ascii_rom[12'h2E3] = 8'h00;
        ascii_rom[12'h2E4] = 8'h00;
        ascii_rom[12'h2E5] = 8'h00;
        ascii_rom[12'h2E6] = 8'h00;
        ascii_rom[12'h2E7] = 8'h00;
        ascii_rom[12'h2E8] = 8'h00;
        ascii_rom[12'h2E9] = 8'h00;
        ascii_rom[12'h2EA] = 8'h18;
        ascii_rom[12'h2EB] = 8'h18;
        ascii_rom[12'h2EC] = 8'h00;
        ascii_rom[12'h2ED] = 8'h00;
        ascii_rom[12'h2EE] = 8'h00;
        ascii_rom[12'h2EF] = 8'h00;
        // 0x2F /
        ascii_rom[12'h2F0] = 8'h00;
        ascii_rom[12'h2F1] = 8'h00;
        ascii_rom[12'h2F2] = 8'h00;
        ascii_rom[12'h2F3] = 8'h00;
        ascii_rom[12'h2F4] = 8'h02;
        ascii_rom[12'h2F5] = 8'h06;
        ascii_rom[12'h2F6] = 8'h0C;
        ascii_rom[12'h2F7] = 8'h18;
        ascii_rom[12'h2F8] = 8'h30;
        ascii_rom[12'h2F9] = 8'h60;
        ascii_rom[12'h2FA] = 8'hC0;
        ascii_rom[12'h2FB] = 8'h80;
        ascii_rom[12'h2FC] = 8'h00;
        ascii_rom[12'h2FD] = 8'h00;
        ascii_rom[12'h2FE] = 8'h00;
        ascii_rom[12'h2FF] = 8'h00;
        // 0x30 0
        ascii_rom[12'h300] = 8'h00;
        ascii_rom[12'h301] = 8'h00;
        ascii_rom[12'h302] = 8'h38;
        ascii_rom[12'h303] = 8'h6C;
        ascii_rom[12'h304] = 8'hC6;
        ascii_rom[12'h305] = 8'hC6;
        ascii_rom[12'h306] = 8'hD6;
        ascii_rom[12'h307] = 8'hD6;
        ascii_rom[12'h308] = 8'hC6;
        ascii_rom[12'h309] = 8'hC6;
        ascii_rom[12'h30A] = 8'h6C;
        ascii_rom[12'h30B] = 8'h38;
        ascii_rom[12'h30C] = 8'h00;
        ascii_rom[12'h30D] = 8'h00;
        ascii_rom[12'h30E] = 8'h00;
        ascii_rom[12'h30F] = 8'h00;
        // 0x31 1
        ascii_rom[12'h310] = 8'h00;
        ascii_rom[12'h311] = 8'h00;
        ascii_rom[12'h312] = 8'h18;
        ascii_rom[12'h313] = 8'h38;
        ascii_rom[12'h314] = 8'h78;
        ascii_rom[12'h315] = 8'h18;
        ascii_rom[12'h316] = 8'h18;
        ascii_rom[12'h317] = 8'h18;
        ascii_rom[12'h318] = 8'h18;
        ascii_rom[12'h319] = 8'h18;
        ascii_rom[12'h31A] = 8'h18;
        ascii_rom[12'h31B] = 8'h7E;
        ascii_rom[12'h31C] = 8'h00;
        ascii_rom[12'h31D] = 8'h00;
        ascii_rom[12'h31E] = 8'h00;
        ascii_rom[12'h31F] = 8'h00;
        // 0x32 2
        ascii_rom[12'h320] = 8'h00;
        ascii_rom[12'h321] = 8'h00;
        ascii_rom[12'h322] = 8'h7C;
        ascii_rom[12'h323] = 8'hC6;
        ascii_rom[12'h324] = 8'h06;
        ascii_rom[12'h325] = 8'h0C;
        ascii_rom[12'h326] = 8'h18;
        ascii_rom[12'h327] = 8'h30;
        ascii_rom[12'h328] = 8'h60;
        ascii_rom[12'h329] = 8'hC0;
        ascii_rom[12'h32A] = 8'hC6;
        ascii_rom[12'h32B] = 8'hFE;
        ascii_rom[12'h32C] = 8'h00;
        ascii_rom[12'h32D] = 8'h00;
        ascii_rom[12'h32E] = 8'h00;
        ascii_rom[12'h32F] = 8'h00;
        // 0x33 3
        ascii_rom[12'h330] = 8'h00;
        ascii_rom[12'h331] = 8'h00;
        ascii_rom[12'h332] = 8'h7C;
        ascii_rom[12'h333] = 8'hC6;
        ascii_rom[12'h334] = 8'h06;
        ascii_rom[12'h335] = 8'h06;
        ascii_rom[12'h336] = 8'h3C;
        ascii_rom[12'h337] = 8'h06;
        ascii_rom[12'h338] = 8'h06;
        ascii_rom[12'h339] = 8'h06;
        ascii_rom[12'h33A] = 8'hC6;
        ascii_rom[12'h33B] = 8'h7C;
        ascii_rom[12'h33C] = 8'h00;
        ascii_rom[12'h33D] = 8'h00;
        ascii_rom[12'h33E] = 8'h00;
        ascii_rom[12'h33F] = 8'h00;
        // 0x34 4
        ascii_rom[12'h340] = 8'h00;
        ascii_rom[12'h341] = 8'h00;
        ascii_rom[12'h342] = 8'h0C;
        ascii_rom[12'h343] = 8'h1C;
        ascii_rom[12'h344] = 8'h3C;
        ascii_rom[12'h345] = 8'h6C;
        ascii_rom[12'h346] = 8'hCC;
        ascii_rom[12'h347] = 8'hFE;
        ascii_rom[12'h348] = 8'h0C;
        ascii_rom[12'h349] = 8'h0C;
        ascii_rom[12'h34A] = 8'h0C;
        ascii_rom[12'h34B] = 8'h1E;
        ascii_rom[12'h34C] = 8'h00;
        ascii_rom[12'h34D] = 8'h00;
        ascii_rom[12'h34E] = 8'h00;
        ascii_rom[12'h34F] = 8'h00;
        // 0x35 5
        ascii_rom[12'h350] = 8'h00;
        ascii_rom[12'h351] = 8'h00;
        ascii_rom[12'h352] = 8'hFE;
        ascii_rom[12'h353] = 8'hC0;
        ascii_rom[12'h354] = 8'hC0;
        ascii_rom[12'h355] = 8'hC0;
        ascii_rom[12'h356] = 8'hFC;
        ascii_rom[12'h357] = 8'h06;
        ascii_rom[12'h358] = 8'h06;
        ascii_rom[12'h359] = 8'h06;
        ascii_rom[12'h35A] = 8'hC6;
        ascii_rom[12'h35B] = 8'h7C;
        ascii_rom[12'h35C] = 8'h00;
        ascii_rom[12'h35D] = 8'h00;
        ascii_rom[12'h35E] = 8'h00;
        ascii_rom[12'h35F] = 8'h00;
        // 0x36 6
        ascii_rom[12'h360] = 8'h00;
        ascii_rom[12'h361] = 8'h00;
        ascii_rom[12'h362] = 8'h38;
        ascii_rom[12'h363] = 8'h60;
        ascii_rom[12'h364] = 8'hC0;
        ascii_rom[12'h365] = 8'hC0;
        ascii_rom[12'h366] = 8'hFC;
        ascii_rom[12'h367] = 8'hC6;
        ascii_rom[12'h368] = 8'hC6;
        ascii_rom[12'h369] = 8'hC6;
        ascii_rom[12'h36A] = 8'hC6;
        ascii_rom[12'h36B] = 8'h7C;
        ascii_rom[12'h36C] = 8'h00;
        ascii_rom[12'h36D] = 8'h00;
        ascii_rom[12'h36E] = 8'h00;
        ascii_rom[12'h36F] = 8'h00;
        // 0x37 7
        ascii_rom[12'h370] = 8'h00;
        ascii_rom[12'h371] = 8'h00;
        ascii_rom[12'h372] = 8'hFE;
        ascii_rom[12'h373] = 8'hC6;
        ascii_rom[12'h374] = 8'h06;
        ascii_rom[12'h375] = 8'h06;
        ascii_rom[12'h376] = 8'h0C;
        ascii_rom[12'h377] = 8'h18;
        ascii_rom[12'h378] = 8'h30;
        ascii_rom[12'h379] = 8'h30;
        ascii_rom[12'h37A] = 8'h30;
        ascii_rom[12'h37B] = 8'h30;
        ascii_rom[12'h37C] = 8'h00;
        ascii_rom[12'h37D] = 8'h00;
        ascii_rom[12'h37E] = 8'h00;
        ascii_rom[12'h37F] = 8'h00;
        // 0x38 8
        ascii_rom[12'h380] = 8'h00;
        ascii_rom[12'h381] = 8'h00;
        ascii_rom[12'h382] = 8'h7C;
        ascii_rom[12'h383] = 8'hC6;
        ascii_rom[12'h384] = 8'hC6;
        ascii_rom[12'h385] = 8'hC6;
        ascii_rom[12'h386] = 8'h7C;
        ascii_rom[12'h387] = 8'hC6;
        ascii_rom[12'h388] = 8'hC6;
        ascii_rom[12'h389] = 8'hC6;
        ascii_rom[12'h38A] = 8'hC6;
        ascii_rom[12'h38B] = 8'h7C;
        ascii_rom[12'h38C] = 8'h00;
        ascii_rom[12'h38D] = 8'h00;
        ascii_rom[12'h38E] = 8'h00;
        ascii_rom[12'h38F] = 8'h00;
        // 0x39 9
        ascii_rom[12'h390] = 8'h00;
        ascii_rom[12'h391] = 8'h00;
        ascii_rom[12'h392] = 8'h7C;
        ascii_rom[12'h393] = 8'hC6;
        ascii_rom[12'h394] = 8'hC6;
        ascii_rom[12'h395] = 8'hC6;
        ascii_rom[12'h396] = 8'h7E;
        ascii_rom[12'h397] = 8'h06;
        ascii_rom[12'h398] = 8'h06;
        ascii_rom[12'h399] = 8'h06;
        ascii_rom[12'h39A] = 8'h0C;
        ascii_rom[12'h39B] = 8'h78;
        ascii_rom[12'h39C] = 8'h00;
        ascii_rom[12'h39D] = 8'h00;
        ascii_rom[12'h39E] = 8'h00;
        ascii_rom[12'h39F] = 8'h00;
        // 0x3A :
        ascii_rom[12'h3A0] = 8'h00;
        ascii_rom[12'h3A1] = 8'h00;
        ascii_rom[12'h3A2] = 8'h00;
        ascii_rom[12'h3A3] = 8'h00;
        ascii_rom[12'h3A4] = 8'h18;
        ascii_rom[12'h3A5] = 8'h18;
        ascii_rom[12'h3A6] = 8'h00;
        ascii_rom[12'h3A7] = 8'h00;
        ascii_rom[12'h3A8] = 8'h00;
        ascii_rom[12'h3A9] = 8'h18;
        ascii_rom[12'h3AA] = 8'h18;
        ascii_rom[12'h3AB] = 8'h00;
        ascii_rom[12'h3AC] = 8'h00;
        ascii_rom[12'h3AD] = 8'h00;
        ascii_rom[12'h3AE] = 8'h00;
        ascii_rom[12'h3AF] = 8'h00;
        // 0x3B ;
        ascii_rom[12'h3B0] = 8'h00;
        ascii_rom[12'h3B1] = 8'h00;
        ascii_rom[12'h3B2] = 8'h00;
        ascii_rom[12'h3B3] = 8'h00;
        ascii_rom[12'h3B4] = 8'h18;
        ascii_rom[12'h3B5] = 8'h18;
        ascii_rom[12'h3B6] = 8'h00;
        ascii_rom[12'h3B7] = 8'h00;
        ascii_rom[12'h3B8] = 8'h00;
        ascii_rom[12'h3B9] = 8'h18;
        ascii_rom[12'h3BA] = 8'h18;
        ascii_rom[12'h3BB] = 8'h30;
        ascii_rom[12'h3BC] = 8'h00;
        ascii_rom[12'h3BD] = 8'h00;
        ascii_rom[12'h3BE] = 8'h00;
        ascii_rom[12'h3BF] = 8'h00;
        // 0x3C <
        ascii_rom[12'h3C0] = 8'h00;
        ascii_rom[12'h3C1] = 8'h00;
        ascii_rom[12'h3C2] = 8'h00;
        ascii_rom[12'h3C3] = 8'h06;
        ascii_rom[12'h3C4] = 8'h0C;
        ascii_rom[12'h3C5] = 8'h18;
        ascii_rom[12'h3C6] = 8'h30;
        ascii_rom[12'h3C7] = 8'h60;
        ascii_rom[12'h3C8] = 8'h30;
        ascii_rom[12'h3C9] = 8'h18;
        ascii_rom[12'h3CA] = 8'h0C;
        ascii_rom[12'h3CB] = 8'h06;
        ascii_rom[12'h3CC] = 8'h00;
        ascii_rom[12'h3CD] = 8'h00;
        ascii_rom[12'h3CE] = 8'h00;
        ascii_rom[12'h3CF] = 8'h00;
        // 0x3D =
        ascii_rom[12'h3D0] = 8'h00;
        ascii_rom[12'h3D1] = 8'h00;
        ascii_rom[12'h3D2] = 8'h00;
        ascii_rom[12'h3D3] = 8'h00;
        ascii_rom[12'h3D4] = 8'h00;
        ascii_rom[12'h3D5] = 8'h7E;
        ascii_rom[12'h3D6] = 8'h00;
        ascii_rom[12'h3D7] = 8'h00;
        ascii_rom[12'h3D8] = 8'h7E;
        ascii_rom[12'h3D9] = 8'h00;
        ascii_rom[12'h3DA] = 8'h00;
        ascii_rom[12'h3DB] = 8'h00;
        ascii_rom[12'h3DC] = 8'h00;
        ascii_rom[12'h3DD] = 8'h00;
        ascii_rom[12'h3DE] = 8'h00;
        ascii_rom[12'h3DF] = 8'h00;
        // 0x3E >
        ascii_rom[12'h3E0] = 8'h00;
        ascii_rom[12'h3E1] = 8'h00;
        ascii_rom[12'h3E2] = 8'h00;
        ascii_rom[12'h3E3] = 8'h60;
        ascii_rom[12'h3E4] = 8'h30;
        ascii_rom[12'h3E5] = 8'h18;
        ascii_rom[12'h3E6] = 8'h0C;
        ascii_rom[12'h3E7] = 8'h06;
        ascii_rom[12'h3E8] = 8'h0C;
        ascii_rom[12'h3E9] = 8'h18;
        ascii_rom[12'h3EA] = 8'h30;
        ascii_rom[12'h3EB] = 8'h60;
        ascii_rom[12'h3EC] = 8'h00;
        ascii_rom[12'h3ED] = 8'h00;
        ascii_rom[12'h3EE] = 8'h00;
        ascii_rom[12'h3EF] = 8'h00;
        // 0x3F ?
        ascii_rom[12'h3F0] = 8'h00;
        ascii_rom[12'h3F1] = 8'h00;
        ascii_rom[12'h3F2] = 8'h7C;
        ascii_rom[12'h3F3] = 8'hC6;
        ascii_rom[12'h3F4] = 8'hC6;
        ascii_rom[12'h3F5] = 8'h0C;
        ascii_rom[12'h3F6] = 8'h18;
        ascii_rom[12'h3F7] = 8'h18;
        ascii_rom[12'h3F8] = 8'h18;
        ascii_rom[12'h3F9] = 8'h00;
        ascii_rom[12'h3FA] = 8'h18;
        ascii_rom[12'h3FB] = 8'h18;
        ascii_rom[12'h3FC] = 8'h00;
        ascii_rom[12'h3FD] = 8'h00;
        ascii_rom[12'h3FE] = 8'h00;
        ascii_rom[12'h3FF] = 8'h00;
        // 0x40 @
        ascii_rom[12'h400] = 8'h00;
        ascii_rom[12'h401] = 8'h00;
        ascii_rom[12'h402] = 8'h00;
        ascii_rom[12'h403] = 8'h7C;
        ascii_rom[12'h404] = 8'hC6;
        ascii_rom[12'h405] = 8'hC6;
        ascii_rom[12'h406] = 8'hDE;
        ascii_rom[12'h407] = 8'hDE;
        ascii_rom[12'h408] = 8'hDE;
        ascii_rom[12'h409] = 8'hDC;
        ascii_rom[12'h40A] = 8'hC0;
        ascii_rom[12'h40B] = 8'h7C;
        ascii_rom[12'h40C] = 8'h00;
        ascii_rom[12'h40D] = 8'h00;
        ascii_rom[12'h40E] = 8'h00;
        ascii_rom[12'h40F] = 8'h00;
        // 0x41 A
        ascii_rom[12'h410] = 8'h00;
        ascii_rom[12'h411] = 8'h00;
        ascii_rom[12'h412] = 8'h10;
        ascii_rom[12'h413] = 8'h38;
        ascii_rom[12'h414] = 8'h6C;
        ascii_rom[12'h415] = 8'hC6;
        ascii_rom[12'h416] = 8'hC6;
        ascii_rom[12'h417] = 8'hFE;
        ascii_rom[12'h418] = 8'hC6;
        ascii_rom[12'h419] = 8'hC6;
        ascii_rom[12'h41A] = 8'hC6;
        ascii_rom[12'h41B] = 8'hC6;
        ascii_rom[12'h41C] = 8'h00;
        ascii_rom[12'h41D] = 8'h00;
        ascii_rom[12'h41E] = 8'h00;
        ascii_rom[12'h41F] = 8'h00;
        // 0x42 B
        ascii_rom[12'h420] = 8'h00;
        ascii_rom[12'h421] = 8'h00;
        ascii_rom[12'h422] = 8'hFC;
        ascii_rom[12'h423] = 8'h66;
        ascii_rom[12'h424] = 8'h66;
        ascii_rom[12'h425] = 8'h66;
        ascii_rom[12'h426] = 8'h7C;
        ascii_rom[12'h427] = 8'h66;
        ascii_rom[12'h428] = 8'h66;
        ascii_rom[12'h429] = 8'h66;
        ascii_rom[12'h42A] = 8'h66;
        ascii_rom[12'h42B] = 8'hFC;
        ascii_rom[12'h42C] = 8'h00;
        ascii_rom[12'h42D] = 8'h00;
        ascii_rom[12'h42E] = 8'h00;
        ascii_rom[12'h42F] = 8'h00;
        // 0x43 C
        ascii_rom[12'h430] = 8'h00;
        ascii_rom[12'h431] = 8'h00;
        ascii_rom[12'h432] = 8'h3C;
        ascii_rom[12'h433] = 8'h66;
        ascii_rom[12'h434] = 8'hC2;
        ascii_rom[12'h435] = 8'hC0;
        ascii_rom[12'h436] = 8'hC0;
        ascii_rom[12'h437] = 8'hC0;
        ascii_rom[12'h438] = 8'hC0;
        ascii_rom[12'h439] = 8'hC2;
        ascii_rom[12'h43A] = 8'h66;
        ascii_rom[12'h43B] = 8'h3C;
        ascii_rom[12'h43C] = 8'h00;
        ascii_rom[12'h43D] = 8'h00;
        ascii_rom[12'h43E] = 8'h00;
        ascii_rom[12'h43F] = 8'h00;
        // 0x44 D
        ascii_rom[12'h440] = 8'h00;
        ascii_rom[12'h441] = 8'h00;
        ascii_rom[12'h442] = 8'hF8;
        ascii_rom[12'h443] = 8'h6C;
        ascii_rom[12'h444] = 8'h66;
        ascii_rom[12'h445] = 8'h66;
        ascii_rom[12'h446] = 8'h66;
        ascii_rom[12'h447] = 8'h66;
        ascii_rom[12'h448] = 8'h66;
        ascii_rom[12'h449] = 8'h66;
        ascii_rom[12'h44A] = 8'h6C;
        ascii_rom[12'h44B] = 8'hF8;
        ascii_rom[12'h44C] = 8'h00;
        ascii_rom[12'h44D] = 8'h00;
        ascii_rom[12'h44E] = 8'h00;
        ascii_rom[12'h44F] = 8'h00;
        // 0x45 E
        ascii_rom[12'h450] = 8'h00;
        ascii_rom[12'h451] = 8'h00;
        ascii_rom[12'h452] = 8'hFE;
        ascii_rom[12'h453] = 8'h66;
        ascii_rom[12'h454] = 8'h62;
        ascii_rom[12'h455] = 8'h68;
        ascii_rom[12'h456] = 8'h78;
        ascii_rom[12'h457] = 8'h68;
        ascii_rom[12'h458] = 8'h60;
        ascii_rom[12'h459] = 8'h62;
        ascii_rom[12'h45A] = 8'h66;
        ascii_rom[12'h45B] = 8'hFE;
        ascii_rom[12'h45C] = 8'h00;
        ascii_rom[12'h45D] = 8'h00;
        ascii_rom[12'h45E] = 8'h00;
        ascii_rom[12'h45F] = 8'h00;
        // 0x46 F
        ascii_rom[12'h460] = 8'h00;
        ascii_rom[12'h461] = 8'h00;
        ascii_rom[12'h462] = 8'hFE;
        ascii_rom[12'h463] = 8'h66;
        ascii_rom[12'h464] = 8'h62;
        ascii_rom[12'h465] = 8'h68;
        ascii_rom[12'h466] = 8'h78;
        ascii_rom[12'h467] = 8'h68;
        ascii_rom[12'h468] = 8'h60;
        ascii_rom[12'h469] = 8'h60;
        ascii_rom[12'h46A] = 8'h60;
        ascii_rom[12'h46B] = 8'hF0;
        ascii_rom[12'h46C] = 8'h00;
        ascii_rom[12'h46D] = 8'h00;
        ascii_rom[12'h46E] = 8'h00;
        ascii_rom[12'h46F] = 8'h00;
        // 0x47 G
        ascii_rom[12'h470] = 8'h00;
        ascii_rom[12'h471] = 8'h00;
        ascii_rom[12'h472] = 8'h3C;
        ascii_rom[12'h473] = 8'h66;
        ascii_rom[12'h474] = 8'hC2;
        ascii_rom[12'h475] = 8'hC0;
        ascii_rom[12'h476] = 8'hC0;
        ascii_rom[12'h477] = 8'hDE;
        ascii_rom[12'h478] = 8'hC6;
        ascii_rom[12'h479] = 8'hC6;
        ascii_rom[12'h47A] = 8'h66;
        ascii_rom[12'h47B] = 8'h3A;
        ascii_rom[12'h47C] = 8'h00;
        ascii_rom[12'h47D] = 8'h00;
        ascii_rom[12'h47E] = 8'h00;
        ascii_rom[12'h47F] = 8'h00;
        // 0x48 H
        ascii_rom[12'h480] = 8'h00;
        ascii_rom[12'h481] = 8'h00;
        ascii_rom[12'h482] = 8'hC6;
        ascii_rom[12'h483] = 8'hC6;
        ascii_rom[12'h484] = 8'hC6;
        ascii_rom[12'h485] = 8'hC6;
        ascii_rom[12'h486] = 8'hFE;
        ascii_rom[12'h487] = 8'hC6;
        ascii_rom[12'h488] = 8'hC6;
        ascii_rom[12'h489] = 8'hC6;
        ascii_rom[12'h48A] = 8'hC6;
        ascii_rom[12'h48B] = 8'hC6;
        ascii_rom[12'h48C] = 8'h00;
        ascii_rom[12'h48D] = 8'h00;
        ascii_rom[12'h48E] = 8'h00;
        ascii_rom[12'h48F] = 8'h00;
        // 0x49 I
        ascii_rom[12'h490] = 8'h00;
        ascii_rom[12'h491] = 8'h00;
        ascii_rom[12'h492] = 8'h3C;
        ascii_rom[12'h493] = 8'h18;
        ascii_rom[12'h494] = 8'h18;
        ascii_rom[12'h495] = 8'h18;
        ascii_rom[12'h496] = 8'h18;
        ascii_rom[12'h497] = 8'h18;
        ascii_rom[12'h498] = 8'h18;
        ascii_rom[12'h499] = 8'h18;
        ascii_rom[12'h49A] = 8'h18;
        ascii_rom[12'h49B] = 8'h3C;
        ascii_rom[12'h49C] = 8'h00;
        ascii_rom[12'h49D] = 8'h00;
        ascii_rom[12'h49E] = 8'h00;
        ascii_rom[12'h49F] = 8'h00;
        // 0x4A J
        ascii_rom[12'h4A0] = 8'h00;
        ascii_rom[12'h4A1] = 8'h00;
        ascii_rom[12'h4A2] = 8'h1E;
        ascii_rom[12'h4A3] = 8'h0C;
        ascii_rom[12'h4A4] = 8'h0C;
        ascii_rom[12'h4A5] = 8'h0C;
        ascii_rom[12'h4A6] = 8'h0C;
        ascii_rom[12'h4A7] = 8'h0C;
        ascii_rom[12'h4A8] = 8'hCC;
        ascii_rom[12'h4A9] = 8'hCC;
        ascii_rom[12'h4AA] = 8'hCC;
        ascii_rom[12'h4AB] = 8'h78;
        ascii_rom[12'h4AC] = 8'h00;
        ascii_rom[12'h4AD] = 8'h00;
        ascii_rom[12'h4AE] = 8'h00;
        ascii_rom[12'h4AF] = 8'h00;
        // 0x4B K
        ascii_rom[12'h4B0] = 8'h00;
        ascii_rom[12'h4B1] = 8'h00;
        ascii_rom[12'h4B2] = 8'hE6;
        ascii_rom[12'h4B3] = 8'h66;
        ascii_rom[12'h4B4] = 8'h66;
        ascii_rom[12'h4B5] = 8'h6C;
        ascii_rom[12'h4B6] = 8'h78;
        ascii_rom[12'h4B7] = 8'h78;
        ascii_rom[12'h4B8] = 8'h6C;
        ascii_rom[12'h4B9] = 8'h66;
        ascii_rom[12'h4BA] = 8'h66;
        ascii_rom[12'h4BB] = 8'hE6;
        ascii_rom[12'h4BC] = 8'h00;
        ascii_rom[12'h4BD] = 8'h00;
        ascii_rom[12'h4BE] = 8'h00;
        ascii_rom[12'h4BF] = 8'h00;
        // 0x4C L
        ascii_rom[12'h4C0] = 8'h00;
        ascii_rom[12'h4C1] = 8'h00;
        ascii_rom[12'h4C2] = 8'hF0;
        ascii_rom[12'h4C3] = 8'h60;
        ascii_rom[12'h4C4] = 8'h60;
        ascii_rom[12'h4C5] = 8'h60;
        ascii_rom[12'h4C6] = 8'h60;
        ascii_rom[12'h4C7] = 8'h60;
        ascii_rom[12'h4C8] = 8'h60;
        ascii_rom[12'h4C9] = 8'h62;
        ascii_rom[12'h4CA] = 8'h66;
        ascii_rom[12'h4CB] = 8'hFE;
        ascii_rom[12'h4CC] = 8'h00;
        ascii_rom[12'h4CD] = 8'h00;
        ascii_rom[12'h4CE] = 8'h00;
        ascii_rom[12'h4CF] = 8'h00;
        // 0x4D M
        ascii_rom[12'h4D0] = 8'h00;
        ascii_rom[12'h4D1] = 8'h00;
        ascii_rom[12'h4D2] = 8'hC6;
        ascii_rom[12'h4D3] = 8'hEE;
        ascii_rom[12'h4D4] = 8'hFE;
        ascii_rom[12'h4D5] = 8'hFE;
        ascii_rom[12'h4D6] = 8'hD6;
        ascii_rom[12'h4D7] = 8'hC6;
        ascii_rom[12'h4D8] = 8'hC6;
        ascii_rom[12'h4D9] = 8'hC6;
        ascii_rom[12'h4DA] = 8'hC6;
        ascii_rom[12'h4DB] = 8'hC6;
        ascii_rom[12'h4DC] = 8'h00;
        ascii_rom[12'h4DD] = 8'h00;
        ascii_rom[12'h4DE] = 8'h00;
        ascii_rom[12'h4DF] = 8'h00;
        // 0x4E N
        ascii_rom[12'h4E0] = 8'h00;
        ascii_rom[12'h4E1] = 8'h00;
        ascii_rom[12'h4E2] = 8'hC6;
        ascii_rom[12'h4E3] = 8'hE6;
        ascii_rom[12'h4E4] = 8'hF6;
        ascii_rom[12'h4E5] = 8'hFE;
        ascii_rom[12'h4E6] = 8'hDE;
        ascii_rom[12'h4E7] = 8'hCE;
        ascii_rom[12'h4E8] = 8'hC6;
        ascii_rom[12'h4E9] = 8'hC6;
        ascii_rom[12'h4EA] = 8'hC6;
        ascii_rom[12'h4EB] = 8'hC6;
        ascii_rom[12'h4EC] = 8'h00;
        ascii_rom[12'h4ED] = 8'h00;
        ascii_rom[12'h4EE] = 8'h00;
        ascii_rom[12'h4EF] = 8'h00;
        // 0x4F O
        ascii_rom[12'h4F0] = 8'h00;
        ascii_rom[12'h4F1] = 8'h00;
        ascii_rom[12'h4F2] = 8'h7C;
        ascii_rom[12'h4F3] = 8'hC6;
        ascii_rom[12'h4F4] = 8'hC6;
        ascii_rom[12'h4F5] = 8'hC6;
        ascii_rom[12'h4F6] = 8'hC6;
        ascii_rom[12'h4F7] = 8'hC6;
        ascii_rom[12'h4F8] = 8'hC6;
        ascii_rom[12'h4F9] = 8'hC6;
        ascii_rom[12'h4FA] = 8'hC6;
        ascii_rom[12'h4FB] = 8'h7C;
        ascii_rom[12'h4FC] = 8'h00;
        ascii_rom[12'h4FD] = 8'h00;
        ascii_rom[12'h4FE] = 8'h00;
        ascii_rom[12'h4FF] = 8'h00;
        // 0x50 P
        ascii_rom[12'h500] = 8'h00;
        ascii_rom[12'h501] = 8'h00;
        ascii_rom[12'h502] = 8'hFC;
        ascii_rom[12'h503] = 8'h66;
        ascii_rom[12'h504] = 8'h66;
        ascii_rom[12'h505] = 8'h66;
        ascii_rom[12'h506] = 8'h7C;
        ascii_rom[12'h507] = 8'h60;
        ascii_rom[12'h508] = 8'h60;
        ascii_rom[12'h509] = 8'h60;
        ascii_rom[12'h50A] = 8'h60;
        ascii_rom[12'h50B] = 8'hF0;
        ascii_rom[12'h50C] = 8'h00;
        ascii_rom[12'h50D] = 8'h00;
        ascii_rom[12'h50E] = 8'h00;
        ascii_rom[12'h50F] = 8'h00;
        // 0x51 Q
        ascii_rom[12'h510] = 8'h00;
        ascii_rom[12'h511] = 8'h00;
        ascii_rom[12'h512] = 8'h7C;
        ascii_rom[12'h513] = 8'hC6;
        ascii_rom[12'h514] = 8'hC6;
        ascii_rom[12'h515] = 8'hC6;
        ascii_rom[12'h516] = 8'hC6;
        ascii_rom[12'h517] = 8'hC6;
        ascii_rom[12'h518] = 8'hC6;
        ascii_rom[12'h519] = 8'hD6;
        ascii_rom[12'h51A] = 8'hDE;
        ascii_rom[12'h51B] = 8'h7C;
        ascii_rom[12'h51C] = 8'h0C;
        ascii_rom[12'h51D] = 8'h0E;
        ascii_rom[12'h51E] = 8'h00;
        ascii_rom[12'h51F] = 8'h00;
        // 0x52 R
        ascii_rom[12'h520] = 8'h00;
        ascii_rom[12'h521] = 8'h00;
        ascii_rom[12'h522] = 8'hFC;
        ascii_rom[12'h523] = 8'h66;
        ascii_rom[12'h524] = 8'h66;
        ascii_rom[12'h525] = 8'h66;
        ascii_rom[12'h526] = 8'h7C;
        ascii_rom[12'h527] = 8'h6C;
        ascii_rom[12'h528] = 8'h66;
        ascii_rom[12'h529] = 8'h66;
        ascii_rom[12'h52A] = 8'h66;
        ascii_rom[12'h52B] = 8'hE6;
        ascii_rom[12'h52C] = 8'h00;
        ascii_rom[12'h52D] = 8'h00;
        ascii_rom[12'h52E] = 8'h00;
        ascii_rom[12'h52F] = 8'h00;
        // 0x53 S
        ascii_rom[12'h530] = 8'h00;
        ascii_rom[12'h531] = 8'h00;
        ascii_rom[12'h532] = 8'h7C;
        ascii_rom[12'h533] = 8'hC6;
        ascii_rom[12'h534] = 8'hC6;
        ascii_rom[12'h535] = 8'h60;
        ascii_rom[12'h536] = 8'h38;
        ascii_rom[12'h537] = 8'h0C;
        ascii_rom[12'h538] = 8'h06;
        ascii_rom[12'h539] = 8'hC6;
        ascii_rom[12'h53A] = 8'hC6;
        ascii_rom[12'h53B] = 8'h7C;
        ascii_rom[12'h53C] = 8'h00;
        ascii_rom[12'h53D] = 8'h00;
        ascii_rom[12'h53E] = 8'h00;
        ascii_rom[12'h53F] = 8'h00;
        // 0x54 T
        ascii_rom[12'h540] = 8'h00;
        ascii_rom[12'h541] = 8'h00;
        ascii_rom[12'h542] = 8'h7E;
        ascii_rom[12'h543] = 8'h7E;
        ascii_rom[12'h544] = 8'h5A;
        ascii_rom[12'h545] = 8'h18;
        ascii_rom[12'h546] = 8'h18;
        ascii_rom[12'h547] = 8'h18;
        ascii_rom[12'h548] = 8'h18;
        ascii_rom[12'h549] = 8'h18;
        ascii_rom[12'h54A] = 8'h18;
        ascii_rom[12'h54B] = 8'h3C;
        ascii_rom[12'h54C] = 8'h00;
        ascii_rom[12'h54D] = 8'h00;
        ascii_rom[12'h54E] = 8'h00;
        ascii_rom[12'h54F] = 8'h00;
        // 0x55 U
        ascii_rom[12'h550] = 8'h00;
        ascii_rom[12'h551] = 8'h00;
        ascii_rom[12'h552] = 8'hC6;
        ascii_rom[12'h553] = 8'hC6;
        ascii_rom[12'h554] = 8'hC6;
        ascii_rom[12'h555] = 8'hC6;
        ascii_rom[12'h556] = 8'hC6;
        ascii_rom[12'h557] = 8'hC6;
        ascii_rom[12'h558] = 8'hC6;
        ascii_rom[12'h559] = 8'hC6;
        ascii_rom[12'h55A] = 8'hC6;
        ascii_rom[12'h55B] = 8'h7C;
        ascii_rom[12'h55C] = 8'h00;
        ascii_rom[12'h55D] = 8'h00;
        ascii_rom[12'h55E] = 8'h00;
        ascii_rom[12'h55F] = 8'h00;
        // 0x56 V
        ascii_rom[12'h560] = 8'h00;
        ascii_rom[12'h561] = 8'h00;
        ascii_rom[12'h562] = 8'hC6;
        ascii_rom[12'h563] = 8'hC6;
        ascii_rom[12'h564] = 8'hC6;
        ascii_rom[12'h565] = 8'hC6;
        ascii_rom[12'h566] = 8'hC6;
        ascii_rom[12'h567] = 8'hC6;
        ascii_rom[12'h568] = 8'hC6;
        ascii_rom[12'h569] = 8'h6C;
        ascii_rom[12'h56A] = 8'h38;
        ascii_rom[12'h56B] = 8'h10;
        ascii_rom[12'h56C] = 8'h00;
        ascii_rom[12'h56D] = 8'h00;
        ascii_rom[12'h56E] = 8'h00;
        ascii_rom[12'h56F] = 8'h00;
        // 0x57 W
        ascii_rom[12'h570] = 8'h00;
        ascii_rom[12'h571] = 8'h00;
        ascii_rom[12'h572] = 8'hC6;
        ascii_rom[12'h573] = 8'hC6;
        ascii_rom[12'h574] = 8'hC6;
        ascii_rom[12'h575] = 8'hC6;
        ascii_rom[12'h576] = 8'hD6;
        ascii_rom[12'h577] = 8'hD6;
        ascii_rom[12'h578] = 8'hD6;
        ascii_rom[12'h579] = 8'hFE;
        ascii_rom[12'h57A] = 8'hEE;
        ascii_rom[12'h57B] = 8'h6C;
        ascii_rom[12'h57C] = 8'h00;
        ascii_rom[12'h57D] = 8'h00;
        ascii_rom[12'h57E] = 8'h00;
        ascii_rom[12'h57F] = 8'h00;
        // 0x58 X
        ascii_rom[12'h580] = 8'h00;
        ascii_rom[12'h581] = 8'h00;
        ascii_rom[12'h582] = 8'hC6;
        ascii_rom[12'h583] = 8'hC6;
        ascii_rom[12'h584] = 8'h6C;
        ascii_rom[12'h585] = 8'h7C;
        ascii_rom[12'h586] = 8'h38;
        ascii_rom[12'h587] = 8'h38;
        ascii_rom[12'h588] = 8'h7C;
        ascii_rom[12'h589] = 8'h6C;
        ascii_rom[12'h58A] = 8'hC6;
        ascii_rom[12'h58B] = 8'hC6;
        ascii_rom[12'h58C] = 8'h00;
        ascii_rom[12'h58D] = 8'h00;
        ascii_rom[12'h58E] = 8'h00;
        ascii_rom[12'h58F] = 8'h00;
        // 0x59 Y
        ascii_rom[12'h590] = 8'h00;
        ascii_rom[12'h591] = 8'h00;
        ascii_rom[12'h592] = 8'h66;
        ascii_rom[12'h593] = 8'h66;
        ascii_rom[12'h594] = 8'h66;
        ascii_rom[12'h595] = 8'h66;
        ascii_rom[12'h596] = 8'h3C;
        ascii_rom[12'h597] = 8'h18;
        ascii_rom[12'h598] = 8'h18;
        ascii_rom[12'h599] = 8'h18;
        ascii_rom[12'h59A] = 8'h18;
        ascii_rom[12'h59B] = 8'h3C;
        ascii_rom[12'h59C] = 8'h00;
        ascii_rom[12'h59D] = 8'h00;
        ascii_rom[12'h59E] = 8'h00;
        ascii_rom[12'h59F] = 8'h00;
        // 0x5A Z
        ascii_rom[12'h5A0] = 8'h00;
        ascii_rom[12'h5A1] = 8'h00;
        ascii_rom[12'h5A2] = 8'hFE;
        ascii_rom[12'h5A3] = 8'hC6;
        ascii_rom[12'h5A4] = 8'h86;
        ascii_rom[12'h5A5] = 8'h0C;
        ascii_rom[12'h5A6] = 8'h18;
        ascii_rom[12'h5A7] = 8'h30;
        ascii_rom[12'h5A8] = 8'h60;
        ascii_rom[12'h5A9] = 8'hC2;
        ascii_rom[12'h5AA] = 8'hC6;
        ascii_rom[12'h5AB] = 8'hFE;
        ascii_rom[12'h5AC] = 8'h00;
        ascii_rom[12'h5AD] = 8'h00;
        ascii_rom[12'h5AE] = 8'h00;
        ascii_rom[12'h5AF] = 8'h00;
        // 0x5B [
        ascii_rom[12'h5B0] = 8'h00;
        ascii_rom[12'h5B1] = 8'h00;
        ascii_rom[12'h5B2] = 8'h3C;
        ascii_rom[12'h5B3] = 8'h30;
        ascii_rom[12'h5B4] = 8'h30;
        ascii_rom[12'h5B5] = 8'h30;
        ascii_rom[12'h5B6] = 8'h30;
        ascii_rom[12'h5B7] = 8'h30;
        ascii_rom[12'h5B8] = 8'h30;
        ascii_rom[12'h5B9] = 8'h30;
        ascii_rom[12'h5BA] = 8'h30;
        ascii_rom[12'h5BB] = 8'h3C;
        ascii_rom[12'h5BC] = 8'h00;
        ascii_rom[12'h5BD] = 8'h00;
        ascii_rom[12'h5BE] = 8'h00;
        ascii_rom[12'h5BF] = 8'h00;
        // 0x5C \
        ascii_rom[12'h5C0] = 8'h00;
        ascii_rom[12'h5C1] = 8'h00;
        ascii_rom[12'h5C2] = 8'h00;
        ascii_rom[12'h5C3] = 8'h80;
        ascii_rom[12'h5C4] = 8'hC0;
        ascii_rom[12'h5C5] = 8'hE0;
        ascii_rom[12'h5C6] = 8'h70;
        ascii_rom[12'h5C7] = 8'h38;
        ascii_rom[12'h5C8] = 8'h1C;
        ascii_rom[12'h5C9] = 8'h0E;
        ascii_rom[12'h5CA] = 8'h06;
        ascii_rom[12'h5CB] = 8'h02;
        ascii_rom[12'h5CC] = 8'h00;
        ascii_rom[12'h5CD] = 8'h00;
        ascii_rom[12'h5CE] = 8'h00;
        ascii_rom[12'h5CF] = 8'h00;
        // 0x5D ]
        ascii_rom[12'h5D0] = 8'h00;
        ascii_rom[12'h5D1] = 8'h00;
        ascii_rom[12'h5D2] = 8'h3C;
        ascii_rom[12'h5D3] = 8'h0C;
        ascii_rom[12'h5D4] = 8'h0C;
        ascii_rom[12'h5D5] = 8'h0C;
        ascii_rom[12'h5D6] = 8'h0C;
        ascii_rom[12'h5D7] = 8'h0C;
        ascii_rom[12'h5D8] = 8'h0C;
        ascii_rom[12'h5D9] = 8'h0C;
        ascii_rom[12'h5DA] = 8'h0C;
        ascii_rom[12'h5DB] = 8'h3C;
        ascii_rom[12'h5DC] = 8'h00;
        ascii_rom[12'h5DD] = 8'h00;
        ascii_rom[12'h5DE] = 8'h00;
        ascii_rom[12'h5DF] = 8'h00;
        // 0x5E ^
        ascii_rom[12'h5E0] = 8'h10;
        ascii_rom[12'h5E1] = 8'h38;
        ascii_rom[12'h5E2] = 8'h6C;
        ascii_rom[12'h5E3] = 8'hC6;
        ascii_rom[12'h5E4] = 8'h00;
        ascii_rom[12'h5E5] = 8'h00;
        ascii_rom[12'h5E6] = 8'h00;
        ascii_rom[12'h5E7] = 8'h00;
        ascii_rom[12'h5E8] = 8'h00;
        ascii_rom[12'h5E9] = 8'h00;
        ascii_rom[12'h5EA] = 8'h00;
        ascii_rom[12'h5EB] = 8'h00;
        ascii_rom[12'h5EC] = 8'h00;
        ascii_rom[12'h5ED] = 8'h00;
        ascii_rom[12'h5EE] = 8'h00;
        ascii_rom[12'h5EF] = 8'h00;
        // 0x5F _
        ascii_rom[12'h5F0] = 8'h00;
        ascii_rom[12'h5F1] = 8'h00;
        ascii_rom[12'h5F2] = 8'h00;
        ascii_rom[12'h5F3] = 8'h00;
        ascii_rom[12'h5F4] = 8'h00;
        ascii_rom[12'h5F5] = 8'h00;
        ascii_rom[12'h5F6] = 8'h00;
        ascii_rom[12'h5F7] = 8'h00;
        ascii_rom[12'h5F8] = 8'h00;
        ascii_rom[12'h5F9] = 8'h00;
        ascii_rom[12'h5FA] = 8'h00;
        ascii_rom[12'h5FB] = 8'h00;
        ascii_rom[12'h5FC] = 8'h00;
        ascii_rom[12'h5FD] = 8'hFF;
        ascii_rom[12'h5FE] = 8'h00;
        ascii_rom[12'h5FF] = 8'h00;
        // 0x60 `
        ascii_rom[12'h600] = 8'h00;
        ascii_rom[12'h601] = 8'h30;
        ascii_rom[12'h602] = 8'h18;
        ascii_rom[12'h603] = 8'h0C;
        ascii_rom[12'h604] = 8'h00;
        ascii_rom[12'h605] = 8'h00;
        ascii_rom[12'h606] = 8'h00;
        ascii_rom[12'h607] = 8'h00;
        ascii_rom[12'h608] = 8'h00;
        ascii_rom[12'h609] = 8'h00;
        ascii_rom[12'h60A] = 8'h00;
        ascii_rom[12'h60B] = 8'h00;
        ascii_rom[12'h60C] = 8'h00;
        ascii_rom[12'h60D] = 8'h00;
        ascii_rom[12'h60E] = 8'h00;
        ascii_rom[12'h60F] = 8'h00;
        // 0x61 a
        ascii_rom[12'h610] = 8'h00;
        ascii_rom[12'h611] = 8'h00;
        ascii_rom[12'h612] = 8'h00;
        ascii_rom[12'h613] = 8'h00;
        ascii_rom[12'h614] = 8'h00;
        ascii_rom[12'h615] = 8'h78;
        ascii_rom[12'h616] = 8'h0C;
        ascii_rom[12'h617] = 8'h7C;
        ascii_rom[12'h618] = 8'hCC;
        ascii_rom[12'h619] = 8'hCC;
        ascii_rom[12'h61A] = 8'hCC;
        ascii_rom[12'h61B] = 8'h76;
        ascii_rom[12'h61C] = 8'h00;
        ascii_rom[12'h61D] = 8'h00;
        ascii_rom[12'h61E] = 8'h00;
        ascii_rom[12'h61F] = 8'h00;
        // 0x62 b
        ascii_rom[12'h620] = 8'h00;
        ascii_rom[12'h621] = 8'h00;
        ascii_rom[12'h622] = 8'hE0;
        ascii_rom[12'h623] = 8'h60;
        ascii_rom[12'h624] = 8'h60;
        ascii_rom[12'h625] = 8'h78;
        ascii_rom[12'h626] = 8'h6C;
        ascii_rom[12'h627] = 8'h66;
        ascii_rom[12'h628] = 8'h66;
        ascii_rom[12'h629] = 8'h66;
        ascii_rom[12'h62A] = 8'h66;
        ascii_rom[12'h62B] = 8'h7C;
        ascii_rom[12'h62C] = 8'h00;
        ascii_rom[12'h62D] = 8'h00;
        ascii_rom[12'h62E] = 8'h00;
        ascii_rom[12'h62F] = 8'h00;
        // 0x63 c
        ascii_rom[12'h630] = 8'h00;
        ascii_rom[12'h631] = 8'h00;
        ascii_rom[12'h632] = 8'h00;
        ascii_rom[12'h633] = 8'h00;
        ascii_rom[12'h634] = 8'h00;
        ascii_rom[12'h635] = 8'h7C;
        ascii_rom[12'h636] = 8'hC6;
        ascii_rom[12'h637] = 8'hC0;
        ascii_rom[12'h638] = 8'hC0;
        ascii_rom[12'h639] = 8'hC0;
        ascii_rom[12'h63A] = 8'hC6;
        ascii_rom[12'h63B] = 8'h7C;
        ascii_rom[12'h63C] = 8'h00;
        ascii_rom[12'h63D] = 8'h00;
        ascii_rom[12'h63E] = 8'h00;
        ascii_rom[12'h63F] = 8'h00;
        // 0x64 d
        ascii_rom[12'h640] = 8'h00;
        ascii_rom[12'h641] = 8'h00;
        ascii_rom[12'h642] = 8'h1C;
        ascii_rom[12'h643] = 8'h0C;
        ascii_rom[12'h644] = 8'h0C;
        ascii_rom[12'h645] = 8'h3C;
        ascii_rom[12'h646] = 8'h6C;
        ascii_rom[12'h647] = 8'hCC;
        ascii_rom[12'h648] = 8'hCC;
        ascii_rom[12'h649] = 8'hCC;
        ascii_rom[12'h64A] = 8'hCC;
        ascii_rom[12'h64B] = 8'h76;
        ascii_rom[12'h64C] = 8'h00;
        ascii_rom[12'h64D] = 8'h00;
        ascii_rom[12'h64E] = 8'h00;
        ascii_rom[12'h64F] = 8'h00;
        // 0x65 e
        ascii_rom[12'h650] = 8'h00;
        ascii_rom[12'h651] = 8'h00;
        ascii_rom[12'h652] = 8'h00;
        ascii_rom[12'h653] = 8'h00;
        ascii_rom[12'h654] = 8'h00;
        ascii_rom[12'h655] = 8'h7C;
        ascii_rom[12'h656] = 8'hC6;
        ascii_rom[12'h657] = 8'hFE;
        ascii_rom[12'h658] = 8'hC0;
        ascii_rom[12'h659] = 8'hC0;
        ascii_rom[12'h65A] = 8'hC6;
        ascii_rom[12'h65B] = 8'h7C;
        ascii_rom[12'h65C] = 8'h00;
        ascii_rom[12'h65D] = 8'h00;
        ascii_rom[12'h65E] = 8'h00;
        ascii_rom[12'h65F] = 8'h00;
        // 0x66 f
        ascii_rom[12'h660] = 8'h00;
        ascii_rom[12'h661] = 8'h00;
        ascii_rom[12'h662] = 8'h1C;
        ascii_rom[12'h663] = 8'h36;
        ascii_rom[12'h664] = 8'h32;
        ascii_rom[12'h665] = 8'h30;
        ascii_rom[12'h666] = 8'h78;
        ascii_rom[12'h667] = 8'h30;
        ascii_rom[12'h668] = 8'h30;
        ascii_rom[12'h669] = 8'h30;
        ascii_rom[12'h66A] = 8'h30;
        ascii_rom[12'h66B] = 8'h78;
        ascii_rom[12'h66C] = 8'h00;
        ascii_rom[12'h66D] = 8'h00;
        ascii_rom[12'h66E] = 8'h00;
        ascii_rom[12'h66F] = 8'h00;
        // 0x67 g
        ascii_rom[12'h670] = 8'h00;
        ascii_rom[12'h671] = 8'h00;
        ascii_rom[12'h672] = 8'h00;
        ascii_rom[12'h673] = 8'h00;
        ascii_rom[12'h674] = 8'h00;
        ascii_rom[12'h675] = 8'h76;
        ascii_rom[12'h676] = 8'hCC;
        ascii_rom[12'h677] = 8'hCC;
        ascii_rom[12'h678] = 8'hCC;
        ascii_rom[12'h679] = 8'hCC;
        ascii_rom[12'h67A] = 8'hCC;
        ascii_rom[12'h67B] = 8'h7C;
        ascii_rom[12'h67C] = 8'h0C;
        ascii_rom[12'h67D] = 8'hCC;
        ascii_rom[12'h67E] = 8'h78;
        ascii_rom[12'h67F] = 8'h00;
        // 0x68 h
        ascii_rom[12'h680] = 8'h00;
        ascii_rom[12'h681] = 8'h00;
        ascii_rom[12'h682] = 8'hE0;
        ascii_rom[12'h683] = 8'h60;
        ascii_rom[12'h684] = 8'h60;
        ascii_rom[12'h685] = 8'h6C;
        ascii_rom[12'h686] = 8'h76;
        ascii_rom[12'h687] = 8'h66;
        ascii_rom[12'h688] = 8'h66;
        ascii_rom[12'h689] = 8'h66;
        ascii_rom[12'h68A] = 8'h66;
        ascii_rom[12'h68B] = 8'hE6;
        ascii_rom[12'h68C] = 8'h00;
        ascii_rom[12'h68D] = 8'h00;
        ascii_rom[12'h68E] = 8'h00;
        ascii_rom[12'h68F] = 8'h00;
        // 0x69 i
        ascii_rom[12'h690] = 8'h00;
        ascii_rom[12'h691] = 8'h00;
        ascii_rom[12'h692] = 8'h18;
        ascii_rom[12'h693] = 8'h18;
        ascii_rom[12'h694] = 8'h00;
        ascii_rom[12'h695] = 8'h38;
        ascii_rom[12'h696] = 8'h18;
        ascii_rom[12'h697] = 8'h18;
        ascii_rom[12'h698] = 8'h18;
        ascii_rom[12'h699] = 8'h18;
        ascii_rom[12'h69A] = 8'h18;
        ascii_rom[12'h69B] = 8'h3C;
        ascii_rom[12'h69C] = 8'h00;
        ascii_rom[12'h69D] = 8'h00;
        ascii_rom[12'h69E] = 8'h00;
        ascii_rom[12'h69F] = 8'h00;
        // 0x6A j
        ascii_rom[12'h6A0] = 8'h00;
        ascii_rom[12'h6A1] = 8'h00;
        ascii_rom[12'h6A2] = 8'h06;
        ascii_rom[12'h6A3] = 8'h06;
        ascii_rom[12'h6A4] = 8'h00;
        ascii_rom[12'h6A5] = 8'h0E;
        ascii_rom[12'h6A6] = 8'h06;
        ascii_rom[12'h6A7] = 8'h06;
        ascii_rom[12'h6A8] = 8'h06;
        ascii_rom[12'h6A9] = 8'h06;
        ascii_rom[12'h6AA] = 8'h06;
        ascii_rom[12'h6AB] = 8'h06;
        ascii_rom[12'h6AC] = 8'h66;
        ascii_rom[12'h6AD] = 8'h66;
        ascii_rom[12'h6AE] = 8'h3C;
        ascii_rom[12'h6AF] = 8'h00;
        // 0x6B k
        ascii_rom[12'h6B0] = 8'h00;
        ascii_rom[12'h6B1] = 8'h00;
        ascii_rom[12'h6B2] = 8'hE0;
        ascii_rom[12'h6B3] = 8'h60;
        ascii_rom[12'h6B4] = 8'h60;
        ascii_rom[12'h6B5] = 8'h66;
        ascii_rom[12'h6B6] = 8'h6C;
        ascii_rom[12'h6B7] = 8'h78;
        ascii_rom[12'h6B8] = 8'h78;
        ascii_rom[12'h6B9] = 8'h6C;
        ascii_rom[12'h6BA] = 8'h66;
        ascii_rom[12'h6BB] = 8'hE6;
        ascii_rom[12'h6BC] = 8'h00;
        ascii_rom[12'h6BD] = 8'h00;
        ascii_rom[12'h6BE] = 8'h00;
        ascii_rom[12'h6BF] = 8'h00;
        // 0x6C l
        ascii_rom[12'h6C0] = 8'h00;
        ascii_rom[12'h6C1] = 8'h00;
        ascii_rom[12'h6C2] = 8'h38;
        ascii_rom[12'h6C3] = 8'h18;
        ascii_rom[12'h6C4] = 8'h18;
        ascii_rom[12'h6C5] = 8'h18;
        ascii_rom[12'h6C6] = 8'h18;
        ascii_rom[12'h6C7] = 8'h18;
        ascii_rom[12'h6C8] = 8'h18;
        ascii_rom[12'h6C9] = 8'h18;
        ascii_rom[12'h6CA] = 8'h18;
        ascii_rom[12'h6CB] = 8'h3C;
        ascii_rom[12'h6CC] = 8'h00;
        ascii_rom[12'h6CD] = 8'h00;
        ascii_rom[12'h6CE] = 8'h00;
        ascii_rom[12'h6CF] = 8'h00;
        // 0x6D m
        ascii_rom[12'h6D0] = 8'h00;
        ascii_rom[12'h6D1] = 8'h00;
        ascii_rom[12'h6D2] = 8'h00;
        ascii_rom[12'h6D3] = 8'h00;
        ascii_rom[12'h6D4] = 8'h00;
        ascii_rom[12'h6D5] = 8'hEC;
        ascii_rom[12'h6D6] = 8'hFE;
        ascii_rom[12'h6D7] = 8'hD6;
        ascii_rom[12'h6D8] = 8'hD6;
        ascii_rom[12'h6D9] = 8'hD6;
        ascii_rom[12'h6DA] = 8'hD6;
        ascii_rom[12'h6DB] = 8'hC6;
        ascii_rom[12'h6DC] = 8'h00;
        ascii_rom[12'h6DD] = 8'h00;
        ascii_rom[12'h6DE] = 8'h00;
        ascii_rom[12'h6DF] = 8'h00;
        // 0x6E n
        ascii_rom[12'h6E0] = 8'h00;
        ascii_rom[12'h6E1] = 8'h00;
        ascii_rom[12'h6E2] = 8'h00;
        ascii_rom[12'h6E3] = 8'h00;
        ascii_rom[12'h6E4] = 8'h00;
        ascii_rom[12'h6E5] = 8'hDC;
        ascii_rom[12'h6E6] = 8'h66;
        ascii_rom[12'h6E7] = 8'h66;
        ascii_rom[12'h6E8] = 8'h66;
        ascii_rom[12'h6E9] = 8'h66;
        ascii_rom[12'h6EA] = 8'h66;
        ascii_rom[12'h6EB] = 8'h66;
        ascii_rom[12'h6EC] = 8'h00;
        ascii_rom[12'h6ED] = 8'h00;
        ascii_rom[12'h6EE] = 8'h00;
        ascii_rom[12'h6EF] = 8'h00;
        // 0x6F o
        ascii_rom[12'h6F0] = 8'h00;
        ascii_rom[12'h6F1] = 8'h00;
        ascii_rom[12'h6F2] = 8'h00;
        ascii_rom[12'h6F3] = 8'h00;
        ascii_rom[12'h6F4] = 8'h00;
        ascii_rom[12'h6F5] = 8'h7C;
        ascii_rom[12'h6F6] = 8'hC6;
        ascii_rom[12'h6F7] = 8'hC6;
        ascii_rom[12'h6F8] = 8'hC6;
        ascii_rom[12'h6F9] = 8'hC6;
        ascii_rom[12'h6FA] = 8'hC6;
        ascii_rom[12'h6FB] = 8'h7C;
        ascii_rom[12'h6FC] = 8'h00;
        ascii_rom[12'h6FD] = 8'h00;
        ascii_rom[12'h6FE] = 8'h00;
        ascii_rom[12'h6FF] = 8'h00;
        // 0x70 p
        ascii_rom[12'h700] = 8'h00;
        ascii_rom[12'h701] = 8'h00;
        ascii_rom[12'h702] = 8'h00;
        ascii_rom[12'h703] = 8'h00;
        ascii_rom[12'h704] = 8'h00;
        ascii_rom[12'h705] = 8'hDC;
        ascii_rom[12'h706] = 8'h66;
        ascii_rom[12'h707] = 8'h66;
        ascii_rom[12'h708] = 8'h66;
        ascii_rom[12'h709] = 8'h66;
        ascii_rom[12'h70A] = 8'h66;
        ascii_rom[12'h70B] = 8'h7C;
        ascii_rom[12'h70C] = 8'h60;
        ascii_rom[12'h70D] = 8'h60;
        ascii_rom[12'h70E] = 8'hF0;
        ascii_rom[12'h70F] = 8'h00;
        // 0x71 q
        ascii_rom[12'h710] = 8'h00;
        ascii_rom[12'h711] = 8'h00;
        ascii_rom[12'h712] = 8'h00;
        ascii_rom[12'h713] = 8'h00;
        ascii_rom[12'h714] = 8'h00;
        ascii_rom[12'h715] = 8'h76;
        ascii_rom[12'h716] = 8'hCC;
        ascii_rom[12'h717] = 8'hCC;
        ascii_rom[12'h718] = 8'hCC;
        ascii_rom[12'h719] = 8'hCC;
        ascii_rom[12'h71A] = 8'hCC;
        ascii_rom[12'h71B] = 8'h7C;
        ascii_rom[12'h71C] = 8'h0C;
        ascii_rom[12'h71D] = 8'h0C;
        ascii_rom[12'h71E] = 8'h1E;
        ascii_rom[12'h71F] = 8'h00;
        // 0x72 r
        ascii_rom[12'h720] = 8'h00;
        ascii_rom[12'h721] = 8'h00;
        ascii_rom[12'h722] = 8'h00;
        ascii_rom[12'h723] = 8'h00;
        ascii_rom[12'h724] = 8'h00;
        ascii_rom[12'h725] = 8'hDC;
        ascii_rom[12'h726] = 8'h76;
        ascii_rom[12'h727] = 8'h66;
        ascii_rom[12'h728] = 8'h60;
        ascii_rom[12'h729] = 8'h60;
        ascii_rom[12'h72A] = 8'h60;
        ascii_rom[12'h72B] = 8'hF0;
        ascii_rom[12'h72C] = 8'h00;
        ascii_rom[12'h72D] = 8'h00;
        ascii_rom[12'h72E] = 8'h00;
        ascii_rom[12'h72F] = 8'h00;
        // 0x73 s
        ascii_rom[12'h730] = 8'h00;
        ascii_rom[12'h731] = 8'h00;
        ascii_rom[12'h732] = 8'h00;
        ascii_rom[12'h733] = 8'h00;
        ascii_rom[12'h734] = 8'h00;
        ascii_rom[12'h735] = 8'h7C;
        ascii_rom[12'h736] = 8'hC6;
        ascii_rom[12'h737] = 8'h60;
        ascii_rom[12'h738] = 8'h38;
        ascii_rom[12'h739] = 8'h0C;
        ascii_rom[12'h73A] = 8'hC6;
        ascii_rom[12'h73B] = 8'h7C;
        ascii_rom[12'h73C] = 8'h00;
        ascii_rom[12'h73D] = 8'h00;
        ascii_rom[12'h73E] = 8'h00;
        ascii_rom[12'h73F] = 8'h00;
        // 0x74 t
        ascii_rom[12'h740] = 8'h00;
        ascii_rom[12'h741] = 8'h00;
        ascii_rom[12'h742] = 8'h10;
        ascii_rom[12'h743] = 8'h30;
        ascii_rom[12'h744] = 8'h30;
        ascii_rom[12'h745] = 8'hFC;
        ascii_rom[12'h746] = 8'h30;
        ascii_rom[12'h747] = 8'h30;
        ascii_rom[12'h748] = 8'h30;
        ascii_rom[12'h749] = 8'h30;
        ascii_rom[12'h74A] = 8'h36;
        ascii_rom[12'h74B] = 8'h1C;
        ascii_rom[12'h74C] = 8'h00;
        ascii_rom[12'h74D] = 8'h00;
        ascii_rom[12'h74E] = 8'h00;
        ascii_rom[12'h74F] = 8'h00;
        // 0x75 u
        ascii_rom[12'h750] = 8'h00;
        ascii_rom[12'h751] = 8'h00;
        ascii_rom[12'h752] = 8'h00;
        ascii_rom[12'h753] = 8'h00;
        ascii_rom[12'h754] = 8'h00;
        ascii_rom[12'h755] = 8'hCC;
        ascii_rom[12'h756] = 8'hCC;
        ascii_rom[12'h757] = 8'hCC;
        ascii_rom[12'h758] = 8'hCC;
        ascii_rom[12'h759] = 8'hCC;
        ascii_rom[12'h75A] = 8'hCC;
        ascii_rom[12'h75B] = 8'h76;
        ascii_rom[12'h75C] = 8'h00;
        ascii_rom[12'h75D] = 8'h00;
        ascii_rom[12'h75E] = 8'h00;
        ascii_rom[12'h75F] = 8'h00;
        // 0x76 v
        ascii_rom[12'h760] = 8'h00;
        ascii_rom[12'h761] = 8'h00;
        ascii_rom[12'h762] = 8'h00;
        ascii_rom[12'h763] = 8'h00;
        ascii_rom[12'h764] = 8'h00;
        ascii_rom[12'h765] = 8'hC6;
        ascii_rom[12'h766] = 8'hC6;
        ascii_rom[12'h767] = 8'hC6;
        ascii_rom[12'h768] = 8'hC6;
        ascii_rom[12'h769] = 8'hC6;
        ascii_rom[12'h76A] = 8'h6C;
        ascii_rom[12'h76B] = 8'h38;
        ascii_rom[12'h76C] = 8'h00;
        ascii_rom[12'h76D] = 8'h00;
        ascii_rom[12'h76E] = 8'h00;
        ascii_rom[12'h76F] = 8'h00;
        // 0x77 w
        ascii_rom[12'h770] = 8'h00;
        ascii_rom[12'h771] = 8'h00;
        ascii_rom[12'h772] = 8'h00;
        ascii_rom[12'h773] = 8'h00;
        ascii_rom[12'h774] = 8'h00;
        ascii_rom[12'h775] = 8'hC6;
        ascii_rom[12'h776] = 8'hC6;
        ascii_rom[12'h777] = 8'hD6;
        ascii_rom[12'h778] = 8'hD6;
        ascii_rom[12'h779] = 8'hD6;
        ascii_rom[12'h77A] = 8'hFE;
        ascii_rom[12'h77B] = 8'h6C;
        ascii_rom[12'h77C] = 8'h00;
        ascii_rom[12'h77D] = 8'h00;
        ascii_rom[12'h77E] = 8'h00;
        ascii_rom[12'h77F] = 8'h00;
        // 0x78 x
        ascii_rom[12'h780] = 8'h00;
        ascii_rom[12'h781] = 8'h00;
        ascii_rom[12'h782] = 8'h00;
        ascii_rom[12'h783] = 8'h00;
        ascii_rom[12'h784] = 8'h00;
        ascii_rom[12'h785] = 8'hC6;
        ascii_rom[12'h786] = 8'h6C;
        ascii_rom[12'h787] = 8'h38;
        ascii_rom[12'h788] = 8'h38;
        ascii_rom[12'h789] = 8'h38;
        ascii_rom[12'h78A] = 8'h6C;
        ascii_rom[12'h78B] = 8'hC6;
        ascii_rom[12'h78C] = 8'h00;
        ascii_rom[12'h78D] = 8'h00;
        ascii_rom[12'h78E] = 8'h00;
        ascii_rom[12'h78F] = 8'h00;
        // 0x79 y
        ascii_rom[12'h790] = 8'h00;
        ascii_rom[12'h791] = 8'h00;
        ascii_rom[12'h792] = 8'h00;
        ascii_rom[12'h793] = 8'h00;
        ascii_rom[12'h794] = 8'h00;
        ascii_rom[12'h795] = 8'hC6;
        ascii_rom[12'h796] = 8'hC6;
        ascii_rom[12'h797] = 8'hC6;
        ascii_rom[12'h798] = 8'hC6;
        ascii_rom[12'h799] = 8'hC6;
        ascii_rom[12'h79A] = 8'hC6;
        ascii_rom[12'h79B] = 8'h7E;
        ascii_rom[12'h79C] = 8'h06;
        ascii_rom[12'h79D] = 8'h0C;
        ascii_rom[12'h79E] = 8'hF8;
        ascii_rom[12'h79F] = 8'h00;
        // 0x7A z
        ascii_rom[12'h7A0] = 8'h00;
        ascii_rom[12'h7A1] = 8'h00;
        ascii_rom[12'h7A2] = 8'h00;
        ascii_rom[12'h7A3] = 8'h00;
        ascii_rom[12'h7A4] = 8'h00;
        ascii_rom[12'h7A5] = 8'hFE;
        ascii_rom[12'h7A6] = 8'hCC;
        ascii_rom[12'h7A7] = 8'h18;
        ascii_rom[12'h7A8] = 8'h30;
        ascii_rom[12'h7A9] = 8'h60;
        ascii_rom[12'h7AA] = 8'hC6;
        ascii_rom[12'h7AB] = 8'hFE;
        ascii_rom[12'h7AC] = 8'h00;
        ascii_rom[12'h7AD] = 8'h00;
        ascii_rom[12'h7AE] = 8'h00;
        ascii_rom[12'h7AF] = 8'h00;
        // 0x7B {
        ascii_rom[12'h7B0] = 8'h00;
        ascii_rom[12'h7B1] = 8'h00;
        ascii_rom[12'h7B2] = 8'h0E;
        ascii_rom[12'h7B3] = 8'h18;
        ascii_rom[12'h7B4] = 8'h18;
        ascii_rom[12'h7B5] = 8'h18;
        ascii_rom[12'h7B6] = 8'h70;
        ascii_rom[12'h7B7] = 8'h18;
        ascii_rom[12'h7B8] = 8'h18;
        ascii_rom[12'h7B9] = 8'h18;
        ascii_rom[12'h7BA] = 8'h18;
        ascii_rom[12'h7BB] = 8'h0E;
        ascii_rom[12'h7BC] = 8'h00;
        ascii_rom[12'h7BD] = 8'h00;
        ascii_rom[12'h7BE] = 8'h00;
        ascii_rom[12'h7BF] = 8'h00;
        // 0x7C |
        ascii_rom[12'h7C0] = 8'h00;
        ascii_rom[12'h7C1] = 8'h00;
        ascii_rom[12'h7C2] = 8'h18;
        ascii_rom[12'h7C3] = 8'h18;
        ascii_rom[12'h7C4] = 8'h18;
        ascii_rom[12'h7C5] = 8'h18;
        ascii_rom[12'h7C6] = 8'h18;
        ascii_rom[12'h7C7] = 8'h18;
        ascii_rom[12'h7C8] = 8'h18;
        ascii_rom[12'h7C9] = 8'h18;
        ascii_rom[12'h7CA] = 8'h18;
        ascii_rom[12'h7CB] = 8'h18;
        ascii_rom[12'h7CC] = 8'h00;
        ascii_rom[12'h7CD] = 8'h00;
        ascii_rom[12'h7CE] = 8'h00;
        ascii_rom[12'h7CF] = 8'h00;
        // 0x7D }
        ascii_rom[12'h7D0] = 8'h00;
        ascii_rom[12'h7D1] = 8'h00;
        ascii_rom[12'h7D2] = 8'h70;
        ascii_rom[12'h7D3] = 8'h18;
        ascii_rom[12'h7D4] = 8'h18;
        ascii_rom[12'h7D5] = 8'h18;
        ascii_rom[12'h7D6] = 8'h0E;
        ascii_rom[12'h7D7] = 8'h18;
        ascii_rom[12'h7D8] = 8'h18;
        ascii_rom[12'h7D9] = 8'h18;
        ascii_rom[12'h7DA] = 8'h18;
        ascii_rom[12'h7DB] = 8'h70;
        ascii_rom[12'h7DC] = 8'h00;
        ascii_rom[12'h7DD] = 8'h00;
        ascii_rom[12'h7DE] = 8'h00;
        ascii_rom[12'h7DF] = 8'h00;
        // 0x7E ~
        ascii_rom[12'h7E0] = 8'h00;
        ascii_rom[12'h7E1] = 8'h76;
        ascii_rom[12'h7E2] = 8'hDC;
        ascii_rom[12'h7E3] = 8'h00;
        ascii_rom[12'h7E4] = 8'h00;
        ascii_rom[12'h7E5] = 8'h00;
        ascii_rom[12'h7E6] = 8'h00;
        ascii_rom[12'h7E7] = 8'h00;
        ascii_rom[12'h7E8] = 8'h00;
        ascii_rom[12'h7E9] = 8'h00;
        ascii_rom[12'h7EA] = 8'h00;
        ascii_rom[12'h7EB] = 8'h00;
        ascii_rom[12'h7EC] = 8'h00;
        ascii_rom[12'h7ED] = 8'h00;
        ascii_rom[12'h7EE] = 8'h00;
        ascii_rom[12'h7EF] = 8'h00;
        // 0x7F -
        ascii_rom[12'h7F0] = 8'h00;
        ascii_rom[12'h7F1] = 8'h00;
        ascii_rom[12'h7F2] = 8'h00;
        ascii_rom[12'h7F3] = 8'h00;
        ascii_rom[12'h7F4] = 8'h00;
        ascii_rom[12'h7F5] = 8'h00;
        ascii_rom[12'h7F6] = 8'h00;
        ascii_rom[12'h7F7] = 8'h00;
        ascii_rom[12'h7F8] = 8'h00;
        ascii_rom[12'h7F9] = 8'h00;
        ascii_rom[12'h7FA] = 8'h00;
        ascii_rom[12'h7FB] = 8'h00;
        ascii_rom[12'h7FC] = 8'h00;
        ascii_rom[12'h7FD] = 8'h00;
        ascii_rom[12'h7FE] = 8'h00;
        ascii_rom[12'h7FF] = 8'h00;
        // 0x80 -
        ascii_rom[12'h800] = 8'h00;
        ascii_rom[12'h801] = 8'h00;
        ascii_rom[12'h802] = 8'h00;
        ascii_rom[12'h803] = 8'h00;
        ascii_rom[12'h804] = 8'h00;
        ascii_rom[12'h805] = 8'h00;
        ascii_rom[12'h806] = 8'h00;
        ascii_rom[12'h807] = 8'h00;
        ascii_rom[12'h808] = 8'h00;
        ascii_rom[12'h809] = 8'h00;
        ascii_rom[12'h80A] = 8'h00;
        ascii_rom[12'h80B] = 8'h00;
        ascii_rom[12'h80C] = 8'h00;
        ascii_rom[12'h80D] = 8'h00;
        ascii_rom[12'h80E] = 8'h00;
        ascii_rom[12'h80F] = 8'h00;
        // 0x81 -
        ascii_rom[12'h810] = 8'h00;
        ascii_rom[12'h811] = 8'h00;
        ascii_rom[12'h812] = 8'h00;
        ascii_rom[12'h813] = 8'h00;
        ascii_rom[12'h814] = 8'h00;
        ascii_rom[12'h815] = 8'h00;
        ascii_rom[12'h816] = 8'h00;
        ascii_rom[12'h817] = 8'h00;
        ascii_rom[12'h818] = 8'h00;
        ascii_rom[12'h819] = 8'h00;
        ascii_rom[12'h81A] = 8'h00;
        ascii_rom[12'h81B] = 8'h00;
        ascii_rom[12'h81C] = 8'h00;
        ascii_rom[12'h81D] = 8'h00;
        ascii_rom[12'h81E] = 8'h00;
        ascii_rom[12'h81F] = 8'h00;
        // 0x82 -
        ascii_rom[12'h820] = 8'h00;
        ascii_rom[12'h821] = 8'h00;
        ascii_rom[12'h822] = 8'h00;
        ascii_rom[12'h823] = 8'h00;
        ascii_rom[12'h824] = 8'h00;
        ascii_rom[12'h825] = 8'h00;
        ascii_rom[12'h826] = 8'h00;
        ascii_rom[12'h827] = 8'h00;
        ascii_rom[12'h828] = 8'h00;
        ascii_rom[12'h829] = 8'h00;
        ascii_rom[12'h82A] = 8'h00;
        ascii_rom[12'h82B] = 8'h00;
        ascii_rom[12'h82C] = 8'h00;
        ascii_rom[12'h82D] = 8'h00;
        ascii_rom[12'h82E] = 8'h00;
        ascii_rom[12'h82F] = 8'h00;
        // 0x83 -
        ascii_rom[12'h830] = 8'h00;
        ascii_rom[12'h831] = 8'h00;
        ascii_rom[12'h832] = 8'h00;
        ascii_rom[12'h833] = 8'h00;
        ascii_rom[12'h834] = 8'h00;
        ascii_rom[12'h835] = 8'h00;
        ascii_rom[12'h836] = 8'h00;
        ascii_rom[12'h837] = 8'h00;
        ascii_rom[12'h838] = 8'h00;
        ascii_rom[12'h839] = 8'h00;
        ascii_rom[12'h83A] = 8'h00;
        ascii_rom[12'h83B] = 8'h00;
        ascii_rom[12'h83C] = 8'h00;
        ascii_rom[12'h83D] = 8'h00;
        ascii_rom[12'h83E] = 8'h00;
        ascii_rom[12'h83F] = 8'h00;
        // 0x84 -
        ascii_rom[12'h840] = 8'h00;
        ascii_rom[12'h841] = 8'h00;
        ascii_rom[12'h842] = 8'h00;
        ascii_rom[12'h843] = 8'h00;
        ascii_rom[12'h844] = 8'h00;
        ascii_rom[12'h845] = 8'h00;
        ascii_rom[12'h846] = 8'h00;
        ascii_rom[12'h847] = 8'h00;
        ascii_rom[12'h848] = 8'h00;
        ascii_rom[12'h849] = 8'h00;
        ascii_rom[12'h84A] = 8'h00;
        ascii_rom[12'h84B] = 8'h00;
        ascii_rom[12'h84C] = 8'h00;
        ascii_rom[12'h84D] = 8'h00;
        ascii_rom[12'h84E] = 8'h00;
        ascii_rom[12'h84F] = 8'h00;
        // 0x85 -
        ascii_rom[12'h850] = 8'h00;
        ascii_rom[12'h851] = 8'h00;
        ascii_rom[12'h852] = 8'h00;
        ascii_rom[12'h853] = 8'h00;
        ascii_rom[12'h854] = 8'h00;
        ascii_rom[12'h855] = 8'h00;
        ascii_rom[12'h856] = 8'h00;
        ascii_rom[12'h857] = 8'h00;
        ascii_rom[12'h858] = 8'h00;
        ascii_rom[12'h859] = 8'h00;
        ascii_rom[12'h85A] = 8'h00;
        ascii_rom[12'h85B] = 8'h00;
        ascii_rom[12'h85C] = 8'h00;
        ascii_rom[12'h85D] = 8'h00;
        ascii_rom[12'h85E] = 8'h00;
        ascii_rom[12'h85F] = 8'h00;
        // 0x86 -
        ascii_rom[12'h860] = 8'h00;
        ascii_rom[12'h861] = 8'h00;
        ascii_rom[12'h862] = 8'h00;
        ascii_rom[12'h863] = 8'h00;
        ascii_rom[12'h864] = 8'h00;
        ascii_rom[12'h865] = 8'h00;
        ascii_rom[12'h866] = 8'h00;
        ascii_rom[12'h867] = 8'h00;
        ascii_rom[12'h868] = 8'h00;
        ascii_rom[12'h869] = 8'h00;
        ascii_rom[12'h86A] = 8'h00;
        ascii_rom[12'h86B] = 8'h00;
        ascii_rom[12'h86C] = 8'h00;
        ascii_rom[12'h86D] = 8'h00;
        ascii_rom[12'h86E] = 8'h00;
        ascii_rom[12'h86F] = 8'h00;
        // 0x87 -
        ascii_rom[12'h870] = 8'h00;
        ascii_rom[12'h871] = 8'h00;
        ascii_rom[12'h872] = 8'h00;
        ascii_rom[12'h873] = 8'h00;
        ascii_rom[12'h874] = 8'h00;
        ascii_rom[12'h875] = 8'h00;
        ascii_rom[12'h876] = 8'h00;
        ascii_rom[12'h877] = 8'h00;
        ascii_rom[12'h878] = 8'h00;
        ascii_rom[12'h879] = 8'h00;
        ascii_rom[12'h87A] = 8'h00;
        ascii_rom[12'h87B] = 8'h00;
        ascii_rom[12'h87C] = 8'h00;
        ascii_rom[12'h87D] = 8'h00;
        ascii_rom[12'h87E] = 8'h00;
        ascii_rom[12'h87F] = 8'h00;
        // 0x88 -
        ascii_rom[12'h880] = 8'h00;
        ascii_rom[12'h881] = 8'h00;
        ascii_rom[12'h882] = 8'h00;
        ascii_rom[12'h883] = 8'h00;
        ascii_rom[12'h884] = 8'h00;
        ascii_rom[12'h885] = 8'h00;
        ascii_rom[12'h886] = 8'h00;
        ascii_rom[12'h887] = 8'h00;
        ascii_rom[12'h888] = 8'h00;
        ascii_rom[12'h889] = 8'h00;
        ascii_rom[12'h88A] = 8'h00;
        ascii_rom[12'h88B] = 8'h00;
        ascii_rom[12'h88C] = 8'h00;
        ascii_rom[12'h88D] = 8'h00;
        ascii_rom[12'h88E] = 8'h00;
        ascii_rom[12'h88F] = 8'h00;
        // 0x89 -
        ascii_rom[12'h890] = 8'h00;
        ascii_rom[12'h891] = 8'h00;
        ascii_rom[12'h892] = 8'h00;
        ascii_rom[12'h893] = 8'h00;
        ascii_rom[12'h894] = 8'h00;
        ascii_rom[12'h895] = 8'h00;
        ascii_rom[12'h896] = 8'h00;
        ascii_rom[12'h897] = 8'h00;
        ascii_rom[12'h898] = 8'h00;
        ascii_rom[12'h899] = 8'h00;
        ascii_rom[12'h89A] = 8'h00;
        ascii_rom[12'h89B] = 8'h00;
        ascii_rom[12'h89C] = 8'h00;
        ascii_rom[12'h89D] = 8'h00;
        ascii_rom[12'h89E] = 8'h00;
        ascii_rom[12'h89F] = 8'h00;
        // 0x8A -
        ascii_rom[12'h8A0] = 8'h00;
        ascii_rom[12'h8A1] = 8'h00;
        ascii_rom[12'h8A2] = 8'h00;
        ascii_rom[12'h8A3] = 8'h00;
        ascii_rom[12'h8A4] = 8'h00;
        ascii_rom[12'h8A5] = 8'h00;
        ascii_rom[12'h8A6] = 8'h00;
        ascii_rom[12'h8A7] = 8'h00;
        ascii_rom[12'h8A8] = 8'h00;
        ascii_rom[12'h8A9] = 8'h00;
        ascii_rom[12'h8AA] = 8'h00;
        ascii_rom[12'h8AB] = 8'h00;
        ascii_rom[12'h8AC] = 8'h00;
        ascii_rom[12'h8AD] = 8'h00;
        ascii_rom[12'h8AE] = 8'h00;
        ascii_rom[12'h8AF] = 8'h00;
        // 0x8B -
        ascii_rom[12'h8B0] = 8'h00;
        ascii_rom[12'h8B1] = 8'h00;
        ascii_rom[12'h8B2] = 8'h00;
        ascii_rom[12'h8B3] = 8'h00;
        ascii_rom[12'h8B4] = 8'h00;
        ascii_rom[12'h8B5] = 8'h00;
        ascii_rom[12'h8B6] = 8'h00;
        ascii_rom[12'h8B7] = 8'h00;
        ascii_rom[12'h8B8] = 8'h00;
        ascii_rom[12'h8B9] = 8'h00;
        ascii_rom[12'h8BA] = 8'h00;
        ascii_rom[12'h8BB] = 8'h00;
        ascii_rom[12'h8BC] = 8'h00;
        ascii_rom[12'h8BD] = 8'h00;
        ascii_rom[12'h8BE] = 8'h00;
        ascii_rom[12'h8BF] = 8'h00;
        // 0x8C -
        ascii_rom[12'h8C0] = 8'h00;
        ascii_rom[12'h8C1] = 8'h00;
        ascii_rom[12'h8C2] = 8'h00;
        ascii_rom[12'h8C3] = 8'h00;
        ascii_rom[12'h8C4] = 8'h00;
        ascii_rom[12'h8C5] = 8'h00;
        ascii_rom[12'h8C6] = 8'h00;
        ascii_rom[12'h8C7] = 8'h00;
        ascii_rom[12'h8C8] = 8'h00;
        ascii_rom[12'h8C9] = 8'h00;
        ascii_rom[12'h8CA] = 8'h00;
        ascii_rom[12'h8CB] = 8'h00;
        ascii_rom[12'h8CC] = 8'h00;
        ascii_rom[12'h8CD] = 8'h00;
        ascii_rom[12'h8CE] = 8'h00;
        ascii_rom[12'h8CF] = 8'h00;
        // 0x8D -
        ascii_rom[12'h8D0] = 8'h00;
        ascii_rom[12'h8D1] = 8'h00;
        ascii_rom[12'h8D2] = 8'h00;
        ascii_rom[12'h8D3] = 8'h00;
        ascii_rom[12'h8D4] = 8'h00;
        ascii_rom[12'h8D5] = 8'h00;
        ascii_rom[12'h8D6] = 8'h00;
        ascii_rom[12'h8D7] = 8'h00;
        ascii_rom[12'h8D8] = 8'h00;
        ascii_rom[12'h8D9] = 8'h00;
        ascii_rom[12'h8DA] = 8'h00;
        ascii_rom[12'h8DB] = 8'h00;
        ascii_rom[12'h8DC] = 8'h00;
        ascii_rom[12'h8DD] = 8'h00;
        ascii_rom[12'h8DE] = 8'h00;
        ascii_rom[12'h8DF] = 8'h00;
        // 0x8E -
        ascii_rom[12'h8E0] = 8'h00;
        ascii_rom[12'h8E1] = 8'h00;
        ascii_rom[12'h8E2] = 8'h00;
        ascii_rom[12'h8E3] = 8'h00;
        ascii_rom[12'h8E4] = 8'h00;
        ascii_rom[12'h8E5] = 8'h00;
        ascii_rom[12'h8E6] = 8'h00;
        ascii_rom[12'h8E7] = 8'h00;
        ascii_rom[12'h8E8] = 8'h00;
        ascii_rom[12'h8E9] = 8'h00;
        ascii_rom[12'h8EA] = 8'h00;
        ascii_rom[12'h8EB] = 8'h00;
        ascii_rom[12'h8EC] = 8'h00;
        ascii_rom[12'h8ED] = 8'h00;
        ascii_rom[12'h8EE] = 8'h00;
        ascii_rom[12'h8EF] = 8'h00;
        // 0x8F -
        ascii_rom[12'h8F0] = 8'h00;
        ascii_rom[12'h8F1] = 8'h00;
        ascii_rom[12'h8F2] = 8'h00;
        ascii_rom[12'h8F3] = 8'h00;
        ascii_rom[12'h8F4] = 8'h00;
        ascii_rom[12'h8F5] = 8'h00;
        ascii_rom[12'h8F6] = 8'h00;
        ascii_rom[12'h8F7] = 8'h00;
        ascii_rom[12'h8F8] = 8'h00;
        ascii_rom[12'h8F9] = 8'h00;
        ascii_rom[12'h8FA] = 8'h00;
        ascii_rom[12'h8FB] = 8'h00;
        ascii_rom[12'h8FC] = 8'h00;
        ascii_rom[12'h8FD] = 8'h00;
        ascii_rom[12'h8FE] = 8'h00;
        ascii_rom[12'h8FF] = 8'h00;
        // 0x90 -
        ascii_rom[12'h900] = 8'h00;
        ascii_rom[12'h901] = 8'h00;
        ascii_rom[12'h902] = 8'h00;
        ascii_rom[12'h903] = 8'h00;
        ascii_rom[12'h904] = 8'h00;
        ascii_rom[12'h905] = 8'h00;
        ascii_rom[12'h906] = 8'h00;
        ascii_rom[12'h907] = 8'h00;
        ascii_rom[12'h908] = 8'h00;
        ascii_rom[12'h909] = 8'h00;
        ascii_rom[12'h90A] = 8'h00;
        ascii_rom[12'h90B] = 8'h00;
        ascii_rom[12'h90C] = 8'h00;
        ascii_rom[12'h90D] = 8'h00;
        ascii_rom[12'h90E] = 8'h00;
        ascii_rom[12'h90F] = 8'h00;
        // 0x91 -
        ascii_rom[12'h910] = 8'h00;
        ascii_rom[12'h911] = 8'h00;
        ascii_rom[12'h912] = 8'h00;
        ascii_rom[12'h913] = 8'h00;
        ascii_rom[12'h914] = 8'h00;
        ascii_rom[12'h915] = 8'h00;
        ascii_rom[12'h916] = 8'h00;
        ascii_rom[12'h917] = 8'h00;
        ascii_rom[12'h918] = 8'h00;
        ascii_rom[12'h919] = 8'h00;
        ascii_rom[12'h91A] = 8'h00;
        ascii_rom[12'h91B] = 8'h00;
        ascii_rom[12'h91C] = 8'h00;
        ascii_rom[12'h91D] = 8'h00;
        ascii_rom[12'h91E] = 8'h00;
        ascii_rom[12'h91F] = 8'h00;
        // 0x92 -
        ascii_rom[12'h920] = 8'h00;
        ascii_rom[12'h921] = 8'h00;
        ascii_rom[12'h922] = 8'h00;
        ascii_rom[12'h923] = 8'h00;
        ascii_rom[12'h924] = 8'h00;
        ascii_rom[12'h925] = 8'h00;
        ascii_rom[12'h926] = 8'h00;
        ascii_rom[12'h927] = 8'h00;
        ascii_rom[12'h928] = 8'h00;
        ascii_rom[12'h929] = 8'h00;
        ascii_rom[12'h92A] = 8'h00;
        ascii_rom[12'h92B] = 8'h00;
        ascii_rom[12'h92C] = 8'h00;
        ascii_rom[12'h92D] = 8'h00;
        ascii_rom[12'h92E] = 8'h00;
        ascii_rom[12'h92F] = 8'h00;
        // 0x93 -
        ascii_rom[12'h930] = 8'h00;
        ascii_rom[12'h931] = 8'h00;
        ascii_rom[12'h932] = 8'h00;
        ascii_rom[12'h933] = 8'h00;
        ascii_rom[12'h934] = 8'h00;
        ascii_rom[12'h935] = 8'h00;
        ascii_rom[12'h936] = 8'h00;
        ascii_rom[12'h937] = 8'h00;
        ascii_rom[12'h938] = 8'h00;
        ascii_rom[12'h939] = 8'h00;
        ascii_rom[12'h93A] = 8'h00;
        ascii_rom[12'h93B] = 8'h00;
        ascii_rom[12'h93C] = 8'h00;
        ascii_rom[12'h93D] = 8'h00;
        ascii_rom[12'h93E] = 8'h00;
        ascii_rom[12'h93F] = 8'h00;
        // 0x94 -
        ascii_rom[12'h940] = 8'h00;
        ascii_rom[12'h941] = 8'h00;
        ascii_rom[12'h942] = 8'h00;
        ascii_rom[12'h943] = 8'h00;
        ascii_rom[12'h944] = 8'h00;
        ascii_rom[12'h945] = 8'h00;
        ascii_rom[12'h946] = 8'h00;
        ascii_rom[12'h947] = 8'h00;
        ascii_rom[12'h948] = 8'h00;
        ascii_rom[12'h949] = 8'h00;
        ascii_rom[12'h94A] = 8'h00;
        ascii_rom[12'h94B] = 8'h00;
        ascii_rom[12'h94C] = 8'h00;
        ascii_rom[12'h94D] = 8'h00;
        ascii_rom[12'h94E] = 8'h00;
        ascii_rom[12'h94F] = 8'h00;
        // 0x95 -
        ascii_rom[12'h950] = 8'h00;
        ascii_rom[12'h951] = 8'h00;
        ascii_rom[12'h952] = 8'h00;
        ascii_rom[12'h953] = 8'h00;
        ascii_rom[12'h954] = 8'h00;
        ascii_rom[12'h955] = 8'h00;
        ascii_rom[12'h956] = 8'h00;
        ascii_rom[12'h957] = 8'h00;
        ascii_rom[12'h958] = 8'h00;
        ascii_rom[12'h959] = 8'h00;
        ascii_rom[12'h95A] = 8'h00;
        ascii_rom[12'h95B] = 8'h00;
        ascii_rom[12'h95C] = 8'h00;
        ascii_rom[12'h95D] = 8'h00;
        ascii_rom[12'h95E] = 8'h00;
        ascii_rom[12'h95F] = 8'h00;
        // 0x96 -
        ascii_rom[12'h960] = 8'h00;
        ascii_rom[12'h961] = 8'h00;
        ascii_rom[12'h962] = 8'h00;
        ascii_rom[12'h963] = 8'h00;
        ascii_rom[12'h964] = 8'h00;
        ascii_rom[12'h965] = 8'h00;
        ascii_rom[12'h966] = 8'h00;
        ascii_rom[12'h967] = 8'h00;
        ascii_rom[12'h968] = 8'h00;
        ascii_rom[12'h969] = 8'h00;
        ascii_rom[12'h96A] = 8'h00;
        ascii_rom[12'h96B] = 8'h00;
        ascii_rom[12'h96C] = 8'h00;
        ascii_rom[12'h96D] = 8'h00;
        ascii_rom[12'h96E] = 8'h00;
        ascii_rom[12'h96F] = 8'h00;
        // 0x97 -
        ascii_rom[12'h970] = 8'h00;
        ascii_rom[12'h971] = 8'h00;
        ascii_rom[12'h972] = 8'h00;
        ascii_rom[12'h973] = 8'h00;
        ascii_rom[12'h974] = 8'h00;
        ascii_rom[12'h975] = 8'h00;
        ascii_rom[12'h976] = 8'h00;
        ascii_rom[12'h977] = 8'h00;
        ascii_rom[12'h978] = 8'h00;
        ascii_rom[12'h979] = 8'h00;
        ascii_rom[12'h97A] = 8'h00;
        ascii_rom[12'h97B] = 8'h00;
        ascii_rom[12'h97C] = 8'h00;
        ascii_rom[12'h97D] = 8'h00;
        ascii_rom[12'h97E] = 8'h00;
        ascii_rom[12'h97F] = 8'h00;
        // 0x98 -
        ascii_rom[12'h980] = 8'h00;
        ascii_rom[12'h981] = 8'h00;
        ascii_rom[12'h982] = 8'h00;
        ascii_rom[12'h983] = 8'h00;
        ascii_rom[12'h984] = 8'h00;
        ascii_rom[12'h985] = 8'h00;
        ascii_rom[12'h986] = 8'h00;
        ascii_rom[12'h987] = 8'h00;
        ascii_rom[12'h988] = 8'h00;
        ascii_rom[12'h989] = 8'h00;
        ascii_rom[12'h98A] = 8'h00;
        ascii_rom[12'h98B] = 8'h00;
        ascii_rom[12'h98C] = 8'h00;
        ascii_rom[12'h98D] = 8'h00;
        ascii_rom[12'h98E] = 8'h00;
        ascii_rom[12'h98F] = 8'h00;
        // 0x99 -
        ascii_rom[12'h990] = 8'h00;
        ascii_rom[12'h991] = 8'h00;
        ascii_rom[12'h992] = 8'h00;
        ascii_rom[12'h993] = 8'h00;
        ascii_rom[12'h994] = 8'h00;
        ascii_rom[12'h995] = 8'h00;
        ascii_rom[12'h996] = 8'h00;
        ascii_rom[12'h997] = 8'h00;
        ascii_rom[12'h998] = 8'h00;
        ascii_rom[12'h999] = 8'h00;
        ascii_rom[12'h99A] = 8'h00;
        ascii_rom[12'h99B] = 8'h00;
        ascii_rom[12'h99C] = 8'h00;
        ascii_rom[12'h99D] = 8'h00;
        ascii_rom[12'h99E] = 8'h00;
        ascii_rom[12'h99F] = 8'h00;
        // 0x9A -
        ascii_rom[12'h9A0] = 8'h00;
        ascii_rom[12'h9A1] = 8'h00;
        ascii_rom[12'h9A2] = 8'h00;
        ascii_rom[12'h9A3] = 8'h00;
        ascii_rom[12'h9A4] = 8'h00;
        ascii_rom[12'h9A5] = 8'h00;
        ascii_rom[12'h9A6] = 8'h00;
        ascii_rom[12'h9A7] = 8'h00;
        ascii_rom[12'h9A8] = 8'h00;
        ascii_rom[12'h9A9] = 8'h00;
        ascii_rom[12'h9AA] = 8'h00;
        ascii_rom[12'h9AB] = 8'h00;
        ascii_rom[12'h9AC] = 8'h00;
        ascii_rom[12'h9AD] = 8'h00;
        ascii_rom[12'h9AE] = 8'h00;
        ascii_rom[12'h9AF] = 8'h00;
        // 0x9B -
        ascii_rom[12'h9B0] = 8'h00;
        ascii_rom[12'h9B1] = 8'h00;
        ascii_rom[12'h9B2] = 8'h00;
        ascii_rom[12'h9B3] = 8'h00;
        ascii_rom[12'h9B4] = 8'h00;
        ascii_rom[12'h9B5] = 8'h00;
        ascii_rom[12'h9B6] = 8'h00;
        ascii_rom[12'h9B7] = 8'h00;
        ascii_rom[12'h9B8] = 8'h00;
        ascii_rom[12'h9B9] = 8'h00;
        ascii_rom[12'h9BA] = 8'h00;
        ascii_rom[12'h9BB] = 8'h00;
        ascii_rom[12'h9BC] = 8'h00;
        ascii_rom[12'h9BD] = 8'h00;
        ascii_rom[12'h9BE] = 8'h00;
        ascii_rom[12'h9BF] = 8'h00;
        // 0x9C -
        ascii_rom[12'h9C0] = 8'h00;
        ascii_rom[12'h9C1] = 8'h00;
        ascii_rom[12'h9C2] = 8'h00;
        ascii_rom[12'h9C3] = 8'h00;
        ascii_rom[12'h9C4] = 8'h00;
        ascii_rom[12'h9C5] = 8'h00;
        ascii_rom[12'h9C6] = 8'h00;
        ascii_rom[12'h9C7] = 8'h00;
        ascii_rom[12'h9C8] = 8'h00;
        ascii_rom[12'h9C9] = 8'h00;
        ascii_rom[12'h9CA] = 8'h00;
        ascii_rom[12'h9CB] = 8'h00;
        ascii_rom[12'h9CC] = 8'h00;
        ascii_rom[12'h9CD] = 8'h00;
        ascii_rom[12'h9CE] = 8'h00;
        ascii_rom[12'h9CF] = 8'h00;
        // 0x9D -
        ascii_rom[12'h9D0] = 8'h00;
        ascii_rom[12'h9D1] = 8'h00;
        ascii_rom[12'h9D2] = 8'h00;
        ascii_rom[12'h9D3] = 8'h00;
        ascii_rom[12'h9D4] = 8'h00;
        ascii_rom[12'h9D5] = 8'h00;
        ascii_rom[12'h9D6] = 8'h00;
        ascii_rom[12'h9D7] = 8'h00;
        ascii_rom[12'h9D8] = 8'h00;
        ascii_rom[12'h9D9] = 8'h00;
        ascii_rom[12'h9DA] = 8'h00;
        ascii_rom[12'h9DB] = 8'h00;
        ascii_rom[12'h9DC] = 8'h00;
        ascii_rom[12'h9DD] = 8'h00;
        ascii_rom[12'h9DE] = 8'h00;
        ascii_rom[12'h9DF] = 8'h00;
        // 0x9E -
        ascii_rom[12'h9E0] = 8'h00;
        ascii_rom[12'h9E1] = 8'h00;
        ascii_rom[12'h9E2] = 8'h00;
        ascii_rom[12'h9E3] = 8'h00;
        ascii_rom[12'h9E4] = 8'h00;
        ascii_rom[12'h9E5] = 8'h00;
        ascii_rom[12'h9E6] = 8'h00;
        ascii_rom[12'h9E7] = 8'h00;
        ascii_rom[12'h9E8] = 8'h00;
        ascii_rom[12'h9E9] = 8'h00;
        ascii_rom[12'h9EA] = 8'h00;
        ascii_rom[12'h9EB] = 8'h00;
        ascii_rom[12'h9EC] = 8'h00;
        ascii_rom[12'h9ED] = 8'h00;
        ascii_rom[12'h9EE] = 8'h00;
        ascii_rom[12'h9EF] = 8'h00;
        // 0x9F -
        ascii_rom[12'h9F0] = 8'h00;
        ascii_rom[12'h9F1] = 8'h00;
        ascii_rom[12'h9F2] = 8'h00;
        ascii_rom[12'h9F3] = 8'h00;
        ascii_rom[12'h9F4] = 8'h00;
        ascii_rom[12'h9F5] = 8'h00;
        ascii_rom[12'h9F6] = 8'h00;
        ascii_rom[12'h9F7] = 8'h00;
        ascii_rom[12'h9F8] = 8'h00;
        ascii_rom[12'h9F9] = 8'h00;
        ascii_rom[12'h9FA] = 8'h00;
        ascii_rom[12'h9FB] = 8'h00;
        ascii_rom[12'h9FC] = 8'h00;
        ascii_rom[12'h9FD] = 8'h00;
        ascii_rom[12'h9FE] = 8'h00;
        ascii_rom[12'h9FF] = 8'h00;
        // 0xA0 -
        ascii_rom[12'hA00] = 8'h00;
        ascii_rom[12'hA01] = 8'h00;
        ascii_rom[12'hA02] = 8'h00;
        ascii_rom[12'hA03] = 8'h00;
        ascii_rom[12'hA04] = 8'h00;
        ascii_rom[12'hA05] = 8'h00;
        ascii_rom[12'hA06] = 8'h00;
        ascii_rom[12'hA07] = 8'h00;
        ascii_rom[12'hA08] = 8'h00;
        ascii_rom[12'hA09] = 8'h00;
        ascii_rom[12'hA0A] = 8'h00;
        ascii_rom[12'hA0B] = 8'h00;
        ascii_rom[12'hA0C] = 8'h00;
        ascii_rom[12'hA0D] = 8'h00;
        ascii_rom[12'hA0E] = 8'h00;
        ascii_rom[12'hA0F] = 8'h00;
        // 0xA1 -
        ascii_rom[12'hA10] = 8'h00;
        ascii_rom[12'hA11] = 8'h00;
        ascii_rom[12'hA12] = 8'h00;
        ascii_rom[12'hA13] = 8'h00;
        ascii_rom[12'hA14] = 8'h00;
        ascii_rom[12'hA15] = 8'h00;
        ascii_rom[12'hA16] = 8'h00;
        ascii_rom[12'hA17] = 8'h00;
        ascii_rom[12'hA18] = 8'h00;
        ascii_rom[12'hA19] = 8'h00;
        ascii_rom[12'hA1A] = 8'h00;
        ascii_rom[12'hA1B] = 8'h00;
        ascii_rom[12'hA1C] = 8'h00;
        ascii_rom[12'hA1D] = 8'h00;
        ascii_rom[12'hA1E] = 8'h00;
        ascii_rom[12'hA1F] = 8'h00;
        // 0xA2 -
        ascii_rom[12'hA20] = 8'h00;
        ascii_rom[12'hA21] = 8'h00;
        ascii_rom[12'hA22] = 8'h00;
        ascii_rom[12'hA23] = 8'h00;
        ascii_rom[12'hA24] = 8'h00;
        ascii_rom[12'hA25] = 8'h00;
        ascii_rom[12'hA26] = 8'h00;
        ascii_rom[12'hA27] = 8'h00;
        ascii_rom[12'hA28] = 8'h00;
        ascii_rom[12'hA29] = 8'h00;
        ascii_rom[12'hA2A] = 8'h00;
        ascii_rom[12'hA2B] = 8'h00;
        ascii_rom[12'hA2C] = 8'h00;
        ascii_rom[12'hA2D] = 8'h00;
        ascii_rom[12'hA2E] = 8'h00;
        ascii_rom[12'hA2F] = 8'h00;
        // 0xA3 -
        ascii_rom[12'hA30] = 8'h00;
        ascii_rom[12'hA31] = 8'h00;
        ascii_rom[12'hA32] = 8'h00;
        ascii_rom[12'hA33] = 8'h00;
        ascii_rom[12'hA34] = 8'h00;
        ascii_rom[12'hA35] = 8'h00;
        ascii_rom[12'hA36] = 8'h00;
        ascii_rom[12'hA37] = 8'h00;
        ascii_rom[12'hA38] = 8'h00;
        ascii_rom[12'hA39] = 8'h00;
        ascii_rom[12'hA3A] = 8'h00;
        ascii_rom[12'hA3B] = 8'h00;
        ascii_rom[12'hA3C] = 8'h00;
        ascii_rom[12'hA3D] = 8'h00;
        ascii_rom[12'hA3E] = 8'h00;
        ascii_rom[12'hA3F] = 8'h00;
        // 0xA4 -
        ascii_rom[12'hA40] = 8'h00;
        ascii_rom[12'hA41] = 8'h00;
        ascii_rom[12'hA42] = 8'h00;
        ascii_rom[12'hA43] = 8'h00;
        ascii_rom[12'hA44] = 8'h00;
        ascii_rom[12'hA45] = 8'h00;
        ascii_rom[12'hA46] = 8'h00;
        ascii_rom[12'hA47] = 8'h00;
        ascii_rom[12'hA48] = 8'h00;
        ascii_rom[12'hA49] = 8'h00;
        ascii_rom[12'hA4A] = 8'h00;
        ascii_rom[12'hA4B] = 8'h00;
        ascii_rom[12'hA4C] = 8'h00;
        ascii_rom[12'hA4D] = 8'h00;
        ascii_rom[12'hA4E] = 8'h00;
        ascii_rom[12'hA4F] = 8'h00;
        // 0xA5 -
        ascii_rom[12'hA50] = 8'h00;
        ascii_rom[12'hA51] = 8'h00;
        ascii_rom[12'hA52] = 8'h00;
        ascii_rom[12'hA53] = 8'h00;
        ascii_rom[12'hA54] = 8'h00;
        ascii_rom[12'hA55] = 8'h00;
        ascii_rom[12'hA56] = 8'h00;
        ascii_rom[12'hA57] = 8'h00;
        ascii_rom[12'hA58] = 8'h00;
        ascii_rom[12'hA59] = 8'h00;
        ascii_rom[12'hA5A] = 8'h00;
        ascii_rom[12'hA5B] = 8'h00;
        ascii_rom[12'hA5C] = 8'h00;
        ascii_rom[12'hA5D] = 8'h00;
        ascii_rom[12'hA5E] = 8'h00;
        ascii_rom[12'hA5F] = 8'h00;
        // 0xA6 -
        ascii_rom[12'hA60] = 8'h00;
        ascii_rom[12'hA61] = 8'h00;
        ascii_rom[12'hA62] = 8'h00;
        ascii_rom[12'hA63] = 8'h00;
        ascii_rom[12'hA64] = 8'h00;
        ascii_rom[12'hA65] = 8'h00;
        ascii_rom[12'hA66] = 8'h00;
        ascii_rom[12'hA67] = 8'h00;
        ascii_rom[12'hA68] = 8'h00;
        ascii_rom[12'hA69] = 8'h00;
        ascii_rom[12'hA6A] = 8'h00;
        ascii_rom[12'hA6B] = 8'h00;
        ascii_rom[12'hA6C] = 8'h00;
        ascii_rom[12'hA6D] = 8'h00;
        ascii_rom[12'hA6E] = 8'h00;
        ascii_rom[12'hA6F] = 8'h00;
        // 0xA7 -
        ascii_rom[12'hA70] = 8'h00;
        ascii_rom[12'hA71] = 8'h00;
        ascii_rom[12'hA72] = 8'h00;
        ascii_rom[12'hA73] = 8'h00;
        ascii_rom[12'hA74] = 8'h00;
        ascii_rom[12'hA75] = 8'h00;
        ascii_rom[12'hA76] = 8'h00;
        ascii_rom[12'hA77] = 8'h00;
        ascii_rom[12'hA78] = 8'h00;
        ascii_rom[12'hA79] = 8'h00;
        ascii_rom[12'hA7A] = 8'h00;
        ascii_rom[12'hA7B] = 8'h00;
        ascii_rom[12'hA7C] = 8'h00;
        ascii_rom[12'hA7D] = 8'h00;
        ascii_rom[12'hA7E] = 8'h00;
        ascii_rom[12'hA7F] = 8'h00;
        // 0xA8 -
        ascii_rom[12'hA80] = 8'h00;
        ascii_rom[12'hA81] = 8'h00;
        ascii_rom[12'hA82] = 8'h00;
        ascii_rom[12'hA83] = 8'h00;
        ascii_rom[12'hA84] = 8'h00;
        ascii_rom[12'hA85] = 8'h00;
        ascii_rom[12'hA86] = 8'h00;
        ascii_rom[12'hA87] = 8'h00;
        ascii_rom[12'hA88] = 8'h00;
        ascii_rom[12'hA89] = 8'h00;
        ascii_rom[12'hA8A] = 8'h00;
        ascii_rom[12'hA8B] = 8'h00;
        ascii_rom[12'hA8C] = 8'h00;
        ascii_rom[12'hA8D] = 8'h00;
        ascii_rom[12'hA8E] = 8'h00;
        ascii_rom[12'hA8F] = 8'h00;
        // 0xA9 -
        ascii_rom[12'hA90] = 8'h00;
        ascii_rom[12'hA91] = 8'h00;
        ascii_rom[12'hA92] = 8'h00;
        ascii_rom[12'hA93] = 8'h00;
        ascii_rom[12'hA94] = 8'h00;
        ascii_rom[12'hA95] = 8'h00;
        ascii_rom[12'hA96] = 8'h00;
        ascii_rom[12'hA97] = 8'h00;
        ascii_rom[12'hA98] = 8'h00;
        ascii_rom[12'hA99] = 8'h00;
        ascii_rom[12'hA9A] = 8'h00;
        ascii_rom[12'hA9B] = 8'h00;
        ascii_rom[12'hA9C] = 8'h00;
        ascii_rom[12'hA9D] = 8'h00;
        ascii_rom[12'hA9E] = 8'h00;
        ascii_rom[12'hA9F] = 8'h00;
        // 0xAA -
        ascii_rom[12'hAA0] = 8'h00;
        ascii_rom[12'hAA1] = 8'h00;
        ascii_rom[12'hAA2] = 8'h00;
        ascii_rom[12'hAA3] = 8'h00;
        ascii_rom[12'hAA4] = 8'h00;
        ascii_rom[12'hAA5] = 8'h00;
        ascii_rom[12'hAA6] = 8'h00;
        ascii_rom[12'hAA7] = 8'h00;
        ascii_rom[12'hAA8] = 8'h00;
        ascii_rom[12'hAA9] = 8'h00;
        ascii_rom[12'hAAA] = 8'h00;
        ascii_rom[12'hAAB] = 8'h00;
        ascii_rom[12'hAAC] = 8'h00;
        ascii_rom[12'hAAD] = 8'h00;
        ascii_rom[12'hAAE] = 8'h00;
        ascii_rom[12'hAAF] = 8'h00;
        // 0xAB -
        ascii_rom[12'hAB0] = 8'h00;
        ascii_rom[12'hAB1] = 8'h00;
        ascii_rom[12'hAB2] = 8'h00;
        ascii_rom[12'hAB3] = 8'h00;
        ascii_rom[12'hAB4] = 8'h00;
        ascii_rom[12'hAB5] = 8'h00;
        ascii_rom[12'hAB6] = 8'h00;
        ascii_rom[12'hAB7] = 8'h00;
        ascii_rom[12'hAB8] = 8'h00;
        ascii_rom[12'hAB9] = 8'h00;
        ascii_rom[12'hABA] = 8'h00;
        ascii_rom[12'hABB] = 8'h00;
        ascii_rom[12'hABC] = 8'h00;
        ascii_rom[12'hABD] = 8'h00;
        ascii_rom[12'hABE] = 8'h00;
        ascii_rom[12'hABF] = 8'h00;
        // 0xAC -
        ascii_rom[12'hAC0] = 8'h00;
        ascii_rom[12'hAC1] = 8'h00;
        ascii_rom[12'hAC2] = 8'h00;
        ascii_rom[12'hAC3] = 8'h00;
        ascii_rom[12'hAC4] = 8'h00;
        ascii_rom[12'hAC5] = 8'h00;
        ascii_rom[12'hAC6] = 8'h00;
        ascii_rom[12'hAC7] = 8'h00;
        ascii_rom[12'hAC8] = 8'h00;
        ascii_rom[12'hAC9] = 8'h00;
        ascii_rom[12'hACA] = 8'h00;
        ascii_rom[12'hACB] = 8'h00;
        ascii_rom[12'hACC] = 8'h00;
        ascii_rom[12'hACD] = 8'h00;
        ascii_rom[12'hACE] = 8'h00;
        ascii_rom[12'hACF] = 8'h00;
        // 0xAD -
        ascii_rom[12'hAD0] = 8'h00;
        ascii_rom[12'hAD1] = 8'h00;
        ascii_rom[12'hAD2] = 8'h00;
        ascii_rom[12'hAD3] = 8'h00;
        ascii_rom[12'hAD4] = 8'h00;
        ascii_rom[12'hAD5] = 8'h00;
        ascii_rom[12'hAD6] = 8'h00;
        ascii_rom[12'hAD7] = 8'h00;
        ascii_rom[12'hAD8] = 8'h00;
        ascii_rom[12'hAD9] = 8'h00;
        ascii_rom[12'hADA] = 8'h00;
        ascii_rom[12'hADB] = 8'h00;
        ascii_rom[12'hADC] = 8'h00;
        ascii_rom[12'hADD] = 8'h00;
        ascii_rom[12'hADE] = 8'h00;
        ascii_rom[12'hADF] = 8'h00;
        // 0xAE -
        ascii_rom[12'hAE0] = 8'h00;
        ascii_rom[12'hAE1] = 8'h00;
        ascii_rom[12'hAE2] = 8'h00;
        ascii_rom[12'hAE3] = 8'h00;
        ascii_rom[12'hAE4] = 8'h00;
        ascii_rom[12'hAE5] = 8'h00;
        ascii_rom[12'hAE6] = 8'h00;
        ascii_rom[12'hAE7] = 8'h00;
        ascii_rom[12'hAE8] = 8'h00;
        ascii_rom[12'hAE9] = 8'h00;
        ascii_rom[12'hAEA] = 8'h00;
        ascii_rom[12'hAEB] = 8'h00;
        ascii_rom[12'hAEC] = 8'h00;
        ascii_rom[12'hAED] = 8'h00;
        ascii_rom[12'hAEE] = 8'h00;
        ascii_rom[12'hAEF] = 8'h00;
        // 0xAF -
        ascii_rom[12'hAF0] = 8'h00;
        ascii_rom[12'hAF1] = 8'h00;
        ascii_rom[12'hAF2] = 8'h00;
        ascii_rom[12'hAF3] = 8'h00;
        ascii_rom[12'hAF4] = 8'h00;
        ascii_rom[12'hAF5] = 8'h00;
        ascii_rom[12'hAF6] = 8'h00;
        ascii_rom[12'hAF7] = 8'h00;
        ascii_rom[12'hAF8] = 8'h00;
        ascii_rom[12'hAF9] = 8'h00;
        ascii_rom[12'hAFA] = 8'h00;
        ascii_rom[12'hAFB] = 8'h00;
        ascii_rom[12'hAFC] = 8'h00;
        ascii_rom[12'hAFD] = 8'h00;
        ascii_rom[12'hAFE] = 8'h00;
        ascii_rom[12'hAFF] = 8'h00;
        // 0xB0 -
        ascii_rom[12'hB00] = 8'h00;
        ascii_rom[12'hB01] = 8'h00;
        ascii_rom[12'hB02] = 8'h00;
        ascii_rom[12'hB03] = 8'h00;
        ascii_rom[12'hB04] = 8'h00;
        ascii_rom[12'hB05] = 8'h00;
        ascii_rom[12'hB06] = 8'h00;
        ascii_rom[12'hB07] = 8'h00;
        ascii_rom[12'hB08] = 8'h00;
        ascii_rom[12'hB09] = 8'h00;
        ascii_rom[12'hB0A] = 8'h00;
        ascii_rom[12'hB0B] = 8'h00;
        ascii_rom[12'hB0C] = 8'h00;
        ascii_rom[12'hB0D] = 8'h00;
        ascii_rom[12'hB0E] = 8'h00;
        ascii_rom[12'hB0F] = 8'h00;
        // 0xB1 -
        ascii_rom[12'hB10] = 8'h00;
        ascii_rom[12'hB11] = 8'h00;
        ascii_rom[12'hB12] = 8'h00;
        ascii_rom[12'hB13] = 8'h00;
        ascii_rom[12'hB14] = 8'h00;
        ascii_rom[12'hB15] = 8'h00;
        ascii_rom[12'hB16] = 8'h00;
        ascii_rom[12'hB17] = 8'h00;
        ascii_rom[12'hB18] = 8'h00;
        ascii_rom[12'hB19] = 8'h00;
        ascii_rom[12'hB1A] = 8'h00;
        ascii_rom[12'hB1B] = 8'h00;
        ascii_rom[12'hB1C] = 8'h00;
        ascii_rom[12'hB1D] = 8'h00;
        ascii_rom[12'hB1E] = 8'h00;
        ascii_rom[12'hB1F] = 8'h00;
        // 0xB2 -
        ascii_rom[12'hB20] = 8'h00;
        ascii_rom[12'hB21] = 8'h00;
        ascii_rom[12'hB22] = 8'h00;
        ascii_rom[12'hB23] = 8'h00;
        ascii_rom[12'hB24] = 8'h00;
        ascii_rom[12'hB25] = 8'h00;
        ascii_rom[12'hB26] = 8'h00;
        ascii_rom[12'hB27] = 8'h00;
        ascii_rom[12'hB28] = 8'h00;
        ascii_rom[12'hB29] = 8'h00;
        ascii_rom[12'hB2A] = 8'h00;
        ascii_rom[12'hB2B] = 8'h00;
        ascii_rom[12'hB2C] = 8'h00;
        ascii_rom[12'hB2D] = 8'h00;
        ascii_rom[12'hB2E] = 8'h00;
        ascii_rom[12'hB2F] = 8'h00;
        // 0xB3 -
        ascii_rom[12'hB30] = 8'h00;
        ascii_rom[12'hB31] = 8'h00;
        ascii_rom[12'hB32] = 8'h00;
        ascii_rom[12'hB33] = 8'h00;
        ascii_rom[12'hB34] = 8'h00;
        ascii_rom[12'hB35] = 8'h00;
        ascii_rom[12'hB36] = 8'h00;
        ascii_rom[12'hB37] = 8'h00;
        ascii_rom[12'hB38] = 8'h00;
        ascii_rom[12'hB39] = 8'h00;
        ascii_rom[12'hB3A] = 8'h00;
        ascii_rom[12'hB3B] = 8'h00;
        ascii_rom[12'hB3C] = 8'h00;
        ascii_rom[12'hB3D] = 8'h00;
        ascii_rom[12'hB3E] = 8'h00;
        ascii_rom[12'hB3F] = 8'h00;
        // 0xB4 -
        ascii_rom[12'hB40] = 8'h00;
        ascii_rom[12'hB41] = 8'h00;
        ascii_rom[12'hB42] = 8'h00;
        ascii_rom[12'hB43] = 8'h00;
        ascii_rom[12'hB44] = 8'h00;
        ascii_rom[12'hB45] = 8'h00;
        ascii_rom[12'hB46] = 8'h00;
        ascii_rom[12'hB47] = 8'h00;
        ascii_rom[12'hB48] = 8'h00;
        ascii_rom[12'hB49] = 8'h00;
        ascii_rom[12'hB4A] = 8'h00;
        ascii_rom[12'hB4B] = 8'h00;
        ascii_rom[12'hB4C] = 8'h00;
        ascii_rom[12'hB4D] = 8'h00;
        ascii_rom[12'hB4E] = 8'h00;
        ascii_rom[12'hB4F] = 8'h00;
        // 0xB5 -
        ascii_rom[12'hB50] = 8'h00;
        ascii_rom[12'hB51] = 8'h00;
        ascii_rom[12'hB52] = 8'h00;
        ascii_rom[12'hB53] = 8'h00;
        ascii_rom[12'hB54] = 8'h00;
        ascii_rom[12'hB55] = 8'h00;
        ascii_rom[12'hB56] = 8'h00;
        ascii_rom[12'hB57] = 8'h00;
        ascii_rom[12'hB58] = 8'h00;
        ascii_rom[12'hB59] = 8'h00;
        ascii_rom[12'hB5A] = 8'h00;
        ascii_rom[12'hB5B] = 8'h00;
        ascii_rom[12'hB5C] = 8'h00;
        ascii_rom[12'hB5D] = 8'h00;
        ascii_rom[12'hB5E] = 8'h00;
        ascii_rom[12'hB5F] = 8'h00;
        // 0xB6 -
        ascii_rom[12'hB60] = 8'h00;
        ascii_rom[12'hB61] = 8'h00;
        ascii_rom[12'hB62] = 8'h00;
        ascii_rom[12'hB63] = 8'h00;
        ascii_rom[12'hB64] = 8'h00;
        ascii_rom[12'hB65] = 8'h00;
        ascii_rom[12'hB66] = 8'h00;
        ascii_rom[12'hB67] = 8'h00;
        ascii_rom[12'hB68] = 8'h00;
        ascii_rom[12'hB69] = 8'h00;
        ascii_rom[12'hB6A] = 8'h00;
        ascii_rom[12'hB6B] = 8'h00;
        ascii_rom[12'hB6C] = 8'h00;
        ascii_rom[12'hB6D] = 8'h00;
        ascii_rom[12'hB6E] = 8'h00;
        ascii_rom[12'hB6F] = 8'h00;
        // 0xB7 -
        ascii_rom[12'hB70] = 8'h00;
        ascii_rom[12'hB71] = 8'h00;
        ascii_rom[12'hB72] = 8'h00;
        ascii_rom[12'hB73] = 8'h00;
        ascii_rom[12'hB74] = 8'h00;
        ascii_rom[12'hB75] = 8'h00;
        ascii_rom[12'hB76] = 8'h00;
        ascii_rom[12'hB77] = 8'h00;
        ascii_rom[12'hB78] = 8'h00;
        ascii_rom[12'hB79] = 8'h00;
        ascii_rom[12'hB7A] = 8'h00;
        ascii_rom[12'hB7B] = 8'h00;
        ascii_rom[12'hB7C] = 8'h00;
        ascii_rom[12'hB7D] = 8'h00;
        ascii_rom[12'hB7E] = 8'h00;
        ascii_rom[12'hB7F] = 8'h00;
        // 0xB8 -
        ascii_rom[12'hB80] = 8'h00;
        ascii_rom[12'hB81] = 8'h00;
        ascii_rom[12'hB82] = 8'h00;
        ascii_rom[12'hB83] = 8'h00;
        ascii_rom[12'hB84] = 8'h00;
        ascii_rom[12'hB85] = 8'h00;
        ascii_rom[12'hB86] = 8'h00;
        ascii_rom[12'hB87] = 8'h00;
        ascii_rom[12'hB88] = 8'h00;
        ascii_rom[12'hB89] = 8'h00;
        ascii_rom[12'hB8A] = 8'h00;
        ascii_rom[12'hB8B] = 8'h00;
        ascii_rom[12'hB8C] = 8'h00;
        ascii_rom[12'hB8D] = 8'h00;
        ascii_rom[12'hB8E] = 8'h00;
        ascii_rom[12'hB8F] = 8'h00;
        // 0xB9 -
        ascii_rom[12'hB90] = 8'h00;
        ascii_rom[12'hB91] = 8'h00;
        ascii_rom[12'hB92] = 8'h00;
        ascii_rom[12'hB93] = 8'h00;
        ascii_rom[12'hB94] = 8'h00;
        ascii_rom[12'hB95] = 8'h00;
        ascii_rom[12'hB96] = 8'h00;
        ascii_rom[12'hB97] = 8'h00;
        ascii_rom[12'hB98] = 8'h00;
        ascii_rom[12'hB99] = 8'h00;
        ascii_rom[12'hB9A] = 8'h00;
        ascii_rom[12'hB9B] = 8'h00;
        ascii_rom[12'hB9C] = 8'h00;
        ascii_rom[12'hB9D] = 8'h00;
        ascii_rom[12'hB9E] = 8'h00;
        ascii_rom[12'hB9F] = 8'h00;
        // 0xBA -
        ascii_rom[12'hBA0] = 8'h00;
        ascii_rom[12'hBA1] = 8'h00;
        ascii_rom[12'hBA2] = 8'h00;
        ascii_rom[12'hBA3] = 8'h00;
        ascii_rom[12'hBA4] = 8'h00;
        ascii_rom[12'hBA5] = 8'h00;
        ascii_rom[12'hBA6] = 8'h00;
        ascii_rom[12'hBA7] = 8'h00;
        ascii_rom[12'hBA8] = 8'h00;
        ascii_rom[12'hBA9] = 8'h00;
        ascii_rom[12'hBAA] = 8'h00;
        ascii_rom[12'hBAB] = 8'h00;
        ascii_rom[12'hBAC] = 8'h00;
        ascii_rom[12'hBAD] = 8'h00;
        ascii_rom[12'hBAE] = 8'h00;
        ascii_rom[12'hBAF] = 8'h00;
        // 0xBB -
        ascii_rom[12'hBB0] = 8'h00;
        ascii_rom[12'hBB1] = 8'h00;
        ascii_rom[12'hBB2] = 8'h00;
        ascii_rom[12'hBB3] = 8'h00;
        ascii_rom[12'hBB4] = 8'h00;
        ascii_rom[12'hBB5] = 8'h00;
        ascii_rom[12'hBB6] = 8'h00;
        ascii_rom[12'hBB7] = 8'h00;
        ascii_rom[12'hBB8] = 8'h00;
        ascii_rom[12'hBB9] = 8'h00;
        ascii_rom[12'hBBA] = 8'h00;
        ascii_rom[12'hBBB] = 8'h00;
        ascii_rom[12'hBBC] = 8'h00;
        ascii_rom[12'hBBD] = 8'h00;
        ascii_rom[12'hBBE] = 8'h00;
        ascii_rom[12'hBBF] = 8'h00;
        // 0xBC -
        ascii_rom[12'hBC0] = 8'h00;
        ascii_rom[12'hBC1] = 8'h00;
        ascii_rom[12'hBC2] = 8'h00;
        ascii_rom[12'hBC3] = 8'h00;
        ascii_rom[12'hBC4] = 8'h00;
        ascii_rom[12'hBC5] = 8'h00;
        ascii_rom[12'hBC6] = 8'h00;
        ascii_rom[12'hBC7] = 8'h00;
        ascii_rom[12'hBC8] = 8'h00;
        ascii_rom[12'hBC9] = 8'h00;
        ascii_rom[12'hBCA] = 8'h00;
        ascii_rom[12'hBCB] = 8'h00;
        ascii_rom[12'hBCC] = 8'h00;
        ascii_rom[12'hBCD] = 8'h00;
        ascii_rom[12'hBCE] = 8'h00;
        ascii_rom[12'hBCF] = 8'h00;
        // 0xBD -
        ascii_rom[12'hBD0] = 8'h00;
        ascii_rom[12'hBD1] = 8'h00;
        ascii_rom[12'hBD2] = 8'h00;
        ascii_rom[12'hBD3] = 8'h00;
        ascii_rom[12'hBD4] = 8'h00;
        ascii_rom[12'hBD5] = 8'h00;
        ascii_rom[12'hBD6] = 8'h00;
        ascii_rom[12'hBD7] = 8'h00;
        ascii_rom[12'hBD8] = 8'h00;
        ascii_rom[12'hBD9] = 8'h00;
        ascii_rom[12'hBDA] = 8'h00;
        ascii_rom[12'hBDB] = 8'h00;
        ascii_rom[12'hBDC] = 8'h00;
        ascii_rom[12'hBDD] = 8'h00;
        ascii_rom[12'hBDE] = 8'h00;
        ascii_rom[12'hBDF] = 8'h00;
        // 0xBE -
        ascii_rom[12'hBE0] = 8'h00;
        ascii_rom[12'hBE1] = 8'h00;
        ascii_rom[12'hBE2] = 8'h00;
        ascii_rom[12'hBE3] = 8'h00;
        ascii_rom[12'hBE4] = 8'h00;
        ascii_rom[12'hBE5] = 8'h00;
        ascii_rom[12'hBE6] = 8'h00;
        ascii_rom[12'hBE7] = 8'h00;
        ascii_rom[12'hBE8] = 8'h00;
        ascii_rom[12'hBE9] = 8'h00;
        ascii_rom[12'hBEA] = 8'h00;
        ascii_rom[12'hBEB] = 8'h00;
        ascii_rom[12'hBEC] = 8'h00;
        ascii_rom[12'hBED] = 8'h00;
        ascii_rom[12'hBEE] = 8'h00;
        ascii_rom[12'hBEF] = 8'h00;
        // 0xBF -
        ascii_rom[12'hBF0] = 8'h00;
        ascii_rom[12'hBF1] = 8'h00;
        ascii_rom[12'hBF2] = 8'h00;
        ascii_rom[12'hBF3] = 8'h00;
        ascii_rom[12'hBF4] = 8'h00;
        ascii_rom[12'hBF5] = 8'h00;
        ascii_rom[12'hBF6] = 8'h00;
        ascii_rom[12'hBF7] = 8'h00;
        ascii_rom[12'hBF8] = 8'h00;
        ascii_rom[12'hBF9] = 8'h00;
        ascii_rom[12'hBFA] = 8'h00;
        ascii_rom[12'hBFB] = 8'h00;
        ascii_rom[12'hBFC] = 8'h00;
        ascii_rom[12'hBFD] = 8'h00;
        ascii_rom[12'hBFE] = 8'h00;
        ascii_rom[12'hBFF] = 8'h00;
        // 0xC0 -
        ascii_rom[12'hC00] = 8'h00;
        ascii_rom[12'hC01] = 8'h00;
        ascii_rom[12'hC02] = 8'h00;
        ascii_rom[12'hC03] = 8'h00;
        ascii_rom[12'hC04] = 8'h00;
        ascii_rom[12'hC05] = 8'h00;
        ascii_rom[12'hC06] = 8'h00;
        ascii_rom[12'hC07] = 8'h00;
        ascii_rom[12'hC08] = 8'h00;
        ascii_rom[12'hC09] = 8'h00;
        ascii_rom[12'hC0A] = 8'h00;
        ascii_rom[12'hC0B] = 8'h00;
        ascii_rom[12'hC0C] = 8'h00;
        ascii_rom[12'hC0D] = 8'h00;
        ascii_rom[12'hC0E] = 8'h00;
        ascii_rom[12'hC0F] = 8'h00;
        // 0xC1 -
        ascii_rom[12'hC10] = 8'h00;
        ascii_rom[12'hC11] = 8'h00;
        ascii_rom[12'hC12] = 8'h00;
        ascii_rom[12'hC13] = 8'h00;
        ascii_rom[12'hC14] = 8'h00;
        ascii_rom[12'hC15] = 8'h00;
        ascii_rom[12'hC16] = 8'h00;
        ascii_rom[12'hC17] = 8'h00;
        ascii_rom[12'hC18] = 8'h00;
        ascii_rom[12'hC19] = 8'h00;
        ascii_rom[12'hC1A] = 8'h00;
        ascii_rom[12'hC1B] = 8'h00;
        ascii_rom[12'hC1C] = 8'h00;
        ascii_rom[12'hC1D] = 8'h00;
        ascii_rom[12'hC1E] = 8'h00;
        ascii_rom[12'hC1F] = 8'h00;
        // 0xC2 -
        ascii_rom[12'hC20] = 8'h00;
        ascii_rom[12'hC21] = 8'h00;
        ascii_rom[12'hC22] = 8'h00;
        ascii_rom[12'hC23] = 8'h00;
        ascii_rom[12'hC24] = 8'h00;
        ascii_rom[12'hC25] = 8'h00;
        ascii_rom[12'hC26] = 8'h00;
        ascii_rom[12'hC27] = 8'h00;
        ascii_rom[12'hC28] = 8'h00;
        ascii_rom[12'hC29] = 8'h00;
        ascii_rom[12'hC2A] = 8'h00;
        ascii_rom[12'hC2B] = 8'h00;
        ascii_rom[12'hC2C] = 8'h00;
        ascii_rom[12'hC2D] = 8'h00;
        ascii_rom[12'hC2E] = 8'h00;
        ascii_rom[12'hC2F] = 8'h00;
        // 0xC3 -
        ascii_rom[12'hC30] = 8'h00;
        ascii_rom[12'hC31] = 8'h00;
        ascii_rom[12'hC32] = 8'h00;
        ascii_rom[12'hC33] = 8'h00;
        ascii_rom[12'hC34] = 8'h00;
        ascii_rom[12'hC35] = 8'h00;
        ascii_rom[12'hC36] = 8'h00;
        ascii_rom[12'hC37] = 8'h00;
        ascii_rom[12'hC38] = 8'h00;
        ascii_rom[12'hC39] = 8'h00;
        ascii_rom[12'hC3A] = 8'h00;
        ascii_rom[12'hC3B] = 8'h00;
        ascii_rom[12'hC3C] = 8'h00;
        ascii_rom[12'hC3D] = 8'h00;
        ascii_rom[12'hC3E] = 8'h00;
        ascii_rom[12'hC3F] = 8'h00;
        // 0xC4 -
        ascii_rom[12'hC40] = 8'h00;
        ascii_rom[12'hC41] = 8'h00;
        ascii_rom[12'hC42] = 8'h00;
        ascii_rom[12'hC43] = 8'h00;
        ascii_rom[12'hC44] = 8'h00;
        ascii_rom[12'hC45] = 8'h00;
        ascii_rom[12'hC46] = 8'h00;
        ascii_rom[12'hC47] = 8'h00;
        ascii_rom[12'hC48] = 8'h00;
        ascii_rom[12'hC49] = 8'h00;
        ascii_rom[12'hC4A] = 8'h00;
        ascii_rom[12'hC4B] = 8'h00;
        ascii_rom[12'hC4C] = 8'h00;
        ascii_rom[12'hC4D] = 8'h00;
        ascii_rom[12'hC4E] = 8'h00;
        ascii_rom[12'hC4F] = 8'h00;
        // 0xC5 -
        ascii_rom[12'hC50] = 8'h00;
        ascii_rom[12'hC51] = 8'h00;
        ascii_rom[12'hC52] = 8'h00;
        ascii_rom[12'hC53] = 8'h00;
        ascii_rom[12'hC54] = 8'h00;
        ascii_rom[12'hC55] = 8'h00;
        ascii_rom[12'hC56] = 8'h00;
        ascii_rom[12'hC57] = 8'h00;
        ascii_rom[12'hC58] = 8'h00;
        ascii_rom[12'hC59] = 8'h00;
        ascii_rom[12'hC5A] = 8'h00;
        ascii_rom[12'hC5B] = 8'h00;
        ascii_rom[12'hC5C] = 8'h00;
        ascii_rom[12'hC5D] = 8'h00;
        ascii_rom[12'hC5E] = 8'h00;
        ascii_rom[12'hC5F] = 8'h00;
        // 0xC6 -
        ascii_rom[12'hC60] = 8'h00;
        ascii_rom[12'hC61] = 8'h00;
        ascii_rom[12'hC62] = 8'h00;
        ascii_rom[12'hC63] = 8'h00;
        ascii_rom[12'hC64] = 8'h00;
        ascii_rom[12'hC65] = 8'h00;
        ascii_rom[12'hC66] = 8'h00;
        ascii_rom[12'hC67] = 8'h00;
        ascii_rom[12'hC68] = 8'h00;
        ascii_rom[12'hC69] = 8'h00;
        ascii_rom[12'hC6A] = 8'h00;
        ascii_rom[12'hC6B] = 8'h00;
        ascii_rom[12'hC6C] = 8'h00;
        ascii_rom[12'hC6D] = 8'h00;
        ascii_rom[12'hC6E] = 8'h00;
        ascii_rom[12'hC6F] = 8'h00;
        // 0xC7 -
        ascii_rom[12'hC70] = 8'h00;
        ascii_rom[12'hC71] = 8'h00;
        ascii_rom[12'hC72] = 8'h00;
        ascii_rom[12'hC73] = 8'h00;
        ascii_rom[12'hC74] = 8'h00;
        ascii_rom[12'hC75] = 8'h00;
        ascii_rom[12'hC76] = 8'h00;
        ascii_rom[12'hC77] = 8'h00;
        ascii_rom[12'hC78] = 8'h00;
        ascii_rom[12'hC79] = 8'h00;
        ascii_rom[12'hC7A] = 8'h00;
        ascii_rom[12'hC7B] = 8'h00;
        ascii_rom[12'hC7C] = 8'h00;
        ascii_rom[12'hC7D] = 8'h00;
        ascii_rom[12'hC7E] = 8'h00;
        ascii_rom[12'hC7F] = 8'h00;
        // 0xC8 -
        ascii_rom[12'hC80] = 8'h00;
        ascii_rom[12'hC81] = 8'h00;
        ascii_rom[12'hC82] = 8'h00;
        ascii_rom[12'hC83] = 8'h00;
        ascii_rom[12'hC84] = 8'h00;
        ascii_rom[12'hC85] = 8'h00;
        ascii_rom[12'hC86] = 8'h00;
        ascii_rom[12'hC87] = 8'h00;
        ascii_rom[12'hC88] = 8'h00;
        ascii_rom[12'hC89] = 8'h00;
        ascii_rom[12'hC8A] = 8'h00;
        ascii_rom[12'hC8B] = 8'h00;
        ascii_rom[12'hC8C] = 8'h00;
        ascii_rom[12'hC8D] = 8'h00;
        ascii_rom[12'hC8E] = 8'h00;
        ascii_rom[12'hC8F] = 8'h00;
        // 0xC9 -
        ascii_rom[12'hC90] = 8'h00;
        ascii_rom[12'hC91] = 8'h00;
        ascii_rom[12'hC92] = 8'h00;
        ascii_rom[12'hC93] = 8'h00;
        ascii_rom[12'hC94] = 8'h00;
        ascii_rom[12'hC95] = 8'h00;
        ascii_rom[12'hC96] = 8'h00;
        ascii_rom[12'hC97] = 8'h00;
        ascii_rom[12'hC98] = 8'h00;
        ascii_rom[12'hC99] = 8'h00;
        ascii_rom[12'hC9A] = 8'h00;
        ascii_rom[12'hC9B] = 8'h00;
        ascii_rom[12'hC9C] = 8'h00;
        ascii_rom[12'hC9D] = 8'h00;
        ascii_rom[12'hC9E] = 8'h00;
        ascii_rom[12'hC9F] = 8'h00;
        // 0xCA -
        ascii_rom[12'hCA0] = 8'h00;
        ascii_rom[12'hCA1] = 8'h00;
        ascii_rom[12'hCA2] = 8'h00;
        ascii_rom[12'hCA3] = 8'h00;
        ascii_rom[12'hCA4] = 8'h00;
        ascii_rom[12'hCA5] = 8'h00;
        ascii_rom[12'hCA6] = 8'h00;
        ascii_rom[12'hCA7] = 8'h00;
        ascii_rom[12'hCA8] = 8'h00;
        ascii_rom[12'hCA9] = 8'h00;
        ascii_rom[12'hCAA] = 8'h00;
        ascii_rom[12'hCAB] = 8'h00;
        ascii_rom[12'hCAC] = 8'h00;
        ascii_rom[12'hCAD] = 8'h00;
        ascii_rom[12'hCAE] = 8'h00;
        ascii_rom[12'hCAF] = 8'h00;
        // 0xCB -
        ascii_rom[12'hCB0] = 8'h00;
        ascii_rom[12'hCB1] = 8'h00;
        ascii_rom[12'hCB2] = 8'h00;
        ascii_rom[12'hCB3] = 8'h00;
        ascii_rom[12'hCB4] = 8'h00;
        ascii_rom[12'hCB5] = 8'h00;
        ascii_rom[12'hCB6] = 8'h00;
        ascii_rom[12'hCB7] = 8'h00;
        ascii_rom[12'hCB8] = 8'h00;
        ascii_rom[12'hCB9] = 8'h00;
        ascii_rom[12'hCBA] = 8'h00;
        ascii_rom[12'hCBB] = 8'h00;
        ascii_rom[12'hCBC] = 8'h00;
        ascii_rom[12'hCBD] = 8'h00;
        ascii_rom[12'hCBE] = 8'h00;
        ascii_rom[12'hCBF] = 8'h00;
        // 0xCC -
        ascii_rom[12'hCC0] = 8'h00;
        ascii_rom[12'hCC1] = 8'h00;
        ascii_rom[12'hCC2] = 8'h00;
        ascii_rom[12'hCC3] = 8'h00;
        ascii_rom[12'hCC4] = 8'h00;
        ascii_rom[12'hCC5] = 8'h00;
        ascii_rom[12'hCC6] = 8'h00;
        ascii_rom[12'hCC7] = 8'h00;
        ascii_rom[12'hCC8] = 8'h00;
        ascii_rom[12'hCC9] = 8'h00;
        ascii_rom[12'hCCA] = 8'h00;
        ascii_rom[12'hCCB] = 8'h00;
        ascii_rom[12'hCCC] = 8'h00;
        ascii_rom[12'hCCD] = 8'h00;
        ascii_rom[12'hCCE] = 8'h00;
        ascii_rom[12'hCCF] = 8'h00;
        // 0xCD -
        ascii_rom[12'hCD0] = 8'h00;
        ascii_rom[12'hCD1] = 8'h00;
        ascii_rom[12'hCD2] = 8'h00;
        ascii_rom[12'hCD3] = 8'h00;
        ascii_rom[12'hCD4] = 8'h00;
        ascii_rom[12'hCD5] = 8'h00;
        ascii_rom[12'hCD6] = 8'h00;
        ascii_rom[12'hCD7] = 8'h00;
        ascii_rom[12'hCD8] = 8'h00;
        ascii_rom[12'hCD9] = 8'h00;
        ascii_rom[12'hCDA] = 8'h00;
        ascii_rom[12'hCDB] = 8'h00;
        ascii_rom[12'hCDC] = 8'h00;
        ascii_rom[12'hCDD] = 8'h00;
        ascii_rom[12'hCDE] = 8'h00;
        ascii_rom[12'hCDF] = 8'h00;
        // 0xCE -
        ascii_rom[12'hCE0] = 8'h00;
        ascii_rom[12'hCE1] = 8'h00;
        ascii_rom[12'hCE2] = 8'h00;
        ascii_rom[12'hCE3] = 8'h00;
        ascii_rom[12'hCE4] = 8'h00;
        ascii_rom[12'hCE5] = 8'h00;
        ascii_rom[12'hCE6] = 8'h00;
        ascii_rom[12'hCE7] = 8'h00;
        ascii_rom[12'hCE8] = 8'h00;
        ascii_rom[12'hCE9] = 8'h00;
        ascii_rom[12'hCEA] = 8'h00;
        ascii_rom[12'hCEB] = 8'h00;
        ascii_rom[12'hCEC] = 8'h00;
        ascii_rom[12'hCED] = 8'h00;
        ascii_rom[12'hCEE] = 8'h00;
        ascii_rom[12'hCEF] = 8'h00;
        // 0xCF -
        ascii_rom[12'hCF0] = 8'h00;
        ascii_rom[12'hCF1] = 8'h00;
        ascii_rom[12'hCF2] = 8'h00;
        ascii_rom[12'hCF3] = 8'h00;
        ascii_rom[12'hCF4] = 8'h00;
        ascii_rom[12'hCF5] = 8'h00;
        ascii_rom[12'hCF6] = 8'h00;
        ascii_rom[12'hCF7] = 8'h00;
        ascii_rom[12'hCF8] = 8'h00;
        ascii_rom[12'hCF9] = 8'h00;
        ascii_rom[12'hCFA] = 8'h00;
        ascii_rom[12'hCFB] = 8'h00;
        ascii_rom[12'hCFC] = 8'h00;
        ascii_rom[12'hCFD] = 8'h00;
        ascii_rom[12'hCFE] = 8'h00;
        ascii_rom[12'hCFF] = 8'h00;
        // 0xD0 -
        ascii_rom[12'hD00] = 8'h00;
        ascii_rom[12'hD01] = 8'h00;
        ascii_rom[12'hD02] = 8'h00;
        ascii_rom[12'hD03] = 8'h00;
        ascii_rom[12'hD04] = 8'h00;
        ascii_rom[12'hD05] = 8'h00;
        ascii_rom[12'hD06] = 8'h00;
        ascii_rom[12'hD07] = 8'h00;
        ascii_rom[12'hD08] = 8'h00;
        ascii_rom[12'hD09] = 8'h00;
        ascii_rom[12'hD0A] = 8'h00;
        ascii_rom[12'hD0B] = 8'h00;
        ascii_rom[12'hD0C] = 8'h00;
        ascii_rom[12'hD0D] = 8'h00;
        ascii_rom[12'hD0E] = 8'h00;
        ascii_rom[12'hD0F] = 8'h00;
        // 0xD1 -
        ascii_rom[12'hD10] = 8'h00;
        ascii_rom[12'hD11] = 8'h00;
        ascii_rom[12'hD12] = 8'h00;
        ascii_rom[12'hD13] = 8'h00;
        ascii_rom[12'hD14] = 8'h00;
        ascii_rom[12'hD15] = 8'h00;
        ascii_rom[12'hD16] = 8'h00;
        ascii_rom[12'hD17] = 8'h00;
        ascii_rom[12'hD18] = 8'h00;
        ascii_rom[12'hD19] = 8'h00;
        ascii_rom[12'hD1A] = 8'h00;
        ascii_rom[12'hD1B] = 8'h00;
        ascii_rom[12'hD1C] = 8'h00;
        ascii_rom[12'hD1D] = 8'h00;
        ascii_rom[12'hD1E] = 8'h00;
        ascii_rom[12'hD1F] = 8'h00;
        // 0xD2 -
        ascii_rom[12'hD20] = 8'h00;
        ascii_rom[12'hD21] = 8'h00;
        ascii_rom[12'hD22] = 8'h00;
        ascii_rom[12'hD23] = 8'h00;
        ascii_rom[12'hD24] = 8'h00;
        ascii_rom[12'hD25] = 8'h00;
        ascii_rom[12'hD26] = 8'h00;
        ascii_rom[12'hD27] = 8'h00;
        ascii_rom[12'hD28] = 8'h00;
        ascii_rom[12'hD29] = 8'h00;
        ascii_rom[12'hD2A] = 8'h00;
        ascii_rom[12'hD2B] = 8'h00;
        ascii_rom[12'hD2C] = 8'h00;
        ascii_rom[12'hD2D] = 8'h00;
        ascii_rom[12'hD2E] = 8'h00;
        ascii_rom[12'hD2F] = 8'h00;
        // 0xD3 -
        ascii_rom[12'hD30] = 8'h00;
        ascii_rom[12'hD31] = 8'h00;
        ascii_rom[12'hD32] = 8'h00;
        ascii_rom[12'hD33] = 8'h00;
        ascii_rom[12'hD34] = 8'h00;
        ascii_rom[12'hD35] = 8'h00;
        ascii_rom[12'hD36] = 8'h00;
        ascii_rom[12'hD37] = 8'h00;
        ascii_rom[12'hD38] = 8'h00;
        ascii_rom[12'hD39] = 8'h00;
        ascii_rom[12'hD3A] = 8'h00;
        ascii_rom[12'hD3B] = 8'h00;
        ascii_rom[12'hD3C] = 8'h00;
        ascii_rom[12'hD3D] = 8'h00;
        ascii_rom[12'hD3E] = 8'h00;
        ascii_rom[12'hD3F] = 8'h00;
        // 0xD4 -
        ascii_rom[12'hD40] = 8'h00;
        ascii_rom[12'hD41] = 8'h00;
        ascii_rom[12'hD42] = 8'h00;
        ascii_rom[12'hD43] = 8'h00;
        ascii_rom[12'hD44] = 8'h00;
        ascii_rom[12'hD45] = 8'h00;
        ascii_rom[12'hD46] = 8'h00;
        ascii_rom[12'hD47] = 8'h00;
        ascii_rom[12'hD48] = 8'h00;
        ascii_rom[12'hD49] = 8'h00;
        ascii_rom[12'hD4A] = 8'h00;
        ascii_rom[12'hD4B] = 8'h00;
        ascii_rom[12'hD4C] = 8'h00;
        ascii_rom[12'hD4D] = 8'h00;
        ascii_rom[12'hD4E] = 8'h00;
        ascii_rom[12'hD4F] = 8'h00;
        // 0xD5 -
        ascii_rom[12'hD50] = 8'h00;
        ascii_rom[12'hD51] = 8'h00;
        ascii_rom[12'hD52] = 8'h00;
        ascii_rom[12'hD53] = 8'h00;
        ascii_rom[12'hD54] = 8'h00;
        ascii_rom[12'hD55] = 8'h00;
        ascii_rom[12'hD56] = 8'h00;
        ascii_rom[12'hD57] = 8'h00;
        ascii_rom[12'hD58] = 8'h00;
        ascii_rom[12'hD59] = 8'h00;
        ascii_rom[12'hD5A] = 8'h00;
        ascii_rom[12'hD5B] = 8'h00;
        ascii_rom[12'hD5C] = 8'h00;
        ascii_rom[12'hD5D] = 8'h00;
        ascii_rom[12'hD5E] = 8'h00;
        ascii_rom[12'hD5F] = 8'h00;
        // 0xD6 -
        ascii_rom[12'hD60] = 8'h00;
        ascii_rom[12'hD61] = 8'h00;
        ascii_rom[12'hD62] = 8'h00;
        ascii_rom[12'hD63] = 8'h00;
        ascii_rom[12'hD64] = 8'h00;
        ascii_rom[12'hD65] = 8'h00;
        ascii_rom[12'hD66] = 8'h00;
        ascii_rom[12'hD67] = 8'h00;
        ascii_rom[12'hD68] = 8'h00;
        ascii_rom[12'hD69] = 8'h00;
        ascii_rom[12'hD6A] = 8'h00;
        ascii_rom[12'hD6B] = 8'h00;
        ascii_rom[12'hD6C] = 8'h00;
        ascii_rom[12'hD6D] = 8'h00;
        ascii_rom[12'hD6E] = 8'h00;
        ascii_rom[12'hD6F] = 8'h00;
        // 0xD7 -
        ascii_rom[12'hD70] = 8'h00;
        ascii_rom[12'hD71] = 8'h00;
        ascii_rom[12'hD72] = 8'h00;
        ascii_rom[12'hD73] = 8'h00;
        ascii_rom[12'hD74] = 8'h00;
        ascii_rom[12'hD75] = 8'h00;
        ascii_rom[12'hD76] = 8'h00;
        ascii_rom[12'hD77] = 8'h00;
        ascii_rom[12'hD78] = 8'h00;
        ascii_rom[12'hD79] = 8'h00;
        ascii_rom[12'hD7A] = 8'h00;
        ascii_rom[12'hD7B] = 8'h00;
        ascii_rom[12'hD7C] = 8'h00;
        ascii_rom[12'hD7D] = 8'h00;
        ascii_rom[12'hD7E] = 8'h00;
        ascii_rom[12'hD7F] = 8'h00;
        // 0xD8 -
        ascii_rom[12'hD80] = 8'h00;
        ascii_rom[12'hD81] = 8'h00;
        ascii_rom[12'hD82] = 8'h00;
        ascii_rom[12'hD83] = 8'h00;
        ascii_rom[12'hD84] = 8'h00;
        ascii_rom[12'hD85] = 8'h00;
        ascii_rom[12'hD86] = 8'h00;
        ascii_rom[12'hD87] = 8'h00;
        ascii_rom[12'hD88] = 8'h00;
        ascii_rom[12'hD89] = 8'h00;
        ascii_rom[12'hD8A] = 8'h00;
        ascii_rom[12'hD8B] = 8'h00;
        ascii_rom[12'hD8C] = 8'h00;
        ascii_rom[12'hD8D] = 8'h00;
        ascii_rom[12'hD8E] = 8'h00;
        ascii_rom[12'hD8F] = 8'h00;
        // 0xD9 -
        ascii_rom[12'hD90] = 8'h00;
        ascii_rom[12'hD91] = 8'h00;
        ascii_rom[12'hD92] = 8'h00;
        ascii_rom[12'hD93] = 8'h00;
        ascii_rom[12'hD94] = 8'h00;
        ascii_rom[12'hD95] = 8'h00;
        ascii_rom[12'hD96] = 8'h00;
        ascii_rom[12'hD97] = 8'h00;
        ascii_rom[12'hD98] = 8'h00;
        ascii_rom[12'hD99] = 8'h00;
        ascii_rom[12'hD9A] = 8'h00;
        ascii_rom[12'hD9B] = 8'h00;
        ascii_rom[12'hD9C] = 8'h00;
        ascii_rom[12'hD9D] = 8'h00;
        ascii_rom[12'hD9E] = 8'h00;
        ascii_rom[12'hD9F] = 8'h00;
        // 0xDA -
        ascii_rom[12'hDA0] = 8'h00;
        ascii_rom[12'hDA1] = 8'h00;
        ascii_rom[12'hDA2] = 8'h00;
        ascii_rom[12'hDA3] = 8'h00;
        ascii_rom[12'hDA4] = 8'h00;
        ascii_rom[12'hDA5] = 8'h00;
        ascii_rom[12'hDA6] = 8'h00;
        ascii_rom[12'hDA7] = 8'h00;
        ascii_rom[12'hDA8] = 8'h00;
        ascii_rom[12'hDA9] = 8'h00;
        ascii_rom[12'hDAA] = 8'h00;
        ascii_rom[12'hDAB] = 8'h00;
        ascii_rom[12'hDAC] = 8'h00;
        ascii_rom[12'hDAD] = 8'h00;
        ascii_rom[12'hDAE] = 8'h00;
        ascii_rom[12'hDAF] = 8'h00;
        // 0xDB -
        ascii_rom[12'hDB0] = 8'h00;
        ascii_rom[12'hDB1] = 8'h00;
        ascii_rom[12'hDB2] = 8'h00;
        ascii_rom[12'hDB3] = 8'h00;
        ascii_rom[12'hDB4] = 8'h00;
        ascii_rom[12'hDB5] = 8'h00;
        ascii_rom[12'hDB6] = 8'h00;
        ascii_rom[12'hDB7] = 8'h00;
        ascii_rom[12'hDB8] = 8'h00;
        ascii_rom[12'hDB9] = 8'h00;
        ascii_rom[12'hDBA] = 8'h00;
        ascii_rom[12'hDBB] = 8'h00;
        ascii_rom[12'hDBC] = 8'h00;
        ascii_rom[12'hDBD] = 8'h00;
        ascii_rom[12'hDBE] = 8'h00;
        ascii_rom[12'hDBF] = 8'h00;
        // 0xDC -
        ascii_rom[12'hDC0] = 8'h00;
        ascii_rom[12'hDC1] = 8'h00;
        ascii_rom[12'hDC2] = 8'h00;
        ascii_rom[12'hDC3] = 8'h00;
        ascii_rom[12'hDC4] = 8'h00;
        ascii_rom[12'hDC5] = 8'h00;
        ascii_rom[12'hDC6] = 8'h00;
        ascii_rom[12'hDC7] = 8'h00;
        ascii_rom[12'hDC8] = 8'h00;
        ascii_rom[12'hDC9] = 8'h00;
        ascii_rom[12'hDCA] = 8'h00;
        ascii_rom[12'hDCB] = 8'h00;
        ascii_rom[12'hDCC] = 8'h00;
        ascii_rom[12'hDCD] = 8'h00;
        ascii_rom[12'hDCE] = 8'h00;
        ascii_rom[12'hDCF] = 8'h00;
        // 0xDD -
        ascii_rom[12'hDD0] = 8'h00;
        ascii_rom[12'hDD1] = 8'h00;
        ascii_rom[12'hDD2] = 8'h00;
        ascii_rom[12'hDD3] = 8'h00;
        ascii_rom[12'hDD4] = 8'h00;
        ascii_rom[12'hDD5] = 8'h00;
        ascii_rom[12'hDD6] = 8'h00;
        ascii_rom[12'hDD7] = 8'h00;
        ascii_rom[12'hDD8] = 8'h00;
        ascii_rom[12'hDD9] = 8'h00;
        ascii_rom[12'hDDA] = 8'h00;
        ascii_rom[12'hDDB] = 8'h00;
        ascii_rom[12'hDDC] = 8'h00;
        ascii_rom[12'hDDD] = 8'h00;
        ascii_rom[12'hDDE] = 8'h00;
        ascii_rom[12'hDDF] = 8'h00;
        // 0xDE -
        ascii_rom[12'hDE0] = 8'h00;
        ascii_rom[12'hDE1] = 8'h00;
        ascii_rom[12'hDE2] = 8'h00;
        ascii_rom[12'hDE3] = 8'h00;
        ascii_rom[12'hDE4] = 8'h00;
        ascii_rom[12'hDE5] = 8'h00;
        ascii_rom[12'hDE6] = 8'h00;
        ascii_rom[12'hDE7] = 8'h00;
        ascii_rom[12'hDE8] = 8'h00;
        ascii_rom[12'hDE9] = 8'h00;
        ascii_rom[12'hDEA] = 8'h00;
        ascii_rom[12'hDEB] = 8'h00;
        ascii_rom[12'hDEC] = 8'h00;
        ascii_rom[12'hDED] = 8'h00;
        ascii_rom[12'hDEE] = 8'h00;
        ascii_rom[12'hDEF] = 8'h00;
        // 0xDF -
        ascii_rom[12'hDF0] = 8'h00;
        ascii_rom[12'hDF1] = 8'h00;
        ascii_rom[12'hDF2] = 8'h00;
        ascii_rom[12'hDF3] = 8'h00;
        ascii_rom[12'hDF4] = 8'h00;
        ascii_rom[12'hDF5] = 8'h00;
        ascii_rom[12'hDF6] = 8'h00;
        ascii_rom[12'hDF7] = 8'h00;
        ascii_rom[12'hDF8] = 8'h00;
        ascii_rom[12'hDF9] = 8'h00;
        ascii_rom[12'hDFA] = 8'h00;
        ascii_rom[12'hDFB] = 8'h00;
        ascii_rom[12'hDFC] = 8'h00;
        ascii_rom[12'hDFD] = 8'h00;
        ascii_rom[12'hDFE] = 8'h00;
        ascii_rom[12'hDFF] = 8'h00;
        // 0xE0 -
        ascii_rom[12'hE00] = 8'h00;
        ascii_rom[12'hE01] = 8'h00;
        ascii_rom[12'hE02] = 8'h00;
        ascii_rom[12'hE03] = 8'h00;
        ascii_rom[12'hE04] = 8'h00;
        ascii_rom[12'hE05] = 8'h00;
        ascii_rom[12'hE06] = 8'h00;
        ascii_rom[12'hE07] = 8'h00;
        ascii_rom[12'hE08] = 8'h00;
        ascii_rom[12'hE09] = 8'h00;
        ascii_rom[12'hE0A] = 8'h00;
        ascii_rom[12'hE0B] = 8'h00;
        ascii_rom[12'hE0C] = 8'h00;
        ascii_rom[12'hE0D] = 8'h00;
        ascii_rom[12'hE0E] = 8'h00;
        ascii_rom[12'hE0F] = 8'h00;
        // 0xE1 -
        ascii_rom[12'hE10] = 8'h00;
        ascii_rom[12'hE11] = 8'h00;
        ascii_rom[12'hE12] = 8'h00;
        ascii_rom[12'hE13] = 8'h00;
        ascii_rom[12'hE14] = 8'h00;
        ascii_rom[12'hE15] = 8'h00;
        ascii_rom[12'hE16] = 8'h00;
        ascii_rom[12'hE17] = 8'h00;
        ascii_rom[12'hE18] = 8'h00;
        ascii_rom[12'hE19] = 8'h00;
        ascii_rom[12'hE1A] = 8'h00;
        ascii_rom[12'hE1B] = 8'h00;
        ascii_rom[12'hE1C] = 8'h00;
        ascii_rom[12'hE1D] = 8'h00;
        ascii_rom[12'hE1E] = 8'h00;
        ascii_rom[12'hE1F] = 8'h00;
        // 0xE2 -
        ascii_rom[12'hE20] = 8'h00;
        ascii_rom[12'hE21] = 8'h00;
        ascii_rom[12'hE22] = 8'h00;
        ascii_rom[12'hE23] = 8'h00;
        ascii_rom[12'hE24] = 8'h00;
        ascii_rom[12'hE25] = 8'h00;
        ascii_rom[12'hE26] = 8'h00;
        ascii_rom[12'hE27] = 8'h00;
        ascii_rom[12'hE28] = 8'h00;
        ascii_rom[12'hE29] = 8'h00;
        ascii_rom[12'hE2A] = 8'h00;
        ascii_rom[12'hE2B] = 8'h00;
        ascii_rom[12'hE2C] = 8'h00;
        ascii_rom[12'hE2D] = 8'h00;
        ascii_rom[12'hE2E] = 8'h00;
        ascii_rom[12'hE2F] = 8'h00;
        // 0xE3 -
        ascii_rom[12'hE30] = 8'h00;
        ascii_rom[12'hE31] = 8'h00;
        ascii_rom[12'hE32] = 8'h00;
        ascii_rom[12'hE33] = 8'h00;
        ascii_rom[12'hE34] = 8'h00;
        ascii_rom[12'hE35] = 8'h00;
        ascii_rom[12'hE36] = 8'h00;
        ascii_rom[12'hE37] = 8'h00;
        ascii_rom[12'hE38] = 8'h00;
        ascii_rom[12'hE39] = 8'h00;
        ascii_rom[12'hE3A] = 8'h00;
        ascii_rom[12'hE3B] = 8'h00;
        ascii_rom[12'hE3C] = 8'h00;
        ascii_rom[12'hE3D] = 8'h00;
        ascii_rom[12'hE3E] = 8'h00;
        ascii_rom[12'hE3F] = 8'h00;
        // 0xE4 -
        ascii_rom[12'hE40] = 8'h00;
        ascii_rom[12'hE41] = 8'h00;
        ascii_rom[12'hE42] = 8'h00;
        ascii_rom[12'hE43] = 8'h00;
        ascii_rom[12'hE44] = 8'h00;
        ascii_rom[12'hE45] = 8'h00;
        ascii_rom[12'hE46] = 8'h00;
        ascii_rom[12'hE47] = 8'h00;
        ascii_rom[12'hE48] = 8'h00;
        ascii_rom[12'hE49] = 8'h00;
        ascii_rom[12'hE4A] = 8'h00;
        ascii_rom[12'hE4B] = 8'h00;
        ascii_rom[12'hE4C] = 8'h00;
        ascii_rom[12'hE4D] = 8'h00;
        ascii_rom[12'hE4E] = 8'h00;
        ascii_rom[12'hE4F] = 8'h00;
        // 0xE5 -
        ascii_rom[12'hE50] = 8'h00;
        ascii_rom[12'hE51] = 8'h00;
        ascii_rom[12'hE52] = 8'h00;
        ascii_rom[12'hE53] = 8'h00;
        ascii_rom[12'hE54] = 8'h00;
        ascii_rom[12'hE55] = 8'h00;
        ascii_rom[12'hE56] = 8'h00;
        ascii_rom[12'hE57] = 8'h00;
        ascii_rom[12'hE58] = 8'h00;
        ascii_rom[12'hE59] = 8'h00;
        ascii_rom[12'hE5A] = 8'h00;
        ascii_rom[12'hE5B] = 8'h00;
        ascii_rom[12'hE5C] = 8'h00;
        ascii_rom[12'hE5D] = 8'h00;
        ascii_rom[12'hE5E] = 8'h00;
        ascii_rom[12'hE5F] = 8'h00;
        // 0xE6 -
        ascii_rom[12'hE60] = 8'h00;
        ascii_rom[12'hE61] = 8'h00;
        ascii_rom[12'hE62] = 8'h00;
        ascii_rom[12'hE63] = 8'h00;
        ascii_rom[12'hE64] = 8'h00;
        ascii_rom[12'hE65] = 8'h00;
        ascii_rom[12'hE66] = 8'h00;
        ascii_rom[12'hE67] = 8'h00;
        ascii_rom[12'hE68] = 8'h00;
        ascii_rom[12'hE69] = 8'h00;
        ascii_rom[12'hE6A] = 8'h00;
        ascii_rom[12'hE6B] = 8'h00;
        ascii_rom[12'hE6C] = 8'h00;
        ascii_rom[12'hE6D] = 8'h00;
        ascii_rom[12'hE6E] = 8'h00;
        ascii_rom[12'hE6F] = 8'h00;
        // 0xE7 -
        ascii_rom[12'hE70] = 8'h00;
        ascii_rom[12'hE71] = 8'h00;
        ascii_rom[12'hE72] = 8'h00;
        ascii_rom[12'hE73] = 8'h00;
        ascii_rom[12'hE74] = 8'h00;
        ascii_rom[12'hE75] = 8'h00;
        ascii_rom[12'hE76] = 8'h00;
        ascii_rom[12'hE77] = 8'h00;
        ascii_rom[12'hE78] = 8'h00;
        ascii_rom[12'hE79] = 8'h00;
        ascii_rom[12'hE7A] = 8'h00;
        ascii_rom[12'hE7B] = 8'h00;
        ascii_rom[12'hE7C] = 8'h00;
        ascii_rom[12'hE7D] = 8'h00;
        ascii_rom[12'hE7E] = 8'h00;
        ascii_rom[12'hE7F] = 8'h00;
        // 0xE8 -
        ascii_rom[12'hE80] = 8'h00;
        ascii_rom[12'hE81] = 8'h00;
        ascii_rom[12'hE82] = 8'h00;
        ascii_rom[12'hE83] = 8'h00;
        ascii_rom[12'hE84] = 8'h00;
        ascii_rom[12'hE85] = 8'h00;
        ascii_rom[12'hE86] = 8'h00;
        ascii_rom[12'hE87] = 8'h00;
        ascii_rom[12'hE88] = 8'h00;
        ascii_rom[12'hE89] = 8'h00;
        ascii_rom[12'hE8A] = 8'h00;
        ascii_rom[12'hE8B] = 8'h00;
        ascii_rom[12'hE8C] = 8'h00;
        ascii_rom[12'hE8D] = 8'h00;
        ascii_rom[12'hE8E] = 8'h00;
        ascii_rom[12'hE8F] = 8'h00;
        // 0xE9 -
        ascii_rom[12'hE90] = 8'h00;
        ascii_rom[12'hE91] = 8'h00;
        ascii_rom[12'hE92] = 8'h00;
        ascii_rom[12'hE93] = 8'h00;
        ascii_rom[12'hE94] = 8'h00;
        ascii_rom[12'hE95] = 8'h00;
        ascii_rom[12'hE96] = 8'h00;
        ascii_rom[12'hE97] = 8'h00;
        ascii_rom[12'hE98] = 8'h00;
        ascii_rom[12'hE99] = 8'h00;
        ascii_rom[12'hE9A] = 8'h00;
        ascii_rom[12'hE9B] = 8'h00;
        ascii_rom[12'hE9C] = 8'h00;
        ascii_rom[12'hE9D] = 8'h00;
        ascii_rom[12'hE9E] = 8'h00;
        ascii_rom[12'hE9F] = 8'h00;
        // 0xEA -
        ascii_rom[12'hEA0] = 8'h00;
        ascii_rom[12'hEA1] = 8'h00;
        ascii_rom[12'hEA2] = 8'h00;
        ascii_rom[12'hEA3] = 8'h00;
        ascii_rom[12'hEA4] = 8'h00;
        ascii_rom[12'hEA5] = 8'h00;
        ascii_rom[12'hEA6] = 8'h00;
        ascii_rom[12'hEA7] = 8'h00;
        ascii_rom[12'hEA8] = 8'h00;
        ascii_rom[12'hEA9] = 8'h00;
        ascii_rom[12'hEAA] = 8'h00;
        ascii_rom[12'hEAB] = 8'h00;
        ascii_rom[12'hEAC] = 8'h00;
        ascii_rom[12'hEAD] = 8'h00;
        ascii_rom[12'hEAE] = 8'h00;
        ascii_rom[12'hEAF] = 8'h00;
        // 0xEB -
        ascii_rom[12'hEB0] = 8'h00;
        ascii_rom[12'hEB1] = 8'h00;
        ascii_rom[12'hEB2] = 8'h00;
        ascii_rom[12'hEB3] = 8'h00;
        ascii_rom[12'hEB4] = 8'h00;
        ascii_rom[12'hEB5] = 8'h00;
        ascii_rom[12'hEB6] = 8'h00;
        ascii_rom[12'hEB7] = 8'h00;
        ascii_rom[12'hEB8] = 8'h00;
        ascii_rom[12'hEB9] = 8'h00;
        ascii_rom[12'hEBA] = 8'h00;
        ascii_rom[12'hEBB] = 8'h00;
        ascii_rom[12'hEBC] = 8'h00;
        ascii_rom[12'hEBD] = 8'h00;
        ascii_rom[12'hEBE] = 8'h00;
        ascii_rom[12'hEBF] = 8'h00;
        // 0xEC -
        ascii_rom[12'hEC0] = 8'h00;
        ascii_rom[12'hEC1] = 8'h00;
        ascii_rom[12'hEC2] = 8'h00;
        ascii_rom[12'hEC3] = 8'h00;
        ascii_rom[12'hEC4] = 8'h00;
        ascii_rom[12'hEC5] = 8'h00;
        ascii_rom[12'hEC6] = 8'h00;
        ascii_rom[12'hEC7] = 8'h00;
        ascii_rom[12'hEC8] = 8'h00;
        ascii_rom[12'hEC9] = 8'h00;
        ascii_rom[12'hECA] = 8'h00;
        ascii_rom[12'hECB] = 8'h00;
        ascii_rom[12'hECC] = 8'h00;
        ascii_rom[12'hECD] = 8'h00;
        ascii_rom[12'hECE] = 8'h00;
        ascii_rom[12'hECF] = 8'h00;
        // 0xED -
        ascii_rom[12'hED0] = 8'h00;
        ascii_rom[12'hED1] = 8'h00;
        ascii_rom[12'hED2] = 8'h00;
        ascii_rom[12'hED3] = 8'h00;
        ascii_rom[12'hED4] = 8'h00;
        ascii_rom[12'hED5] = 8'h00;
        ascii_rom[12'hED6] = 8'h00;
        ascii_rom[12'hED7] = 8'h00;
        ascii_rom[12'hED8] = 8'h00;
        ascii_rom[12'hED9] = 8'h00;
        ascii_rom[12'hEDA] = 8'h00;
        ascii_rom[12'hEDB] = 8'h00;
        ascii_rom[12'hEDC] = 8'h00;
        ascii_rom[12'hEDD] = 8'h00;
        ascii_rom[12'hEDE] = 8'h00;
        ascii_rom[12'hEDF] = 8'h00;
        // 0xEE -
        ascii_rom[12'hEE0] = 8'h00;
        ascii_rom[12'hEE1] = 8'h00;
        ascii_rom[12'hEE2] = 8'h00;
        ascii_rom[12'hEE3] = 8'h00;
        ascii_rom[12'hEE4] = 8'h00;
        ascii_rom[12'hEE5] = 8'h00;
        ascii_rom[12'hEE6] = 8'h00;
        ascii_rom[12'hEE7] = 8'h00;
        ascii_rom[12'hEE8] = 8'h00;
        ascii_rom[12'hEE9] = 8'h00;
        ascii_rom[12'hEEA] = 8'h00;
        ascii_rom[12'hEEB] = 8'h00;
        ascii_rom[12'hEEC] = 8'h00;
        ascii_rom[12'hEED] = 8'h00;
        ascii_rom[12'hEEE] = 8'h00;
        ascii_rom[12'hEEF] = 8'h00;
        // 0xEF -
        ascii_rom[12'hEF0] = 8'h00;
        ascii_rom[12'hEF1] = 8'h00;
        ascii_rom[12'hEF2] = 8'h00;
        ascii_rom[12'hEF3] = 8'h00;
        ascii_rom[12'hEF4] = 8'h00;
        ascii_rom[12'hEF5] = 8'h00;
        ascii_rom[12'hEF6] = 8'h00;
        ascii_rom[12'hEF7] = 8'h00;
        ascii_rom[12'hEF8] = 8'h00;
        ascii_rom[12'hEF9] = 8'h00;
        ascii_rom[12'hEFA] = 8'h00;
        ascii_rom[12'hEFB] = 8'h00;
        ascii_rom[12'hEFC] = 8'h00;
        ascii_rom[12'hEFD] = 8'h00;
        ascii_rom[12'hEFE] = 8'h00;
        ascii_rom[12'hEFF] = 8'h00;
        // 0xF0 -
        ascii_rom[12'hF00] = 8'h00;
        ascii_rom[12'hF01] = 8'h00;
        ascii_rom[12'hF02] = 8'h00;
        ascii_rom[12'hF03] = 8'h00;
        ascii_rom[12'hF04] = 8'h00;
        ascii_rom[12'hF05] = 8'h00;
        ascii_rom[12'hF06] = 8'h00;
        ascii_rom[12'hF07] = 8'h00;
        ascii_rom[12'hF08] = 8'h00;
        ascii_rom[12'hF09] = 8'h00;
        ascii_rom[12'hF0A] = 8'h00;
        ascii_rom[12'hF0B] = 8'h00;
        ascii_rom[12'hF0C] = 8'h00;
        ascii_rom[12'hF0D] = 8'h00;
        ascii_rom[12'hF0E] = 8'h00;
        ascii_rom[12'hF0F] = 8'h00;
        // 0xF1 -
        ascii_rom[12'hF10] = 8'h00;
        ascii_rom[12'hF11] = 8'h00;
        ascii_rom[12'hF12] = 8'h00;
        ascii_rom[12'hF13] = 8'h00;
        ascii_rom[12'hF14] = 8'h00;
        ascii_rom[12'hF15] = 8'h00;
        ascii_rom[12'hF16] = 8'h00;
        ascii_rom[12'hF17] = 8'h00;
        ascii_rom[12'hF18] = 8'h00;
        ascii_rom[12'hF19] = 8'h00;
        ascii_rom[12'hF1A] = 8'h00;
        ascii_rom[12'hF1B] = 8'h00;
        ascii_rom[12'hF1C] = 8'h00;
        ascii_rom[12'hF1D] = 8'h00;
        ascii_rom[12'hF1E] = 8'h00;
        ascii_rom[12'hF1F] = 8'h00;
        // 0xF2 -
        ascii_rom[12'hF20] = 8'h00;
        ascii_rom[12'hF21] = 8'h00;
        ascii_rom[12'hF22] = 8'h00;
        ascii_rom[12'hF23] = 8'h00;
        ascii_rom[12'hF24] = 8'h00;
        ascii_rom[12'hF25] = 8'h00;
        ascii_rom[12'hF26] = 8'h00;
        ascii_rom[12'hF27] = 8'h00;
        ascii_rom[12'hF28] = 8'h00;
        ascii_rom[12'hF29] = 8'h00;
        ascii_rom[12'hF2A] = 8'h00;
        ascii_rom[12'hF2B] = 8'h00;
        ascii_rom[12'hF2C] = 8'h00;
        ascii_rom[12'hF2D] = 8'h00;
        ascii_rom[12'hF2E] = 8'h00;
        ascii_rom[12'hF2F] = 8'h00;
        // 0xF3 -
        ascii_rom[12'hF30] = 8'h00;
        ascii_rom[12'hF31] = 8'h00;
        ascii_rom[12'hF32] = 8'h00;
        ascii_rom[12'hF33] = 8'h00;
        ascii_rom[12'hF34] = 8'h00;
        ascii_rom[12'hF35] = 8'h00;
        ascii_rom[12'hF36] = 8'h00;
        ascii_rom[12'hF37] = 8'h00;
        ascii_rom[12'hF38] = 8'h00;
        ascii_rom[12'hF39] = 8'h00;
        ascii_rom[12'hF3A] = 8'h00;
        ascii_rom[12'hF3B] = 8'h00;
        ascii_rom[12'hF3C] = 8'h00;
        ascii_rom[12'hF3D] = 8'h00;
        ascii_rom[12'hF3E] = 8'h00;
        ascii_rom[12'hF3F] = 8'h00;
        // 0xF4 -
        ascii_rom[12'hF40] = 8'h00;
        ascii_rom[12'hF41] = 8'h00;
        ascii_rom[12'hF42] = 8'h00;
        ascii_rom[12'hF43] = 8'h00;
        ascii_rom[12'hF44] = 8'h00;
        ascii_rom[12'hF45] = 8'h00;
        ascii_rom[12'hF46] = 8'h00;
        ascii_rom[12'hF47] = 8'h00;
        ascii_rom[12'hF48] = 8'h00;
        ascii_rom[12'hF49] = 8'h00;
        ascii_rom[12'hF4A] = 8'h00;
        ascii_rom[12'hF4B] = 8'h00;
        ascii_rom[12'hF4C] = 8'h00;
        ascii_rom[12'hF4D] = 8'h00;
        ascii_rom[12'hF4E] = 8'h00;
        ascii_rom[12'hF4F] = 8'h00;
        // 0xF5 -
        ascii_rom[12'hF50] = 8'h00;
        ascii_rom[12'hF51] = 8'h00;
        ascii_rom[12'hF52] = 8'h00;
        ascii_rom[12'hF53] = 8'h00;
        ascii_rom[12'hF54] = 8'h00;
        ascii_rom[12'hF55] = 8'h00;
        ascii_rom[12'hF56] = 8'h00;
        ascii_rom[12'hF57] = 8'h00;
        ascii_rom[12'hF58] = 8'h00;
        ascii_rom[12'hF59] = 8'h00;
        ascii_rom[12'hF5A] = 8'h00;
        ascii_rom[12'hF5B] = 8'h00;
        ascii_rom[12'hF5C] = 8'h00;
        ascii_rom[12'hF5D] = 8'h00;
        ascii_rom[12'hF5E] = 8'h00;
        ascii_rom[12'hF5F] = 8'h00;
        // 0xF6 -
        ascii_rom[12'hF60] = 8'h00;
        ascii_rom[12'hF61] = 8'h00;
        ascii_rom[12'hF62] = 8'h00;
        ascii_rom[12'hF63] = 8'h00;
        ascii_rom[12'hF64] = 8'h00;
        ascii_rom[12'hF65] = 8'h00;
        ascii_rom[12'hF66] = 8'h00;
        ascii_rom[12'hF67] = 8'h00;
        ascii_rom[12'hF68] = 8'h00;
        ascii_rom[12'hF69] = 8'h00;
        ascii_rom[12'hF6A] = 8'h00;
        ascii_rom[12'hF6B] = 8'h00;
        ascii_rom[12'hF6C] = 8'h00;
        ascii_rom[12'hF6D] = 8'h00;
        ascii_rom[12'hF6E] = 8'h00;
        ascii_rom[12'hF6F] = 8'h00;
        // 0xF7 -
        ascii_rom[12'hF70] = 8'h00;
        ascii_rom[12'hF71] = 8'h00;
        ascii_rom[12'hF72] = 8'h00;
        ascii_rom[12'hF73] = 8'h00;
        ascii_rom[12'hF74] = 8'h00;
        ascii_rom[12'hF75] = 8'h00;
        ascii_rom[12'hF76] = 8'h00;
        ascii_rom[12'hF77] = 8'h00;
        ascii_rom[12'hF78] = 8'h00;
        ascii_rom[12'hF79] = 8'h00;
        ascii_rom[12'hF7A] = 8'h00;
        ascii_rom[12'hF7B] = 8'h00;
        ascii_rom[12'hF7C] = 8'h00;
        ascii_rom[12'hF7D] = 8'h00;
        ascii_rom[12'hF7E] = 8'h00;
        ascii_rom[12'hF7F] = 8'h00;
        // 0xF8 -
        ascii_rom[12'hF80] = 8'h00;
        ascii_rom[12'hF81] = 8'h00;
        ascii_rom[12'hF82] = 8'h00;
        ascii_rom[12'hF83] = 8'h00;
        ascii_rom[12'hF84] = 8'h00;
        ascii_rom[12'hF85] = 8'h00;
        ascii_rom[12'hF86] = 8'h00;
        ascii_rom[12'hF87] = 8'h00;
        ascii_rom[12'hF88] = 8'h00;
        ascii_rom[12'hF89] = 8'h00;
        ascii_rom[12'hF8A] = 8'h00;
        ascii_rom[12'hF8B] = 8'h00;
        ascii_rom[12'hF8C] = 8'h00;
        ascii_rom[12'hF8D] = 8'h00;
        ascii_rom[12'hF8E] = 8'h00;
        ascii_rom[12'hF8F] = 8'h00;
        // 0xF9 -
        ascii_rom[12'hF90] = 8'h00;
        ascii_rom[12'hF91] = 8'h00;
        ascii_rom[12'hF92] = 8'h00;
        ascii_rom[12'hF93] = 8'h00;
        ascii_rom[12'hF94] = 8'h00;
        ascii_rom[12'hF95] = 8'h00;
        ascii_rom[12'hF96] = 8'h00;
        ascii_rom[12'hF97] = 8'h00;
        ascii_rom[12'hF98] = 8'h00;
        ascii_rom[12'hF99] = 8'h00;
        ascii_rom[12'hF9A] = 8'h00;
        ascii_rom[12'hF9B] = 8'h00;
        ascii_rom[12'hF9C] = 8'h00;
        ascii_rom[12'hF9D] = 8'h00;
        ascii_rom[12'hF9E] = 8'h00;
        ascii_rom[12'hF9F] = 8'h00;
        // 0xFA -
        ascii_rom[12'hFA0] = 8'h00;
        ascii_rom[12'hFA1] = 8'h00;
        ascii_rom[12'hFA2] = 8'h00;
        ascii_rom[12'hFA3] = 8'h00;
        ascii_rom[12'hFA4] = 8'h00;
        ascii_rom[12'hFA5] = 8'h00;
        ascii_rom[12'hFA6] = 8'h00;
        ascii_rom[12'hFA7] = 8'h00;
        ascii_rom[12'hFA8] = 8'h00;
        ascii_rom[12'hFA9] = 8'h00;
        ascii_rom[12'hFAA] = 8'h00;
        ascii_rom[12'hFAB] = 8'h00;
        ascii_rom[12'hFAC] = 8'h00;
        ascii_rom[12'hFAD] = 8'h00;
        ascii_rom[12'hFAE] = 8'h00;
        ascii_rom[12'hFAF] = 8'h00;
        // 0xFB -
        ascii_rom[12'hFB0] = 8'h00;
        ascii_rom[12'hFB1] = 8'h00;
        ascii_rom[12'hFB2] = 8'h00;
        ascii_rom[12'hFB3] = 8'h00;
        ascii_rom[12'hFB4] = 8'h00;
        ascii_rom[12'hFB5] = 8'h00;
        ascii_rom[12'hFB6] = 8'h00;
        ascii_rom[12'hFB7] = 8'h00;
        ascii_rom[12'hFB8] = 8'h00;
        ascii_rom[12'hFB9] = 8'h00;
        ascii_rom[12'hFBA] = 8'h00;
        ascii_rom[12'hFBB] = 8'h00;
        ascii_rom[12'hFBC] = 8'h00;
        ascii_rom[12'hFBD] = 8'h00;
        ascii_rom[12'hFBE] = 8'h00;
        ascii_rom[12'hFBF] = 8'h00;
        // 0xFC -
        ascii_rom[12'hFC0] = 8'h00;
        ascii_rom[12'hFC1] = 8'h00;
        ascii_rom[12'hFC2] = 8'h00;
        ascii_rom[12'hFC3] = 8'h00;
        ascii_rom[12'hFC4] = 8'h00;
        ascii_rom[12'hFC5] = 8'h00;
        ascii_rom[12'hFC6] = 8'h00;
        ascii_rom[12'hFC7] = 8'h00;
        ascii_rom[12'hFC8] = 8'h00;
        ascii_rom[12'hFC9] = 8'h00;
        ascii_rom[12'hFCA] = 8'h00;
        ascii_rom[12'hFCB] = 8'h00;
        ascii_rom[12'hFCC] = 8'h00;
        ascii_rom[12'hFCD] = 8'h00;
        ascii_rom[12'hFCE] = 8'h00;
        ascii_rom[12'hFCF] = 8'h00;
        // 0xFD -
        ascii_rom[12'hFD0] = 8'h00;
        ascii_rom[12'hFD1] = 8'h00;
        ascii_rom[12'hFD2] = 8'h00;
        ascii_rom[12'hFD3] = 8'h00;
        ascii_rom[12'hFD4] = 8'h00;
        ascii_rom[12'hFD5] = 8'h00;
        ascii_rom[12'hFD6] = 8'h00;
        ascii_rom[12'hFD7] = 8'h00;
        ascii_rom[12'hFD8] = 8'h00;
        ascii_rom[12'hFD9] = 8'h00;
        ascii_rom[12'hFDA] = 8'h00;
        ascii_rom[12'hFDB] = 8'h00;
        ascii_rom[12'hFDC] = 8'h00;
        ascii_rom[12'hFDD] = 8'h00;
        ascii_rom[12'hFDE] = 8'h00;
        ascii_rom[12'hFDF] = 8'h00;
        // 0xFE -
        ascii_rom[12'hFE0] = 8'h00;
        ascii_rom[12'hFE1] = 8'h00;
        ascii_rom[12'hFE2] = 8'h00;
        ascii_rom[12'hFE3] = 8'h00;
        ascii_rom[12'hFE4] = 8'h00;
        ascii_rom[12'hFE5] = 8'h00;
        ascii_rom[12'hFE6] = 8'h00;
        ascii_rom[12'hFE7] = 8'h00;
        ascii_rom[12'hFE8] = 8'h00;
        ascii_rom[12'hFE9] = 8'h00;
        ascii_rom[12'hFEA] = 8'h00;
        ascii_rom[12'hFEB] = 8'h00;
        ascii_rom[12'hFEC] = 8'h00;
        ascii_rom[12'hFED] = 8'h00;
        ascii_rom[12'hFEE] = 8'h00;
        ascii_rom[12'hFEF] = 8'h00;
        // 0xFF -
        ascii_rom[12'hFF0] = 8'h00;
        ascii_rom[12'hFF1] = 8'h00;
        ascii_rom[12'hFF2] = 8'h00;
        ascii_rom[12'hFF3] = 8'h00;
        ascii_rom[12'hFF4] = 8'h00;
        ascii_rom[12'hFF5] = 8'h00;
        ascii_rom[12'hFF6] = 8'h00;
        ascii_rom[12'hFF7] = 8'h00;
        ascii_rom[12'hFF8] = 8'h00;
        ascii_rom[12'hFF9] = 8'h00;
        ascii_rom[12'hFFA] = 8'h00;
        ascii_rom[12'hFFB] = 8'h00;
        ascii_rom[12'hFFC] = 8'h00;
        ascii_rom[12'hFFD] = 8'h00;
        ascii_rom[12'hFFE] = 8'h00;
        ascii_rom[12'hFFF] = 8'h00;
    end

    // ---- render-side ASCII read port -------------------------------------
    // Address pre-issued EXACTLY like glyph_ram's (xrd/yrd = next pixel),
    // read in the same always block on the same beat.  The band select uses
    // the NEXT pixel's line_sel (dyr[5]) so the word that lands during
    // pixel P is P's own glyph: LINE0 band -> ch_r (44:1 constant mux),
    // MSG band -> left byte of the next slot's code (msg_flat_c, whose
    // only reader is here -- msg_flat_a stays the current-pixel reader,
    // msg_flat_b stays the FSM's).  Both old call sites (glyph / mglyph8)
    // are active in disjoint line bands, so ONE reader/word serves both;
    // rgb_out stays zero-delay, top-level timing unchanged.
    wire [3:0]  glyph_row_r = dyr[4:1];                  // next pixel's glyph row
    wire        line_sel_r  = dyr[5];                    // next pixel's band
    wire [5:0]  cx_r    = (cixr >= MAX_CHARS) ? (MAX_CHARS - 6'd1) : cixr;
    wire [8:0]  cbase_r = ({3'd0, MAX_CHARS} - 9'd1 - {3'd0, cx_r}) * 9'd8; // v1-proven mapping
    wire [7:0]  ch_r    = LINE0_TEXT[cbase_r +: 8];
    wire [8:0]  mbase_r = 9'd336 - {slotr, 4'd0};
    wire [15:0] mcode_r = msg_flat_c[mbase_r +: 16];
    wire [11:0] ascii_raddr = line_sel_r ? {mcode_r[7:0], glyph_row_r}
                                         : {ch_r,          glyph_row_r};
    reg  [7:0]  ascii_q;

    always @(posedge clk) begin
        rd_word <= glyph_ram[rd_addr];                    // 1R1W sync read
        ascii_q <= ascii_rom[ascii_raddr];                // v8: ROM sync read, same pre-issued beat
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

    // §4 address: qu=hi-A1, wei=lo-A1, addr=((qu*94)+wei)*32  (实测最大 0x45C40 < 2^19, 19b——WP-J 全域审计)
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
    // v8: the old glyph8x16() 4096-entry combinational case ROM is GONE --
    // replaced by the ascii_rom BRAM + pre-issued sync read above (render-side
    // ASCII read port), bit-identical data and semantics.
    // ------------------------------------------------------------------------

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

    // v8: LINE0 glyph now arrives from ascii_rom (ch_r mux pre-issued one
    // pixel ahead, see render-side ASCII read port) -- word valid THIS pixel.
    wire [7:0]  glyph   = ascii_q;
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
    // 8x16 BRAM ROM (ascii_q, same pre-issued pipeline as rd_word) drawn in
    // the slot's LEFT 8px (right 8px blank); full-width =
    // rd_word (the 1R1W BRAM word, pre-issued one pixel ahead) tested
    // bit-parallel, bit15 = cell column 0; empty/out-of-range = background.
    wire [9:0]  mcx       = msg_wrap(x[9:0]);              // v10.3 scrolled current MSG x
    wire [5:0]  mcell     = mcx[9:4];
    wire        cell_ok   = (mcell < 6'd22);
    wire [5:0]  mx        = cell_ok ? mcell : 6'd21;
    wire [8:0]  mbase     = 9'd336 - {mx[4:0], 4'd0};
    wire [15:0] mcode     = msg_flat_a[mbase +: 16];
    wire        m_half    = (mcode[15:8] == 8'h00) && (mcode[7:0] != 8'h00);
    wire        m_full    = (mcode[15:8] >= 8'hA1) && (mcode[7:0] >= 8'hA1);
    wire [7:0]  mglyph8   = ascii_q;  // v8: same word, MSG band (mcode_r pre-issued)
    wire        m_half_on = !mcx[3] && |(mglyph8 & (8'h80 >> mcx[2:0])); // LEFT 8px only
    wire        m_full_on = |(rd_word  & (16'h8000 >> mcx[3:0]));  // bit15 = leftmost
    wire        msg_on    = line_sel && cell_ok
                          && ((m_half && m_half_on) || (m_full && m_full_on));

    wire         text_on  = row0_emg ? cjk_on
                       :  line_sel   ? msg_on
                       :               |(glyph & mask);

    // background: each 8-bit channel x 0.5 (shift only)
    // v5c: emergency = red text (international alert convention), normal = user
    // palette (v7.2 "COL": 0 white,1 red,2 green,3 yellow,4 cyan,5 magenta,6 blue,7 orange)
    // v10.1: 应急默红可解锁——进 EMG 上升沿重新锁红；应急中用户发 COL 即放行调色板。
    // （golden 对拍台不驱动 col_exec -> 恒 0 -> 行为与 v9.2 逐拍等价，兼容 WP-J 资产。）
    wire [23:0] pal_col =
          (txt_col_sel==3'd0) ? 24'hFFFFFF :
          (txt_col_sel==3'd1) ? 24'hFF3030 :
          (txt_col_sel==3'd2) ? 24'h40FF70 :
          (txt_col_sel==3'd3) ? 24'hFFE000 :
          (txt_col_sel==3'd4) ? 24'h40E0FF :
          (txt_col_sel==3'd5) ? 24'hFF50C8 :
          (txt_col_sel==3'd6) ? 24'h60A0FF :
                                24'hFF9040;               // 7 = orange
    wire [23:0] tcol = (emg_mode && !col_unlock) ? 24'hFF3030 : pal_col;
    // v10.1 lock register: EMG entry rising edge re-locks red; a user "COL" unlocks.
    reg  col_unlock;
    reg  emg_mode_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_unlock <= 1'b0;
            emg_mode_d <= 1'b0;
        end else begin
            emg_mode_d <= emg_mode;
            if (emg_mode && !emg_mode_d)      col_unlock <= 1'b0;  // 进应急：重新默红
            else if (col_exec)                col_unlock <= 1'b1;  // 用户 COL：解锁
        end
    end
    wire [23:0] bg_dark = { {1'b0, rgb_in[23:17]},
                            {1'b0, rgb_in[15:9]},
                            {1'b0, rgb_in[7:1]}  };

    assign rgb_out = !in_banner ? rgb_in
                   :  text_on   ? tcol
                   :              bg_dark;

endmodule

`default_nettype wire
