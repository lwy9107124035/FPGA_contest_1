`timescale 1 ns / 1 ps
//-----------------------------------------------------------------------------
// glyph_xcd.v -- glyph_fetch(clk50 域) <-> OSD 渲染(video_clk 25.175MHz 域)
//                的跨时钟域搬运桥。风格: 请求/完成握手 + 准静态 256bit 总线,
//                不用双口 RAM。
//
// 协议 (一次完整取字):
//   video 侧: 发 1 拍 req_v(伴随 addr_v, 此后 addr 由本模块内部锁存, 调用方
//             无需保持); busy_v 置 1, req_tgl 翻转。
//   clk50 侧: 同步 req_tgl 检测沿 -> 对 glyph_fetch 发 1 拍 fetch_req +
//             fetch_addr(≈23us 事务); fetch_done 到来 -> done_tgl 翻转。
//   video 侧: 同步 done_tgl 检测沿 new_v(1 拍), 沿上把 fetch_data 打入
//             out_v, glyph_ready_v 置 1, busy_v 清 0。
//   互锁: busy_v=1 期间再来 req_v 会被丢弃并置粘滞标志 drop_err_v(协议违例
//         指示)。请求->完成期间总线只被最终写入一次, 且 video 侧只在 new_v
//         沿采样, 不存在"总线半更新被采样"的窗口。
//
// 跨域时序论证 (为什么"done 打两拍 + busy 互锁"对 256bit 总线是安全的):
//   1) 稳定窗口: glyph_fetch 最后一个字节移位完成后, 还要经 ST_HOLD(2 拍)
//      + ST_CSHIGH(9 拍) 才发 fetch_done, done_tgl 与 fetch_done 同拍翻转;
//      video 侧采样发生在 done_tgl 沿之后 2~3 拍 vclk(两级同步+沿检测,
//      80~120ns)。总线在采样点之前已冻结 >=220ns, 建立裕量 >= 3 拍 vclk。
//   2) 保持窗口: 总线下一次变化(下次 fetch 的数据段首字节)最早发生在
//      "new_v -> busy_v 清 0 -> 调用方再发 req_v -> 4 字节命令/地址过完"
//      之后, 距本次采样 >= 数 us。out_v 早已锁存为 video 域副本, 渲染侧
//      只读 out_v, 绝不直连总线, 中途翻转与渲染无关。
//   3) 单 bit 控制: req_tgl/done_tgl 各走标准两级触发器同步器 + 延迟异或
//      沿检测; 两次翻转间隔 >= 一次完整事务(us 级) >> 同步窗(ns 级),
//      边沿不丢不重复。
//   4) MTBF: 256 根数据线的采样沿距总线翻转沿 >= ~3 vclk(>120ns), 且被采
//      对象是普通寄存器输出(无组合毛刺), 属教科书式"准静态总线 + 慢选通"
//      范式, 亚稳裕量按 ns 级 tau 折算为天文数字 MTBF。
//
// 复位: 两侧 rst_n 建议同源同释放(顶层都用 ~rst_all)。即使一侧单独复位,
//   协议也只会多出一个良性 new_v(数据仍自洽), 不会死锁。
//
// 如何被 osd_banner / 顶层使用 (接线由主线会话完成):
//   top(clk=50M):
//     glyph_fetch u_fetch(.clk(clk), .rst_n(~rst_all),
//         .fetch_req(g_x_fetch_req), .glyph_addr(g_x_fetch_addr),
//         .glyph_data(g_x_fetch_data), .fetch_done(g_x_fetch_done),
//         .busy(g_x_fetch_busy), .flash_cs_n(P8), .flash_sck(M9),
//         .flash_mosi(N8), .flash_miso(P7));
//     glyph_xcd u_xcd(.clk50(clk), .rst50_n(~rst_all),
//         .fetch_req(g_x_fetch_req), .fetch_addr(g_x_fetch_addr),
//         .fetch_busy(g_x_fetch_busy), .fetch_done(g_x_fetch_done),
//         .fetch_data(g_x_fetch_data),
//         .vclk(video_clk), .vrst_n(~rst_all),
//         .req_v(xcd_req), .addr_v(xcd_addr), .busy_v(xcd_busy),
//         .new_v(xcd_new), .glyph_ready_v(xcd_rdy),
//         .out_v(xcd_got), .out_addr_v(xcd_got_addr));
//   video 域: 场消隐预取状态机逐槽发 req_v/addr_v(addr 由 GB2312 码位换算,
//   公式见 README_cjk_flash.md 第 2/7 节), 收到 new_v 拍把 out_v 写入行点阵
//   缓存(真 BRAM, 同步读); 渲染行/像素逻辑只读 BRAM, 不碰 SPI。
//-----------------------------------------------------------------------------
`default_nettype none

module glyph_xcd (
    // ============ clk50 侧: 与 glyph_fetch 同域直连 ============
    input  wire         clk50,          // 50 MHz
    input  wire         rst50_n,        // 低有效
    output wire         fetch_req,      // -> glyph_fetch.fetch_req (1 clk50 拍)
    output reg  [19:0]  fetch_addr,     // -> glyph_fetch.glyph_addr
    input  wire         fetch_busy,     // <- glyph_fetch.busy
    input  wire         fetch_done,     // <- glyph_fetch.fetch_done (1 拍)
    input  wire [255:0] fetch_data,     // <- glyph_fetch.glyph_data (准静态)
    // ============ video_clk(25.175MHz) 侧: 渲染域使用 ============
    input  wire         vclk,
    input  wire         vrst_n,
    input  wire         req_v,          // 1 vclk 拍脉冲, busy_v=1 时发起无效
    input  wire [19:0]  addr_v,         // 与 req_v 同拍给出的槽地址
    output reg          busy_v,         // 1 = 本次取字在途
    output reg          glyph_ready_v,  // 1 = out_v 已至少装载过一次有效字模
    output wire         new_v,          // 1 vclk 拍: 新字模已进 out_v
    output reg  [255:0] out_v,          // 字模 (与 glyph_data 位序一致)
    output reg  [19:0]  out_addr_v,     // 与 out_v 对应的地址(调试/校验用)
    output reg          drop_err_v      // 粘滞: 曾发生过 busy_v 期间发 req_v
);

    // ---------------- 跨域翻转标志 (各自唯一驱动源, 对侧只过同步链) --------
    reg req_tgl;      // video 域驱动, clk50 域同步
    reg done_tgl;     // clk50 域驱动, video 域同步

    // ---------------- video 域: 发起 + 收完成 ----------------
    reg [19:0] addr_hold;               // 在途地址锁存(准静态供给 clk50 侧)
    reg        done_tgl_q0, done_tgl_q1, done_tgl_q2;   // 同步链
    wire       done_edge  = done_tgl_q1 ^ done_tgl_q2;
    assign     new_v      = done_edge;

    // 允许"完成同拍接新请求": done_edge 拍 busy_v 本拍清 0, 若恰好又有
    // req_v, accept_v=1, 下面非阻塞赋值的先后顺序保证 busy_v 最终=1,
    // 互锁不失守, 且省掉一拍空转。
    wire       accept_v   = req_v && (!busy_v || done_edge);

    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            req_tgl       <= 1'b0;
            addr_hold     <= 20'd0;
            busy_v        <= 1'b0;
            glyph_ready_v <= 1'b0;
            drop_err_v    <= 1'b0;
            out_v         <= 256'd0;
            out_addr_v    <= 20'd0;
            done_tgl_q0   <= 1'b0;
            done_tgl_q1   <= 1'b0;
            done_tgl_q2   <= 1'b0;
        end else begin
            done_tgl_q0 <= done_tgl;
            done_tgl_q1 <= done_tgl_q0;
            done_tgl_q2 <= done_tgl_q1;

            if (done_edge) begin
                busy_v <= 1'b0;
            end
            if (req_v && busy_v && !done_edge) begin
                drop_err_v <= 1'b1;     // 协议违例, 记录后丢弃
            end
            if (accept_v) begin
                addr_hold <= addr_v;
                req_tgl   <= ~req_tgl;
                busy_v    <= 1'b1;      // 同拍覆盖上面的清 0 (见注释)
            end
            if (done_edge) begin
                // 准静态总线采样, 裕量论证见文件头 1)/2)
                out_v         <= fetch_data;
                out_addr_v    <= addr_hold;
                glyph_ready_v <= 1'b1;
            end
        end
    end

    // ---------------- clk50 域: 收请求 -> 驱动 glyph_fetch ----------------
    reg req_tgl_q0, req_tgl_q1, req_tgl_q2;       // 同步链
    wire  req_edge  = req_tgl_q1 ^ req_tgl_q2;    // 新请求沿
    reg   pend50;                                 // 对端忙时兜底暂存
    reg   req_p;                                  // fetch_req 脉冲寄存器

    assign fetch_req = req_p;

    always @(posedge clk50 or negedge rst50_n) begin
        if (!rst50_n) begin
            req_tgl_q0 <= 1'b0;
            req_tgl_q1 <= 1'b0;
            req_tgl_q2 <= 1'b0;
            pend50     <= 1'b0;
            req_p      <= 1'b0;
            fetch_addr <= 20'd0;
            done_tgl   <= 1'b0;
        end else begin
            req_tgl_q0 <= req_tgl;
            req_tgl_q1 <= req_tgl_q0;
            req_tgl_q2 <= req_tgl_q1;
            req_p      <= 1'b0;         // 缺省: 单拍脉冲

            if ((req_edge || pend50) && !fetch_busy) begin
                // addr_hold 自 video 沿起已保持数 us, 此处采样是准静态跨域
                fetch_addr <= addr_hold;
                req_p      <= 1'b1;
                pend50     <= 1'b0;
            end else if (req_edge && fetch_busy) begin
                pend50     <= 1'b1;     // busy 互锁下理论不可达, 兜底不丢请求
            end

            if (fetch_done) done_tgl <= ~done_tgl;
        end
    end

endmodule

`default_nettype wire
