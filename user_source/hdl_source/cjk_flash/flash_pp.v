`timescale 1 ns / 1 ps
// =============================================================================
// flash_pp.v — W25Q64 用户 FLASH 编程引擎 (LOAD 协议 v1 §4, clk50 域)
//              第十届(2026)嵌入式竞赛 FPGA 赛题一 · OSD 中文字库软装载
//
// 功能: 接收 1 拍命令脉冲, 对板载 W25Q64 (U33) 执行
//   cmd=2'd1  64K 块擦除 (0xD8, cmd_addr 起; 协议用 0x00000/0x10000/.../0x40000)
//   cmd=2'd2  页编程   (0x02, cmd_addr 须 256B 页对齐, 数据取内部 pbuf)
//   cmd=2'd3  普通读   (0x03, cmd_addr 起 32B → pp_rd_q, 装载收尾抽验用)
//   cmd=2'd0  空闲
// 擦/写命令自动前置 0x06 WREN; 之后用 0x05 RDSR 轮询 WIP(bit0) 直到清零:
//   页编程兜底超时 100ms (>协议 §4 的 3ms 页编程上限), 块擦除兜底 4.5s
//   (>W25Q64 64K 块擦 datasheet max 3s, 协议 §4 自述 0.4~2s 典型 —— 若对
//   擦除也卡 100ms 会 100% 误报, 偏差理由见 LOAD_IMPL_NOTES.md §6)。
// 超时与 done 同拍输出 pp_to=1, 由上层(uart_loader)决定回 TIMEOUT 文本行。
//
// SPI 时序 (模式 0, SCLK=12.5MHz=50M 四分频, 高2拍低2拍; 与 glyph_fetch.v
// 同一套相位约定, 便于主线对照审查):
//   每 bit 四相位 ph=0..3:
//     ph0: FPGA 更新 MOSI (寄存器输出, 距稍后上升沿 1 拍=20ns 建立)
//     ph1: SCLK 上升沿 —— flash 采样 MOSI; miso_s0 本级跟采样 MISO
//     ph2: 把上一拍 miso_s0 移入接收移位 (距 MISO 翻转 >=40ns, 窗口干净)
//     ph3: SCLK 下降沿 —— flash 输出下一 bit; bitn/字节收尾、换发字节
//   24bit 地址大端先行 (addr[23:16] → addr[15:8] → addr[7:0])。
//   CS#: 事务前拉低等 ~120ns 建立; 事务末 bit 后 SCLK 先落、隔 3 拍再抬 CS#
//   (tVSLK 裕量), 两事务间 CS# 高 >= ~320ns (tSHSL 50ns 富余); 末事务后
//   再保 ~180ns 才打 done/释放 busy。全寄存器输出, 引脚无组合毛刺。
//
// —— TD 综合器数组铁律 (msg_ink.v v3c 事故教训) 的落实 ——
//   pbuf (reg [7:0] pbuf[0:255]) 是本工程唯一的 RAM 推断数组。本模块保证:
//   1) 每个时钟沿对 pbuf 最多 1 次读: 唯一读点 pf_now 命中时 hold<=pbuf[idx>;
//      其余任何分支/相位都无第二个 pbuf 读; 下一字节的组合 mux (nxt_b) 只读
//      普通寄存器 hold, 绝不直接索引 pbuf。
//   2) 每个时钟沿最多 1 次写 (loader 灌数口 pp_buf_we)。
//   3) SPI 移出用"上一拍预取、当拍使用"的 1 级 hold, 且预取点在字节边界前
//      8 个时钟 (byte 内 bit6/ph0 预取, bit7/ph3 边界才使用), 比 msg_ink 的
//      1 拍余量更宽: 异步 mux / 同步 BRAM(1 拍延迟) / 被串行化出 2 拍读口
//      三种推断下 hold 都已就位, 位精确。
//   4) 读下标 pf_idx 与写下标 pp_buf_widx 每拍最多各 1 个动态值, 同一拍绝不
//      出现两个不同下标的读。
//
// 与 loader 的 pbuf 并发约定 (带宽论证详见 LOAD_IMPL_NOTES.md §5):
//   115200 字节周期 86.8us; 页编程"移位读 pbuf"段 260B×32×20ns≈166us, 含
//   WREN/间隙全程 ≤ ~220us, 而下一帧首个 payload 字节最早在上一帧末字节后
//   5×86.8=434us (A5/01/LEN16/LEN0 之后) 才到达 —— 写口与读口物理上不可能重叠。
//   cmd_i 在 pp_busy 期间到来会被忽略 (不排队; loader 单发射保证不并发)。
// =============================================================================
`default_nettype none

module flash_pp (
    input  wire         clk50,          // 50 MHz 板晶振域 (勿接 video_clk!)
    input  wire         I_rst,          // 高有效, 与顶层 rst_all 同源
    // —— 命令接口 (1 拍脉冲) ——
    input  wire [1:0]   cmd_i,          // 0=idle 1=块擦 2=页编程 3=读32B
    input  wire [23:0]  cmd_addr_i,
    // —— pbuf 填充口: loader 逐字节写, 256B 页缓冲 ——
    input  wire         pp_buf_we,
    input  wire [7:0]   pp_buf_widx,
    input  wire [7:0]   pp_buf_wdata,
    // —— 状态回报 ——
    output reg          pp_busy,
    output reg          pp_done,        // 1 拍脉冲: 本次 op 结束
    output reg          pp_to,          // 与 pp_done 同拍为 1 = WIP 轮询超时
    output reg  [255:0] pp_rd_q,        // cmd=3 结果: [255:248]=cmd_addr 第 0 字节
    // —— W25Q64 引脚 (WP#=P9, HOLD#=R9 由顶层接常数 1) ——
    output wire         flash_cs_n,     // P8
    output wire         flash_sck,      // M9
    output wire         flash_mosi,     // N8 (原理图 SDO, FPGA→flash)
    input  wire         flash_miso      // P7 (原理图 SDI, flash→FPGA)
);
    localparam [1:0] OP_NONE  = 2'd0,
                     OP_ERASE = 2'd1,
                     OP_PP    = 2'd2,
                     OP_READ  = 2'd3;
    localparam [7:0] C_WREN = 8'h06, C_RDSR = 8'h05,
                     C_BLK  = 8'hD8, C_PP   = 8'h02, C_RD = 8'h03;

    // 超时兜底 (cycle @50MHz): 页编程 100ms; 块擦 4.5s (理由见头注)
    localparam [28:0] TO_PP    = 29'd5_000_000,
                      TO_ERASE = 29'd225_000_000;

    localparam [2:0] S_IDLE  = 3'd0,
                     S_SETUP = 3'd1,   // CS# 已拉低, 等建立 (6 拍)
                     S_RUN   = 3'd2,   // 逐 bit 移位一段事务
                     S_GAP   = 3'd3,   // 事务尾: SCLK 低 3 拍 → 抬 CS# → 段决策
                     S_POLLG = 3'd4,   // RDSR 轮询静默间隙 (~320ns)
                     S_END   = 3'd5;   // 末 CS# 高保持 → done 脉冲

    reg [2:0]  st;
    reg [1:0]  op;                     // 锁存 OP_*
    reg [1:0]  seg;                    // 0=WREN 1=主事务 2=RDSR (READ 只有其主段)
    reg [23:0] addr_r;
    reg [8:0]  tb;                     // 段内字节号 (PP 至 259)
    reg [8:0]  tlen_r;                 // 段总字节数
    reg [2:0]  bitn;
    reg [1:0]  ph;
    reg [5:0]  tick;
    reg [7:0]  sh_out, sh_in, stat_r, hold;
    reg [28:0] to_cnt, to_lim;
    reg        to_r;                   // 粘滞超时, S_END 随 done 输出

    reg [7:0] pbuf [0:255];            // 页缓冲 (1W loader / 1R 预取, 见头注)

    reg cs_n_r, sclk_r, mosi_r;
    assign flash_cs_n = cs_n_r;
    assign flash_sck  = sclk_r;
    assign flash_mosi = mosi_r;

    reg miso_s0;                       // MISO 一级跟采样 (准静态信号)
    always @(posedge clk50 or posedge I_rst)
        if (I_rst) miso_s0 <= 1'b1;
        else       miso_s0 <= flash_miso;

    // —— 段参数纯组合查表 (普通寄存器值上的 mux, 不碰 pbuf) ——
    function [7:0] seg_opcd;
        input [1:0] o; input [1:0] s;
    begin
        case (o)
            OP_ERASE: seg_opcd = (s==2'd0) ? C_WREN : (s==2'd1) ? C_BLK : C_RDSR;
            OP_PP:    seg_opcd = (s==2'd0) ? C_WREN : (s==2'd1) ? C_PP   : C_RDSR;
            OP_READ:  seg_opcd = C_RD;
            default:  seg_opcd = 8'h00;
        endcase
    end
    endfunction

    function [8:0] seg_len;
        input [1:0] o; input [1:0] s;
    begin
        case (o)
            OP_ERASE: seg_len = (s==2'd0) ? 9'd1  : (s==2'd1) ? 9'd4   : 9'd2;
            OP_PP:    seg_len = (s==2'd0) ? 9'd1  : (s==2'd1) ? 9'd260 : 9'd2;
            OP_READ:  seg_len = 9'd36;                        // 1+3+32
            default:  seg_len = 9'd1;
        endcase
    end
    endfunction

    // 下一字节的发送内容 (纯 mux; PP 页字节经 hold 间接, 无第二读口)
    wire [8:0] nb = tb + 9'd1;
    reg  [7:0] nxt_b;
    always @(*) begin
        if ((seg == 2'd1 || op == OP_READ) && nb >= 9'd1 && nb <= 9'd3)
            case (nb)
                9'd1:    nxt_b = addr_r[23:16];
                9'd2:    nxt_b = addr_r[15:8];
                default: nxt_b = addr_r[7:0];                 // nb==3
            endcase
        else if (op == OP_PP && seg == 2'd1 && nb >= 9'd4)
            nxt_b = hold;                                     // 预取好的页字节
        else
            nxt_b = 8'hFF;                                    // dummy / 防锁存
    end

    // 唯一 pbuf 读点: PP 主段, 边界前 8 拍预取 (下一发送字节 = pbuf[tb-3])
    wire       pf_now = (op == OP_PP && seg == 2'd1 &&
                         tb >= 9'd3 && tb <= 9'd258 &&
                         ph == 2'd0 && bitn == 3'd6);
    wire [7:0] pf_idx = tb[7:0] - 8'd3;

    wire cap_stat = (seg == 2'd2 && tb == 9'd1);              // RDSR 状态字节
    wire cap_rd   = (op == OP_READ && tb >= 9'd4);            // READ 32B 数据

    // 段启动公共动作 (S_GAP 内两处复用): 装段参数 + 拉低 CS#
    task arm_seg;
        input [1:0] s;
    begin
        seg    <= s;
        tb     <= 9'd0;
        bitn   <= 3'd0;
        ph     <= 2'd0;
        tick   <= 6'd0;
        sh_out <= seg_opcd(op, s);
        sh_in  <= 8'h00;
        tlen_r <= seg_len(op, s);
        cs_n_r <= 1'b0;
        st     <= S_SETUP;
    end
    endtask

    always @(posedge clk50 or posedge I_rst) begin
        if (I_rst) begin
            st <= S_IDLE; op <= OP_NONE; seg <= 2'd0; addr_r <= 24'd0;
            tb <= 9'd0; tlen_r <= 9'd1; bitn <= 3'd0; ph <= 2'd0;
            tick <= 6'd0; sh_out <= 8'h00; sh_in <= 8'h00;
            stat_r <= 8'h00; hold <= 8'h00;
            to_cnt <= 29'd0; to_lim <= TO_PP; to_r <= 1'b0;
            cs_n_r <= 1'b1; sclk_r <= 1'b0; mosi_r <= 1'b0;
            pp_busy <= 1'b0; pp_done <= 1'b0; pp_to <= 1'b0;
            pp_rd_q <= 256'd0;
        end else begin
            pp_done <= 1'b0;                                  // done 默认 1 拍
            // pbuf 写口 (loader 灌页, ≤1 写/拍; 与 pf_now 读拍不重叠见头注)
            if (pp_buf_we) pbuf[pp_buf_widx] <= pp_buf_wdata;

            // WIP 轮询计时: 擦/写命令执行全程 (READ 定长事务不计时)
            if (pp_busy && op != OP_READ && st != S_IDLE && to_cnt != to_lim)
                to_cnt <= to_cnt + 29'd1;

            case (st)
            // ------------------------------------------------------------
            S_IDLE: begin
                sclk_r <= 1'b0; cs_n_r <= 1'b1; mosi_r <= 1'b0;
                if (cmd_i == OP_ERASE || cmd_i == OP_PP || cmd_i == OP_READ) begin
                    op      <= cmd_i;
                    addr_r  <= cmd_addr_i;
                    to_cnt  <= 29'd0;
                    to_lim  <= (cmd_i == OP_ERASE) ? TO_ERASE : TO_PP;
                    to_r    <= 1'b0;
                    pp_busy <= 1'b1;
                    tb      <= 9'd0; bitn <= 3'd0; ph <= 2'd0;
                    tick    <= 6'd0;
                    sh_in   <= 8'h00;
                    cs_n_r  <= 1'b0;
                    if (cmd_i == OP_READ) begin               // 无 WREN, 直开 READ
                        seg    <= 2'd0;
                        sh_out <= C_RD;
                        tlen_r <= 9'd36;
                        pp_rd_q<= 256'd0;
                    end else begin                            // 先 WREN 段
                        seg    <= 2'd0;
                        sh_out <= C_WREN;
                        tlen_r <= 9'd1;
                    end
                    st <= S_SETUP;
                end
            end

            // ------------------------------------------------------------
            S_SETUP: begin                                    // CS# 建立等待
                tick <= tick + 6'd1;
                ph   <= 2'd0;
                if (tick == 6'd5) st <= S_RUN;
            end

            // ------------------------------------------------------------
            S_RUN: case (ph)
                2'd0: begin                                   // 输出位更新拍
                    mosi_r <= sh_out[7];
                    sh_out <= {sh_out[6:0], 1'b0};
                    if (pf_now) hold <= pbuf[pf_idx];         // *唯一* pbuf 读
                    ph <= 2'd1;
                end
                2'd1: begin                                   // SCLK 上升沿
                    sclk_r <= 1'b1;
                    ph     <= 2'd2;
                end
                2'd2: begin                                   // 收位拍
                    sh_in <= {sh_in[6:0], miso_s0};
                    ph    <= 2'd3;
                end
                2'd3: begin                                   // SCLK 下降沿
                    sclk_r <= 1'b0;
                    ph     <= 2'd0;
                    if (bitn == 3'd7) begin
                        if (cap_stat) stat_r  <= sh_in;
                        if (cap_rd)   pp_rd_q <= {pp_rd_q[247:0], sh_in};
                        sh_out <= nxt_b;                      // 装下一发送字节
                        bitn   <= 3'd0;
                        if (tb == tlen_r - 9'd1) begin
                            tick <= 6'd0;
                            st   <= S_GAP;                    // 段尾 (CS# 仍低)
                        end else begin
                            tb   <= tb + 9'd1;
                        end
                    end else begin
                        bitn <= bitn + 3'd1;
                    end
                end
                default: ph <= 2'd0;                          // 防锁死
            endcase

            // ------------------------------------------------------------
            S_GAP: begin                          // 末 bit 后 SCLK 已低, 3 拍
                tick <= tick + 6'd1;                          // 后抬 CS#, 再留
                if (tick == 6'd3) cs_n_r <= 1'b1;            // tVSLK → CS# 升
                if (tick == 6'd15) begin
                    if (op == OP_READ) begin
                        tick <= 6'd0;
                        st   <= S_END;                        // 读: 无轮询段
                    end else if (seg == 2'd2) begin
                        if (stat_r[0] == 1'b0) begin
                            tick <= 6'd0;
                            st   <= S_END;                    // WIP=0, 完成
                        end else if (to_cnt >= to_lim) begin
                            to_r <= 1'b1;
                            tick <= 6'd0;
                            st   <= S_END;                    // 兜底超时
                        end else begin
                            tick <= 6'd0;
                            st   <= S_POLLG;                  // 稍后再询
                        end
                    end else begin
                        arm_seg(seg + 2'd1);                  // WREN→主段→RDSR
                    end
                end
            end

            // ------------------------------------------------------------
            S_POLLG: begin                                    // 轮询间隙 32 拍
                tick <= tick + 6'd1;
                if (tick == 6'd31) begin
                    seg    <= 2'd2;                           // 重启 RDSR 事务
                    tb     <= 9'd0; bitn <= 3'd0; ph <= 2'd0;
                    tick   <= 6'd0;
                    sh_out <= C_RDSR;
                    sh_in  <= 8'h00;
                    tlen_r <= 9'd2;
                    cs_n_r <= 1'b0;
                    st     <= S_SETUP;
                end
            end

            // ------------------------------------------------------------
            S_END: begin                                      // 末次 CS# 高保持
                tick <= tick + 6'd1;
                if (tick == 6'd8) begin
                    pp_busy <= 1'b0;
                    pp_done <= 1'b1;
                    pp_to   <= to_r;
                    st      <= S_IDLE;
                end
            end

            default: st <= S_IDLE;                            // 防跑飞 (无死态)
            endcase
        end
    end
endmodule

`default_nettype wire
