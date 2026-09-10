`timescale 1 ns / 1 ps
//-----------------------------------------------------------------------------
// glyph_fetch.v -- W25Q64 (板载用户 FLASH, U33) 汉字点阵读取 SPI 主机
//                   第十届(2026)嵌入式竞赛 FPGA 赛题一 · OSD 中文化子模块
//
// 功能:
//   收到 1 拍 fetch_req + 32 字节对齐的 FLASH 字节地址 glyph_addr 后, 用
//   W25Q64 标准 READ 命令 (0x03 + 24bit 地址, SPI 模式0) 连续读出 32 字节
//   = 一个 16x16 汉字点阵 (HZK16 槽位), 装入 glyph_data, 打一拍 fetch_done。
//   每次 fetch 都完整重发 0x03+addr (不做突发/流水线优化): 一次事务
//   36 字节 x 8bit x 4 clk/bit = 1152 clk @50MHz ~= 23us, 应急广播场景足够。
//
// SPI 时序 (模式 0: CPOL=0 空闲低, CPHA=0 上升沿采样):
//   SCLK 由 50MHz 四分频: 低2拍 -> 高2拍, 12.5MHz。每 bit 四个相位 ph=0..3:
//     ph==0 沿: FPGA 输出位 mosi_r 更新 (flash 在稍后的上升沿采样它, 有 1 拍=20ns 建立)
//     ph==1 沿: sclk 拉高 (上升沿, flash 采样 MOSI; 同时 miso_s0 在此沿锁住
//               MISO 当前值 —— 即距 flash 上一下降沿输出后 >=40ns 的稳定值)
//     ph==2 沿: 把上一拍的 miso_s0 移入 sh_miso —— 等效"上升沿采样", 数据距
//               上次翻转 >=40ns、距下次翻转 >=20ns, 窗口干净无亚稳风险
//               (MISO 相对本域是准静态信号, 单级采样即安全)。
//     ph==3 沿: sclk 拉低 (flash 在下降沿输出下一 bit); bit/byte 计数与换字节。
//   SDO/SDI 命名与现有 SD/spi_master.v 一致: flash_mosi 为 FPGA->flash 输出,
//   flash_miso 为 flash->FPGA 输入。
//
// 顶层引脚连接 (原理图实查, 勿与 MSPI 上的 boot FLASH W25Q16 混淆):
//   flash_cs_n  -> P8   (W25Q64 CS#)
//   flash_mosi  -> N8   (原理图标 SDO, 方向为 FPGA -> flash, 即 MOSI)
//   flash_miso  <- P7   (原理图标 SDI, 方向为 flash -> FPGA, 即 MISO)
//   flash_sck   -> M9   (SCLK)
//   WP#  P9 / HOLD# R9 : 在本工程顶层直接接常数 1'b1 (输出常高), 不在本模块。
//   时钟 clk 用板晶振 50MHz (顶层端口 clk), 不要用 video_clk(25.175M),
//   否则 SCLK 频率会不守规。复位与顶层 rst_all 同步 (低有效取 ~rst_all)。
//
// 字模数据排布 (HZK16 标准, 与本工具链 gen_hzk16.py 严格一致):
//   glyph_data[255:240] = 第 0 行 (最上), ..., glyph_data[15:0] = 第 15 行;
//   每行 16bit 内 bit15 = 最左像素。FLASH 中字节序: 偏移+0 = 第0行高字节
//   (左8像素), +1 = 第0行低字节 (右8像素), 依此类推。
//   槽位地址: glyph_addr = ((qu-1)*94 + (wei-1)) * 32  (镜像烧在 0x000000 起)。
//
// 如何被 osd_banner 使用 (由主线会话集成, 本模块作者不接线):
//   video_clk(25.175M) 渲染域不要直接驱动本模块 —— 经 glyph_xcd.v 跨时钟域:
//     osd/msg 行缓存提交 -> 场消隐预取状态机(video 域) -> glyph_xcd.req_v
//     -> [clk50] glyph_xcd -> 本模块 fetch_req/glyph_addr
//     -> 32B 进 glyph_data, fetch_done -> glyph_xcd 搬回 video 域 out_v,
//     写行点阵缓存(真 BRAM, 同步读); 渲染流水线只读缓存, 不碰 SPI。
//   单字取模时序预算: ~23us << 1 行 31.8us < 场消隐 1.43ms, 每场预取 22 字绰绰有余。
//
// 注意: fetch_req 在 busy=1 期间到来会被忽略 (不排队); busy 在 done 打拍的
//   同一拍释放, 上层(glyph_xcd 互锁)保证不会并发请求。
//-----------------------------------------------------------------------------
`default_nettype none

module glyph_fetch (
    input  wire         clk,           // 50 MHz 板晶振域
    input  wire         rst_n,         // 低有效, 与顶层 rst_all 同源
    // —— 字模取用请求接口 ——
    input  wire         fetch_req,     // 1 拍脉冲
    input  wire [19:0]  glyph_addr,    // FLASH 字节地址, 32B 对齐(已含 x32)
    output reg  [255:0] glyph_data,    // 16 行 x 16bit 完整汉字点阵
    output reg          fetch_done,    // 1 拍脉冲
    output reg          busy,          // 1 = 事务进行中, 此期间 glyph_data 不可取用
    // —— W25Q64 引脚 ——
    output wire         flash_cs_n,    // P8
    output wire         flash_sck,     // M9
    output wire         flash_mosi,    // N8 (Schematic: SDO, FPGA -> flash)
    input  wire         flash_miso     // P7 (Schematic: SDI, flash -> FPGA)
);

    // 事务字节数 = 1(命令) + 3(24bit 地址) + 32(数据) = 36, 最后一字节编号 35
    localparam [5:0] LAST_BYTE = 6'd35;
    localparam [7:0] CMD_READ  = 8'h03;   // W25Q64 三线 READ, 地址 24bit, Fmax>=104MHz

    localparam [2:0] ST_IDLE   = 3'd0,
                     ST_CSLOW   = 3'd1,    // CS# 拉低后等待 (tCELT 裕量, 6 x 20ns)
                     ST_RUN     = 3'd2,    // 36 字节移位
                     ST_HOLD    = 3'd3,    // 末 bit 后空 2 拍再抬 CS#
                     ST_CSHIGH  = 3'd4;    // CS# 高保持 >= tSHSL(50ns), 打 done

    reg [2:0]  state;
    reg [1:0]  ph;            // bit 内 4 分相位
    reg [2:0]  bitn;          // 0..7
    reg [5:0]  byten;         // 当前字节 0..35
    reg [3:0]  tick;          // 各等待态计数
    reg [23:0] addr_r;        // {8'h00, glyph_addr} 锁存
    reg [7:0]  sh_mosi;       // 发送字节移位(低位先出完)
    reg [7:0]  sh_miso;       // 接收字节移位(先到为高位)
    reg        mosi_r;         // 串行输出寄存器
    reg        sclk_r;         // 串行时钟寄存器
    reg        cs_n_r;         // 片选寄存器
    reg        miso_s0;        // MISO 入寄存器(每拍跟采样, 见时序注释)

    assign flash_cs_n = cs_n_r;
    assign flash_sck  = sclk_r;
    assign flash_mosi = mosi_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) miso_s0 <= 1'b1;          // 空闲时 SDI 高阻/上拉为 1, 初值无碍
        else        miso_s0 <= flash_miso;
    end

    // 下一个字节的发送内容: byten==0 已在启动时装 0x03, 1..3 为地址, 其余发 0。
    // 纯组合 mux + default, 不产生 latch。
    wire [5:0] nb = byten + 6'd1;            // 35 时回绕为 0, 该拍同时已离开 RUN
    reg  [7:0] tx_next;
    always @(*) begin
        case (nb)
            6'd1:    tx_next = addr_r[23:16];
            6'd2:    tx_next = addr_r[15:8];
            6'd3:    tx_next = addr_r[7:0];
            default: tx_next = 8'h00;
        endcase
    end

    // —— 主状态机 (全寄存器输出, 引脚无组合毛刺) ——
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_IDLE;
            ph         <= 2'd0;
            bitn       <= 3'd0;
            byten      <= 6'd0;
            tick       <= 4'd0;
            addr_r     <= 24'd0;
            sh_mosi    <= 8'h00;
            sh_miso    <= 8'h00;
            mosi_r     <= 1'b0;
            sclk_r     <= 1'b0;
            cs_n_r     <= 1'b1;
            busy       <= 1'b0;
            fetch_done <= 1'b0;
            glyph_data <= 256'd0;
        end else begin
            fetch_done <= 1'b0;               // done 缺省打一拍即回 0
            case (state)
                ST_IDLE: begin
                    sclk_r <= 1'b0;
                    cs_n_r <= 1'b1;
                    if (fetch_req && !busy) begin
                        busy       <= 1'b1;
                        addr_r     <= {4'd0, glyph_addr};  // glyph_addr<=282720, <19bit
                        glyph_data <= 256'd0;             // 数据段左移灌入前的清 0
                        sh_mosi    <= CMD_READ;           // 首字节: 0x03
                        sh_miso    <= 8'h00;
                        byten      <= 6'd0;
                        bitn       <= 3'd0;
                        ph         <= 2'd0;
                        cs_n_r     <= 1'b0;               // 片选拉低
                        tick       <= 4'd0;
                        state      <= ST_CSLOW;
                    end
                end

                ST_CSLOW: begin                          // CS# 建立 ~120ns
                    tick <= tick + 4'd1;
                    ph   <= 2'd0;
                    if (tick == 4'd5) state <= ST_RUN;
                end

                ST_RUN: begin
                    case (ph)
                        2'd0: begin                       // 更新 MOSI (上升沿前 1 拍)
                            mosi_r   <= sh_mosi[7];
                            sh_mosi  <= {sh_mosi[6:0], 1'b0};
                            ph       <= 2'd1;
                        end
                        2'd1: begin                       // SCLK 上升沿 (flash 采样)
                            sclk_r <= 1'b1;
                            ph     <= 2'd2;
                        end
                        2'd2: begin                       // 高电平第 2 拍: 采样 MISO
                            sh_miso <= {sh_miso[6:0], miso_s0};
                            ph      <= 2'd3;
                        end
                        2'd3: begin                       // SCLK 下降沿 + bit/byte 收尾
                            sclk_r <= 1'b0;
                            ph     <= 2'd0;
                            if (bitn == 3'd7) begin
                                // 字节边界: 装载下一字节发送内容(非边界拍不得触碰
                                // sh_mosi, 否则会把正在移的字节冲掉)
                                sh_mosi <= tx_next;
                                bitn    <= 3'd0;
                                if (byten >= 6'd4)        // 数据段: 完成的字节左移入
                                    glyph_data <= {glyph_data[247:0], sh_miso};
                                if (byten == LAST_BYTE) begin
                                    tick  <= 4'd0;
                                    state <= ST_HOLD;
                                end else begin
                                    byten <= byten + 6'd1;
                                end
                            end else begin
                                bitn <= bitn + 3'd1;
                            end
                        end
                        default: ph <= 2'd0;              // 防锁死
                    endcase
                end

                ST_HOLD: begin                            // 末次采样后停 2 拍
                    tick <= tick + 4'd1;
                    if (tick == 4'd1) begin
                        cs_n_r <= 1'b1;                   // 释放片选
                        tick   <= 4'd0;
                        state  <= ST_CSHIGH;
                    end
                end

                ST_CSHIGH: begin                          // CS# 高 ~180ns >= tSHSL
                    tick <= tick + 4'd1;
                    if (tick == 4'd8) begin
                        busy       <= 1'b0;
                        fetch_done <= 1'b1;               // 1 拍脉冲
                        state      <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;                // 防跑飞
            endcase
        end
    end

endmodule

`default_nettype wire
