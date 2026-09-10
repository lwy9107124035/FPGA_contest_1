`timescale 1 ns / 1 ps
// =============================================================================
// uart_loader.v — LOAD 协议 v1 帧组装 + 会话编排 (clk50 域)
//                 第十届(2026)嵌入式竞赛 FPGA 赛题一 · OSD 中文字库软装载
//
// 上游 (top 集成, 协议 §6, 本模块不管): msg_ink 收 "LOAD\n" → loader_start
//   1 拍脉冲 + 把 uart_rx 字节流在本信号有效期间路由到 rx_byte/rx_vld;
//   tx 通道按 ld_tx_* 与 msg_ink 二选一仲裁。
//
// 会话流程 (协议 §2/§3/§4):
//   loader_start → 回 "RDY\r\n" → 连发 5 个 64K 块擦 (0x00000/0x10000/
//   0x20000/0x30000/0x40000, 逐个等 flash_pp done) → 回 "ERASED\r\n" →
//   开始吃二进制帧:
//     A5 01 LEN16(大端) payload(≤256B, 直写 flash_pp.pbuf) CRC16(大端)
//     · 逐字节在线算 CRC16-CCITT(多项式 0x1021/不反转), **初值按主线裁决取
//       0x0000**(自检向量 CRC16-CCITT("123456789")==0x31C3 为权威; 留痕见
//       LOAD_IMPL_NOTES.md §4" CRC init 裁决=0x0000（向量权威）"),
//       覆盖 byte0..payload 末, 与末 2 字节比较; 错 → "CERR\r\n"(帧末字节
//       收齐后 ≤2ms 内发出, 走 B2 快速通道; 连错 3 次再 "ABORT\r\n" 退出),
//       并回滚到达偏移计数器, 等 PC 重发本帧。
//     · 任意 0<LEN≤256 均合法 (裁决2: 真实拆分为 1104 帧×256B + 1 帧
//       LEN=128 残帧; 协议 §5"1105×256 整除"系主线算术错误, 已裁决勘误)。
//     · 对 → 发 cmd=页编程 (addr=提交偏移 goff), 等 done; 每完成 40 帧插
//       一行 "P40\r\n"; 残帧 (LEN<256) 同样支持, goff 按 LEN 累加。
//     · 非帧头/错帧字节在等待帧头位置静默丢弃 (§2.3)。
//     · 任何一帧的帧头字节之后 >10s 无字节 → "TIMEOUT\r\n" 退出回文本
//       (29bit @50MHz, 只在帧收集阶段跑表; 擦除/编程等待各有 flash_pp
//       超时与定长事务兜底)。
//   LEN=0 结束帧 → 抽验: flash_pp cmd=读 0x00000 起 32B 对比 first32(镜像头
//   32B), 再读 (goff-32) 起 32B 对比 last32(滚动寄存的镜像末 32B) →
//   "DONE\r\n"/"BAD\r\n" → 回文本模式。尾地址**不硬编码**协议笔误 0x457E0,
//   按实际累计提交字节数 goff 动态算 (282752B 镜像时 = 282720 = 0x45060)。
// first32 按到达偏移 arr_off∈[0,32) case 抄写; last32 为每个 payload 字节
//   左移插入的滚动 256bit 寄存器 —— 都是普通寄存器(非数组, 无读口压力),
//   整字 256bit 比较, 与 "一拍一口" 铁律零冲突。CERR 帧回滚 arr_off;
//   last32 无需回滚 —— PC 重发同一帧会把正确字节再次移入, 自动复原。
//
// TD 数组铁律自查: 本模块**没有任何动态下标数组读**。pbuf 归 flash_pp 所有;
//   loader 只在收 payload 拍对 pbuf 做 1 次写 (pp_buf_we 打点脉冲), 写地址
//   每拍最多 1 个动态值。lbuf 不存在 (字节到即消费进 CRC/pbuf/快照)。
// =============================================================================
`default_nettype none

module uart_loader (
    input  wire         clk50,             // 50MHz 域 (与 flash_pp 同域)
    input  wire         I_rst,             // 高有效 (rst_all 风格)
    input  wire         loader_start,      // msg_ink 抢切脉冲 (1 clk)
    input  wire [7:0]   rx_byte,           // top 按 loader_active 路由的 RX
    input  wire         rx_vld,
    output reg          loader_active,     // 1 = 会话中, RX 应归 loader
    // —— 文本回执通道 (与 msg_ink 的 tx 握手同风格) ——
    output reg          ld_tx_start,
    output reg  [7:0]   ld_tx_byte,
    input  wire         ld_tx_done,        // 上一字节发完 (stop 位末) 1 拍脉冲
    // —— flash_pp 命令通道 (cmd 为 1 拍脉冲) ——
    output reg  [1:0]   fp_cmd,
    output reg  [23:0]  fp_addr,
    // —— flash_pp.pbuf 灌页通道 ——
    output reg          fp_buf_we,
    output reg  [7:0]   fp_buf_widx,
    output reg  [7:0]   fp_buf_wdata,
    // —— flash_pp 状态 ——
    input  wire         fp_busy,
    input  wire         fp_done,
    input  wire         fp_to,
    input  wire [255:0] fp_rd_q
);
    localparam [1:0] OP_ERASE = 2'd1, OP_PP = 2'd2, OP_READ = 2'd3;

    localparam        [28:0] FTO = 29'd500_000_000;           // 10s @50MHz

    // 回执行编码
    localparam [2:0] L_RDY=3'd0, L_ERASED=3'd1, L_CERR=3'd2, L_DONE=3'd3,
                     L_BAD=3'd4, L_TIMEOUT=3'd5, L_ABORT=3'd6, L_P40=3'd7;

    // 回执行字节 (文本行+CRLF, 协议 §3)
    function [7:0] ldb;
        input [2:0] c; input [3:0] i;
        reg [3:0] n;
    begin
        n = i;
        case (c)
            L_RDY:     ldb = (n==4'd0)?8'h52:(n==4'd1)?8'h44:(n==4'd2)?8'h59:
                         (n==4'd3)?8'h0D:8'h0A;                       // RDY
            L_ERASED:  ldb = (n==4'd0)?8'h45:(n==4'd1)?8'h52:(n==4'd2)?8'h41:
                         (n==4'd3)?8'h53:(n==4'd4)?8'h45:(n==4'd5)?8'h44:
                         (n==4'd6)?8'h0D:8'h0A;                       // ERASED
            L_CERR:    ldb = (n==4'd0)?8'h43:(n==4'd1)?8'h45:(n==4'd2)?8'h52:
                         (n==4'd3)?8'h52:(n==4'd4)?8'h0D:8'h0A;       // CERR
            L_DONE:    ldb = (n==4'd0)?8'h44:(n==4'd1)?8'h4F:(n==4'd2)?8'h4E:
                         (n==4'd3)?8'h45:(n==4'd4)?8'h0D:8'h0A;       // DONE
            L_BAD:     ldb = (n==4'd0)?8'h42:(n==4'd1)?8'h41:(n==4'd2)?8'h44:
                         (n==4'd3)?8'h0D:8'h0A;                       // BAD
            L_TIMEOUT: ldb = (n==4'd0)?8'h54:(n==4'd1)?8'h49:(n==4'd2)?8'h4D:
                         (n==4'd3)?8'h45:(n==4'd4)?8'h4F:(n==4'd5)?8'h55:
                         (n==4'd6)?8'h54:(n==4'd7)?8'h0D:8'h0A;       // TIMEOUT
            L_ABORT:   ldb = (n==4'd0)?8'h41:(n==4'd1)?8'h42:(n==4'd2)?8'h4F:
                         (n==4'd3)?8'h52:(n==4'd4)?8'h54:(n==4'd5)?8'h0D:8'h0A;
            default:   ldb = (n==4'd0)?8'h50:(n==4'd1)?8'h34:(n==4'd2)?8'h30:
                         (n==4'd3)?8'h0D:8'h0A;                       // P40
        endcase
    end
    endfunction

    function [3:0] lnl;                 // 行长 (含 CRLF)
        input [2:0] c;
    begin
        case (c)
            L_RDY:     lnl = 4'd5;
            L_ERASED:  lnl = 4'd8;
            L_CERR:    lnl = 4'd6;
            L_DONE:    lnl = 4'd6;
            L_BAD:     lnl = 4'd5;
            L_TIMEOUT: lnl = 4'd9;
            L_ABORT:   lnl = 4'd7;
            default:   lnl = 4'd5;      // P40
        endcase
    end
    endfunction

    // CRC16-CCITT (0x1021, 不反转; **初值 0x0000 —— 主线裁决, 自检向量
    // "123456789"==0x31C3 权威**, 见 NOTES §4): 逐 bit 组合函数, 无查表。
    function [15:0] crc_upd;
        input [15:0] crc_in; input [7:0] b;
        integer k;
    begin
        crc_upd = crc_in;
        for (k = 0; k <= 7; k = k + 1)
            if (crc_upd[15] ^ b[7-k])
                crc_upd = {crc_upd[14:0], 1'b0} ^ 16'h1021;
            else
                crc_upd = {crc_upd[14:0], 1'b0};
    end
    endfunction

    // —— 状态寄存器 ——
    // 帧收集机
    localparam [2:0] R_F0=3'd0, R_F1=3'd1, R_L1=3'd2, R_L0=3'd3,
                     R_PAY=3'd4, R_C1=3'd5, R_C0=3'd6;
    reg [2:0]  rxst;
    reg [15:0] crc, crc_rx, len_r, len_p;
    reg [7:0]  fix;
    reg [18:0] arr_off;                 // 到达偏移 (CERR 帧回滚)
    reg [1:0]  pend;                    // 0无 1数据帧好 2帧坏 3结束帧
    localparam [1:0] P_NONE=2'd0, P_DATA=2'd1, P_BAD=2'd2, P_END=2'd3;

    // 会话编排机
    localparam [3:0] ST_IDLE=4'd0, ST_LINE=4'd1, ST_ERASE=4'd2, ST_ERAW=4'd3,
                     ST_COLLECT=4'd4, ST_PPW=4'd5, ST_V0=4'd6, ST_V0W=4'd7,
                     ST_V1=4'd8, ST_V1W=4'd9, ST_EXIT=4'd10;
    reg [3:0]  st;
    reg [18:0] goff;                    // 已提交镜像偏移 (PP 目标地址)
    reg [8:0]  len_c;                   // 消费 pend 时锁存的帧长 (防 C0 覆写竞态)
    reg [2:0]  eix;                     // 擦除块 0..4
    reg [5:0]  f40;                     // P40 节拍 0..39
    reg [1:0]  cerr_n;                  // 连续帧错计数
    reg        rx_run, ft_ovf, abort_pend;
    reg [28:0] ft;

    // 文本行发送引擎
    reg        lreq, lbusy, tx_pend, line_done;
    reg [2:0]  lcode_n, lcode_r;
    reg [3:0]  lidx;

    // 抽验快照 (普通寄存器, 非数组)
    reg [255:0] first32, last32;

    wire [15:0] lenv = {len_r[15:8], rx_byte};   // L0 拍的全帧长
    wire [8:0]  fx1  = {1'b0, fix} + 9'd1;
    wire [8:0]  len9 = len_r[8:0];               // 已限长 ≤256, 低 9bit 够用

    always @(posedge clk50 or posedge I_rst) begin
        if (I_rst) begin
            st <= ST_IDLE; rxst <= R_F0;
            crc <= 16'h0000; crc_rx <= 16'h0; len_r <= 16'h0; len_p <= 16'h0;   // v5 裁决: init=0x0000 (XMODEM, 向量 0x31C3 权威)
            fix <= 8'd0; arr_off <= 19'd0; goff <= 19'd0;
            pend <= P_NONE; len_c <= 9'd0;
            eix <= 3'd0; f40 <= 6'd0; cerr_n <= 2'd0;
            rx_run <= 1'b0; ft <= 29'd0; ft_ovf <= 1'b0; abort_pend <= 1'b0;
            lreq <= 1'b0; lbusy <= 1'b0; tx_pend <= 1'b0; line_done <= 1'b0;
            lcode_n <= L_RDY; lcode_r <= L_RDY; lidx <= 4'd0;
            first32 <= 256'd0; last32 <= 256'd0;
            loader_active <= 1'b0;
            ld_tx_start <= 1'b0; ld_tx_byte <= 8'h00;
            fp_cmd <= 2'd0; fp_addr <= 24'd0;
            fp_buf_we <= 1'b0; fp_buf_widx <= 8'd0; fp_buf_wdata <= 8'h00;
        end else begin
            // 单拍脉冲缺省
            ld_tx_start <= 1'b0;
            fp_cmd      <= 2'd0;
            fp_buf_we   <= 1'b0;
            line_done   <= 1'b0;

            // ==========================================================
            // A) 帧收集机 (rx_run=1 才吃字节; 每拍最多 1 个 pbuf 写口动作)
            // ==========================================================
            if (rx_run) begin
                if (rx_vld) begin
                    ft <= 29'd0;
                    case (rxst)
                        R_F0: if (rx_byte == 8'hA5) begin
                                  crc    <= crc_upd(16'h0000, rx_byte);   // v5 裁决 init=0x0000 (见 LOAD_PROTOCOL §3 勘误)
                                  crc_rx <= 16'h0;
                                  fix    <= 8'd0;
                                  rxst   <= R_F1;
                              end                                       // 其余静默丢
                        R_F1: if (rx_byte == 8'h01) begin
                                  crc  <= crc_upd(crc, rx_byte);
                                  rxst <= R_L1;
                              end else begin
                                  pend <= P_BAD;   // 版本字节坏: 无 payload, 不回滚
                                  rxst <= R_F0;
                              end
                        R_L1: begin
                                  crc         <= crc_upd(crc, rx_byte);
                                  len_r[15:8] <= rx_byte;
                                  rxst        <= R_L0;
                              end
                        R_L0: begin
                                  crc    <= crc_upd(crc, rx_byte);
                                  len_r  <= lenv;
                                  if (lenv > 16'd256) begin
                                      pend <= P_BAD;                    // 非法帧长
                                      rxst <= R_F0;
                                  end else if (lenv == 16'd0) begin
                                      rxst <= R_C1;                     // 结束帧
                                  end else begin
                                      rxst <= R_PAY;
                                  end
                              end
                        R_PAY: begin
                                  crc          <= crc_upd(crc, rx_byte);
                                  fix          <= fix + 8'd1;
                                  arr_off      <= arr_off + 19'd1;
                                  // —— pbuf 灌页 (1 写/拍, 无读) ——
                                  fp_buf_we    <= 1'b1;
                                  fp_buf_widx  <= fix;
                                  fp_buf_wdata <= rx_byte;
                                  // —— 32B 抽验快照 (寄存器 case 写) ——
                                  if (arr_off < 19'd32)
                                      case (arr_off[4:0])
                                          5'd0:  first32[255:248] <= rx_byte;
                                          5'd1:  first32[247:240] <= rx_byte;
                                          5'd2:  first32[239:232] <= rx_byte;
                                          5'd3:  first32[231:224] <= rx_byte;
                                          5'd4:  first32[223:216] <= rx_byte;
                                          5'd5:  first32[215:208] <= rx_byte;
                                          5'd6:  first32[207:200] <= rx_byte;
                                          5'd7:  first32[199:192] <= rx_byte;
                                          5'd8:  first32[191:184] <= rx_byte;
                                          5'd9:  first32[183:176] <= rx_byte;
                                          5'd10: first32[175:168] <= rx_byte;
                                          5'd11: first32[167:160] <= rx_byte;
                                          5'd12: first32[159:152] <= rx_byte;
                                          5'd13: first32[151:144] <= rx_byte;
                                          5'd14: first32[143:136] <= rx_byte;
                                          5'd15: first32[135:128] <= rx_byte;
                                          5'd16: first32[127:120] <= rx_byte;
                                          5'd17: first32[119:112] <= rx_byte;
                                          5'd18: first32[111:104] <= rx_byte;
                                          5'd19: first32[103:96]  <= rx_byte;
                                          5'd20: first32[95:88]   <= rx_byte;
                                          5'd21: first32[87:80]   <= rx_byte;
                                          5'd22: first32[79:72]   <= rx_byte;
                                          5'd23: first32[71:64]   <= rx_byte;
                                          5'd24: first32[63:56]   <= rx_byte;
                                          5'd25: first32[55:48]   <= rx_byte;
                                          5'd26: first32[47:40]   <= rx_byte;
                                          5'd27: first32[39:32]   <= rx_byte;
                                          5'd28: first32[31:24]   <= rx_byte;
                                          5'd29: first32[23:16]   <= rx_byte;
                                          5'd30: first32[15:8]    <= rx_byte;
                                          default: first32[7:0]   <= rx_byte;
                                      endcase
                                       // (tail32 fixed-window logic removed per ruling 3)
                                  last32 <= {last32[247:0], rx_byte};  // rolling last-32B
                                  if (fx1 == len9) rxst <= R_C1;
                              end
                        R_C1: begin
                                  crc_rx <= {crc_rx[7:0], rx_byte};      // CRC hi
                                  rxst   <= R_C0;
                              end
                        R_C0: begin
                                  if ({crc_rx[7:0], rx_byte} == crc) begin
                                      len_p <= len_r;
                                      pend  <= (len_r == 16'd0) ? P_END : P_DATA;
                                  end else begin
                                      pend     <= P_BAD;
                                      arr_off  <= arr_off - len9;        // 回滚本帧
                                  end
                                  rxst <= R_F0;
                              end
                        default: rxst <= R_F0;
                    endcase
                end else if (!ft_ovf) begin
                    if (ft >= FTO) ft_ovf <= 1'b1;
                    else           ft      <= ft + 29'd1;
                end
            end

            // ==========================================================
            // B) 文本行发送引擎 (与 msg_ink st==3 同手法)
            // ==========================================================
            if (lreq && !lbusy) begin
                lbusy   <= 1'b1;
                lcode_r <= lcode_n;
                lidx    <= 4'd0;
                lreq    <= 1'b0;
            end
            if (lbusy && !tx_pend) begin
                ld_tx_start <= 1'b1;
                ld_tx_byte  <= ldb(lcode_r, lidx);
                tx_pend     <= 1'b1;
            end else if (lbusy && tx_pend && ld_tx_done) begin
                tx_pend <= 1'b0;
                if (lidx == lnl(lcode_r) - 4'd1) begin
                    lbusy     <= 1'b0;
                    line_done <= 1'b1;
                end else begin
                    lidx <= lidx + 4'd1;
                end
            end

            // ==========================================================
            // B2) 帧坏快速通道 (裁决4: 帧末字节收齐后 ≤2ms 必须发 CERR 行,
            //     PC 每帧只有 4ms 观察窗)。编排机即便在页编程/抽验等待态,
            //     也立即请行, 不等 fp_done; 行引擎本身与 seq 状态解耦。
            //     满 3 连错时置 abort_pend, ABORT 行在页编程收尾回来后由
            //     ST_COLLECT 头部补发 (ABORT 无 2ms 硬窗)。
            // ==========================================================
            if (pend == P_BAD && !lbusy && !lreq && !(fp_done && fp_to) &&
                (st == ST_PPW || st == ST_V0W || st == ST_V1W)) begin
                pend    <= P_NONE;
                cerr_n  <= cerr_n + 2'd1;
                if (cerr_n >= 2'd2) abort_pend <= 1'b1;
                lcode_n <= L_CERR;
                lreq    <= 1'b1;
            end

            // ==========================================================
            // C) 会话编排机
            // ==========================================================
            // 帧间 10s 超时抢占 (等当前行发完立刻转 TIMEOUT→退出; 有新收
            // 帧坏待回执时让 B2 先走 CERR, 本拍后移一拍再抢)
            if (rx_run && ft_ovf && !lbusy && !lreq && pend != P_BAD &&
                st != ST_LINE) begin
                rx_run  <= 1'b0;
                pend    <= P_NONE;
                lcode_n <= L_TIMEOUT;
                lreq    <= 1'b1;
                st      <= ST_LINE;
            end else begin
                case (st)
                    ST_IDLE: if (loader_start) begin
                        loader_active <= 1'b1;
                        arr_off  <= 19'd0;  goff    <= 19'd0;
                        f40      <= 6'd0;   cerr_n  <= 2'd0;
                        eix      <= 3'd0;   rxst    <= R_F0;
                        pend     <= P_NONE;
                        first32  <= 256'd0; last32  <= 256'd0;
                        ft       <= 29'd0;  ft_ovf  <= 1'b0;
                        abort_pend <= 1'b0;
                        lcode_n  <= L_RDY;  lreq    <= 1'b1;
                        st       <= ST_LINE;
                    end

                    ST_LINE: if (line_done) begin
                        case (lcode_r)
                            L_RDY:        st <= ST_ERASE;
                            L_ERASED: begin
                                rx_run <= 1'b1; ft <= 29'd0; ft_ovf <= 1'b0;
                                st <= ST_COLLECT;
                            end
                            L_CERR:  if (cerr_n >= 2'd3) begin
                                         lcode_n <= L_ABORT; lreq <= 1'b1;
                                     end else st <= ST_COLLECT;
                            L_P40:   st <= ST_COLLECT;
                            default: st <= ST_EXIT;   // DONE/BAD/TIMEOUT/ABORT
                        endcase
                    end

                    // —— 5×64K 块擦, 串行 ——
                    ST_ERASE: if (!fp_busy) begin
                        fp_cmd  <= OP_ERASE;
                        fp_addr <= {{5'd0, eix}, 16'd0};               // eix×0x10000
                        st      <= ST_ERAW;
                    end
                    ST_ERAW: if (fp_done) begin
                        if (fp_to) begin
                            lcode_n <= L_TIMEOUT; lreq <= 1'b1; st <= ST_LINE;
                        end else if (eix == 3'd4) begin
                            lcode_n <= L_ERASED; lreq <= 1'b1; st <= ST_LINE;
                        end else begin
                            eix <= eix + 3'd1;
                            st  <= ST_ERASE;
                        end
                    end

                    // —— 帧消费 ——
                    ST_COLLECT: begin
                        if (abort_pend) begin            // 快速通道凑满 3 连错
                            abort_pend <= 1'b0;
                            lcode_n <= L_ABORT; lreq <= 1'b1;
                            st <= ST_LINE;               // default 派发 → ST_EXIT
                        end
                        case (pend)
                        P_NONE: ;                                     // 等帧
                        P_DATA: if (!fp_busy) begin
                            fp_cmd  <= OP_PP;
                            fp_addr <= {5'd0, goff};                  // 页对齐提交偏移
                            len_c   <= len_p[8:0];                    // 锁帧长, 防下帧 C0 覆写
                            pend    <= P_NONE;
                            st      <= ST_PPW;
                        end
                        P_BAD: begin
                            pend    <= P_NONE;
                            cerr_n  <= cerr_n + 2'd1;
                            lcode_n <= L_CERR; lreq <= 1'b1;
                            st      <= ST_LINE;
                        end
                        P_END:  if (!fp_busy) begin
                            pend <= P_NONE;
                            st   <= ST_V0;                            // 抽验
                        end
                        default: pend <= P_NONE;
                        endcase
                    end
                    ST_PPW: if (fp_done) begin
                        if (fp_to) begin
                            lcode_n <= L_TIMEOUT; lreq <= 1'b1; st <= ST_LINE;
                        end else begin
                            goff <= goff + {10'd0, len_c};
                            if (f40 >= 6'd39) begin                   // 每 40 帧
                                f40 <= 6'd0;
                                lcode_n <= L_P40; lreq <= 1'b1; st <= ST_LINE;
                            end else begin
                                f40 <= f40 + 6'd1;
                                st  <= ST_COLLECT;
                            end
                        end
                    end

                    // —— 结束帧抽验: 读头 32B / 读尾 32B ——
                    ST_V0: if (!fp_busy) begin
                        fp_cmd  <= OP_READ;
                        fp_addr <= 24'd0;
                        st      <= ST_V0W;
                    end
                    ST_V0W: if (fp_done) begin
                        if (fp_rd_q == first32) st <= ST_V1;
                        else begin
                            lcode_n <= L_BAD; lreq <= 1'b1; st <= ST_LINE;
                        end
                    end
                    ST_V1: if (!fp_busy) begin
                        fp_cmd  <= OP_READ;
                        fp_addr <= {5'd0, goff - 19'd32};  // 动态尾地址=实收-32 (裁决3)
                        st      <= ST_V1W;
                    end
                    ST_V1W: if (fp_done) begin
                        lcode_n <= (fp_rd_q == last32) ? L_DONE : L_BAD;
                        lreq    <= 1'b1;
                        st      <= ST_LINE;
                    end

                    ST_EXIT: begin
                        loader_active <= 1'b0;
                        rx_run <= 1'b0;  pend   <= P_NONE;
                        ft     <= 29'd0; ft_ovf <= 1'b0;
                        abort_pend <= 1'b0;
                        rxst   <= R_F0;
                        st     <= ST_IDLE;
                    end

                    default: st <= ST_IDLE;                           // 防跑飞
                endcase
            end
        end
    end
endmodule

`default_nettype wire
