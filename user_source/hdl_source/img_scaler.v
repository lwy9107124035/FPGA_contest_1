    //=============================================================================
    // img_scaler v12.0 (v10.3b-13 DISPATCH-ONLY + B3-lite 源侧限流)
    //   v12: 新增 src_pause 输出 —— 环深 4 槽挡不住"写侧抢跑"(突发期写侧一次推 5 行,
    //   领先量单调累积到 26 行), 于是改为"让上游别抢跑": 写侧领先 >=2 行即请
    //   bmp_read 暂停下一个扇区。安全不变式 rows_done <= syc+3 见下方 pause_c。
    // ★★ 06:04 探针账本终极对账：唯一反复通过的结构 = P1/H2/U2 形状
    //    【端口只被 if 体与调度块消费，always 里零"无条件端口直读寄存器"】。
    //    一切"打拍链 sw_r<=src_w"式写法 = TD 6.2.168 coredump 之源
    //    （R1e/Y1/V4 系列全灭、V6/P1/U2/A3sq 全绿，无一例外）。
    //    另注意：td_project 里堆积 minidump/*.logw 会毒化后续会话 —— elab_run.py
    //    已内置每次探测前自动清扫。
    // 功能 = b-11 全集（语义逐行等价）：
    //   · 守卫（组合版 guard_c，仅调度拍消费）：640×480 原样 / 过小(<320×16) /
    //     过大(>1280×1080) / 极端比(>4:1) / 扁条带(est_w && 896w≥1280h+w²)
    //     → pass 直通；宽图判定 wide=est_c 同拍锁存。
    //   · 内联恢复除法（sdiv24 实证单元体）：ld0@T2 job0=短边目标 → qres0@T27
    //     （cp1@T29 取→t_nd, ld1 装 job1=w0*8192÷(wide?640:tclamp)）→ qres1@T53
    //     （cp2@T55 取→sx_step, ld2 装 job2=h0*8192÷(wide?tclamp:480)）→
    //     qres2@T79（fn7@T81 取→sy_step+dst/off 快照）<< 首像素 T163 ✓
    //   · owner(k)=(2k+1)*step>>14（Q13 中心采样最近邻）+ 4 行环形源缓存
    //     24bit×8192 {slot,col} + A/B 两级流水 1px/2拍 + letterbox 黑边。
    //   · 输出恒 640×480=307200 拍；frame_done 与末拍 out_en 同拍。
    // 资源：环 24 BRAM9K（总 ~49/64）+ 2×17/16 乘 + 16×16 乘（守卫 b_c0）。
    //=============================================================================
`default_nettype none
module img_scaler (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_en,
    input  wire [31:0] in_data,
    input  wire [15:0] src_w, src_h,
    input  wire        in_sov,
    input  wire        in_eov,
    output reg         out_en,
    output reg  [31:0] out_data,
    output reg         frame_done,
    // v12 (B3-lite): 源侧限流请求。1 = 请上游暂停供数。详见下方 pause_c 推导。
    output reg         src_pause
);
    localparam [15:0] DST_W = 16'd640, DST_H = 16'd480;

    // ---------- 端口组合守卫（只被调度块消费——P1/U2 实证安全形状） ----------
    wire       c_ex0  = (src_w == 16'd640) && (src_h == 16'd480);
    wire       c_s0   = (src_w < 16'd320) || (src_h < 16'd16);
    wire       c_b0   = (src_w > 16'd1280) || (src_h > 16'd1080);
    wire       c_a0   = (src_w > (src_h << 2)) || (src_h > (src_w << 2));
    wire [24:0] e_l0  = {src_w, 9'd0} - {4'd0, src_w, 5'd0};
    wire [24:0] e_r0  = {src_h, 9'd0} + {2'd0, src_h, 7'd0};
    wire       est_c  = (e_l0 >= e_r0);
    wire [25:0] e_bw  = {src_h, 10'd0};                                   // h*640
    wire [25:0] e_lim = {src_w, 7'd0} + {src_w, 5'd0};                    // w*240
    wire       e_band = est_c ? (e_bw >= e_lim) : 1'b1;
    // b-19 (链B收口): 只有"恰 640×480"允许直通——直通转发字数=输入字数，破坏下游
    //   frame_fifo_write 恒 307,200 字的 write_finish 契约（640×200 永不到 S_END；
    //   1280×360 超写越界踩另一帧缓冲）。c_s0/c_b0/c_a0 与 bmp_read mr_ok 同界，
    //   SC=1 域内不可达；旧 !e_band"扁条带直通"改走缩放路（字数恒 307,200，几何
    //   手算复核：640×200→1:1 居中 offy=140 ✓；1280×360→0.5:1 offy=150 ✓）。
    wire       guard_c = c_ex0;

    // ---------- 状态/几何 ----------
    reg        st, actq, pass, eovr;
    reg [6:0]  sq;
    reg [15:0] sw1, sh1;               // sov 拍一次性锁存（无打拍链）
    reg [15:0] w0, h0;
    reg        wide;
    reg [15:0] t_nd;
    reg [15:0] sx_step, sy_step;
    reg [15:0] dst_w, dst_h, offx, offy;

    // ---------- 寄存器域守卫（除法 job 用，sw1/sh1 驱动） ----------
    wire [24:0] e_l    = {sw1, 9'd0} - {4'd0, sw1, 5'd0};
    wire [24:0] e_r    = {sh1, 9'd0} + {2'd0, sh1, 7'd0};
    wire       est_w   = (e_l >= e_r);


    // ---------- 除法节拍（T0=sov；cp 取结果拍自带 2 拍余量） ----------
    reg        ld0, ld1, ld2;
    wire       cp1 = actq && (sq == 7'd28);
    wire       cp2 = actq && (sq == 7'd54);
    wire       fn7 = actq && (sq == 7'd80);

    // ---------- 内联恢复除法（sdiv24 实证单元体） ----------
    reg [23:0] dn, dq, qres;
    reg [16:0] da;
    reg [4:0]  dc;
    reg        dbz;
    reg [15:0] dden;
    wire [15:0] dds   = (dden == 16'd0) ? 16'd1 : dden;
    wire [16:0] dsh   = {da[15:0], dn[23]};
    wire        dsub  = (dsh >= {1'b0, dds});
    wire [16:0] dna   = dsub ? (dsh - {1'b0, dds}) : dsh;
    wire [23:0] dnext = {dq[22:0], dsub};
    wire [15:0] qclamp = (qres == 24'd0) ? 16'd1 : qres[15:0];
    wire [15:0] tclamp = (t_nd == 16'd0) ? 16'd1 : t_nd;

    // ---------- 4 行环形源缓存（H2 实证形状） ----------
    reg [23:0] ring [0:8191];
    reg [15:0] rows_done;
    reg [1:0]  wr_slot;
    reg [15:0] wr_i;

    // ---------- S2 读/输出级 ----------
    reg [15:0] dy, dx;
    reg        a_black, a_go, fd_pend;
    reg [23:0] ram_q;
    // v12.1 去突发化输出节奏：原 b-22 "真四分频"= 1字/4拍 —— 一整行 640 字会在
    //   2560 拍内灌向 512 深的 wfifo，写侧要么溢出丢字（0x18 卡死），要么为排空而
    //   长时间占住 SDRAM 写口、把显示读口饿死（= 板上花屏）。
    //   源侧实际只需 ~1字/280拍（SD 每像素 ~180 拍 × 800 入/512 出），故取
    //   1字/32拍：比需求快 ~8 倍（不拖慢装载），却把瞬时灌入速率降到原来的 1/8，
    //   wfifo 水位长期贴地，写侧不再成串占口。直通 pass 路仍完全旁路，节奏不变。
    reg [4:0]  rd_tick;
    wire       rd_gate = (rd_tick == 5'd31);

    wire [15:0] cx  = (dx >= offx) ? (dx - offx) : 16'd0;
    wire [15:0] cy  = (dy >= offy) ? (dy - offy) : 16'd0;
    wire [16:0] ix21 = {cx, 1'b0} + 17'd1;
    wire [32:0] ixp  = ix21 * {1'b0, sx_step};
    wire [15:0] sx   = ixp[29:14];
    wire [16:0] iy21 = {cy, 1'b0} + 17'd1;
    wire [32:0] iyp  = iy21 * {1'b0, sy_step};
    wire [15:0] sy   = iyp[29:14];
    wire [15:0] sxc  = (sx  >= (w0 - 16'd1)) ? (w0 - 16'd1) : sx;
    wire [15:0] syc  = (sy  >= (h0 - 16'd1)) ? (h0 - 16'd1) : sy;
    wire        row_ok = (rows_done > syc);
    // ---- v12 (B3-lite) 源侧限流 ----
    // 环 = 4 槽，行 r 写入 slot=r%4；读侧读 slot=syc%4，其内容是"最后一个写入该槽的行"。
    // 只要"行 syc+4 永不被写"，slot syc%4 就必然仍是行 syc 本身（行 syc 之后同槽再无写入）。
    // 故安全不变式 = rows_done <= syc+3（rows_done==syc+4 即正在写行 syc+4）。
    // 上游 bmp_read 在"扇区间隙"响应 pause；一个在飞扇区最多 512B=170px=0.21 行。
    // 取门限 syc+2：在飞扇区落地后 rows_done <= syc+2+0.21 < syc+3，不变式恒成立。
    // pass=1（恰 640x480 直通）时不走环形缓存，无需限流。
    wire [16:0] syc_g2  = {1'b0, syc} + 17'd2;
    wire        pause_c = !pass && ({1'b0, rows_done} >= syc_g2);
    wire        iny    = (dy >= offy) && (dy <  (offy + dst_h));
    wire        inx    = (dx >= offx) && (dx <  (offx + dst_w));
    wire        a_blk  = !(iny && inx);
    wire [12:0] rd_addr = {syc[1:0], sxc[10:0]};
    wire [12:0] wr_addr = {wr_slot,  wr_i[10:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=1'b0; actq<=1'b0; pass<=1'b0; eovr<=1'b0;            sw1<=16'd640; sh1<=16'd480;
            w0<=16'd640; h0<=16'd480; wide<=1'b1;
            t_nd<=16'd0; sx_step<=16'd8192; sy_step<=16'd8192;
            dst_w<=16'd640; dst_h<=16'd480; offx<=16'd0; offy<=16'd0;
            dn<=24'd0; da<=17'd0; dq<=24'd0; dc<=5'd0; dbz<=1'b0;
            dden<=16'd1; qres<=24'd0;
            ld0<=1'b0; ld1<=1'b0; ld2<=1'b0;
            rows_done<=16'd0; wr_slot<=2'd0; wr_i<=16'd0;
            dy<=16'd0; dx<=16'd0; a_black<=1'b0; a_go<=1'b0; fd_pend<=1'b0;
            ram_q<=24'd0; rd_tick<=5'd0;
            out_en<=1'b0; out_data<=32'd0; frame_done<=1'b0; src_pause<=1'b0;
        end else begin
            out_en <= 1'b0; frame_done <= 1'b0;
            src_pause <= pause_c;          // v12: 源侧限流请求（寄存器输出，避免毛刺到 SD 侧）
            actq <= st;
            sq   <= st ? ((sq < 7'd81) ? (sq + 7'd1) : sq) : 7'd0;
            ld0  <= actq && (sq == 7'd1);   // v16b: no port read outside dispatch (TD law)
            ld1  <= actq && (sq == 7'd28);
            ld2  <= actq && (sq == 7'd54);

            if (in_sov) begin           // b-19 (链C): sov 无条件重启帧。旧 (st==0) 合取会把
                //   被半途 abort 撕掉的帧永久钉死（eov 不再来→eovr 不置→row_ok 卡输出、
                //   st 恒 1、下一帧 sov 被吞、几何冻结成烂尾帧旧值）。重启体本就复位
                //   全帧态（rows_done/wr_slot/wr_i/dy/dx/eovr/pass/几何锁存），语义等价
                //   "每帧都是新起点"。640×480 路 sov 到达时 st 恒 0（上帧 in_eov 拍已归零），
                //   删合取对其逐拍无影响。
                w0 <= src_w; h0 <= src_h;
                sw1 <= src_w; sh1 <= src_h;

                wide  <= est_c;
                pass  <= guard_c;
                rows_done <= 16'd0; wr_slot <= 2'd0; wr_i <= 16'd0;
                dy<=16'd0; dx<=16'd0; a_go<=1'b0; fd_pend<=1'b0; eovr<=1'b0;
                t_nd <= 16'd0; sq   <= 7'd0;
                rd_tick <= 5'd0; // b-22/v12.1: 每帧起点对齐出货节奏相位
                st   <= 1'b1;
            end
            if (in_eov && actq) eovr <= 1'b1;

            // ---- 内联除法：装载优先，else-if 续迭代 ----
            if (ld0) begin
                dn   <= est_w ? ({sh1, 9'd0} + {2'd0, sh1, 7'd0})
                              : ({sw1, 9'd0} - {4'd0, sw1, 5'd0});
                dden <= est_w ? sw1 : sh1;
                da <= 17'd0; dq <= 24'd0; dc <= 5'd0; dbz <= 1'b1;
            end else if (ld1) begin
                dn   <= {8'd0, w0} * 24'd8192;
                dden <= wide ? DST_W : tclamp;
                da <= 17'd0; dq <= 24'd0; dc <= 5'd0; dbz <= 1'b1;
            end else if (ld2) begin
                dn   <= {8'd0, h0} * 24'd8192;
                dden <= wide ? tclamp : DST_H;
                da <= 17'd0; dq <= 24'd0; dc <= 5'd0; dbz <= 1'b1;
            end else if (dbz) begin
                da <= dna;
                dq <= dnext;
                dn <= {dn[22:0], 1'b0};
                dc <= dc + 5'd1;
                if (dc == 5'd23) begin
                    dbz  <= 1'b0;
                    qres <= dnext;
                end
            end
            if (cp1) t_nd    <= qclamp;
            if (cp2) sx_step <= qclamp;
            if (fn7) begin
                sy_step <= qclamp;
                dst_w   <= wide ? DST_W : t_nd;
                dst_h   <= wide ? t_nd : DST_H;
                offx    <= (DST_W - (wide ? DST_W : t_nd)) >> 1;
                offy    <= (DST_H - (wide ? t_nd : DST_H)) >> 1;

            end

            // ---- S1：源行顺序写 ----
            if (actq && !pass && in_en) begin
                ring[wr_addr] <= in_data[31:8];
                if (wr_i == (w0 - 16'd1)) begin
                    wr_i    <= 16'd0;
                    wr_slot <= wr_slot + 2'd1;
                    rows_done <= rows_done + 16'd1;
                end else begin
                    wr_i <= wr_i + 16'd1;
                end
            end

            // ---- S2 出货（直通 or 缩放） ----
            if (pass) begin
                out_en   <= in_en;
                out_data <= in_data;
                if (in_en && in_eov) begin st <= 1'b0; frame_done <= 1'b1; end
            end else begin
                if (a_go) begin
                    out_en   <= 1'b1;
                    out_data <= {a_black ? 24'd0 : ram_q, 8'h00};
                    a_go     <= 1'b0;
                    if (fd_pend) begin fd_pend<=1'b0; frame_done<=1'b1; st<=1'b0; end
                end
                if (actq && (dy < DST_H)) begin
                    if ((row_ok || eovr) && (pass || rd_gate)) begin   // v12.1: 缩放路 1字/32拍(去突发化, 见 rd_gate 注释)
                        ram_q   <= ring[rd_addr];
                        a_black <= a_blk;
                        a_go    <= 1'b1;
                        if (dx == (DST_W - 16'd1)) begin
                            dx <= 16'd0; dy <= dy + 16'd1;
                            if (dy == (DST_H - 16'd1)) fd_pend <= 1'b1;
                        end else dx <= dx + 16'd1;
                    end
                end
                rd_tick <= rd_tick + 5'd1;   // v12.1 自由计数（直通 pass 旁路节奏门，零变化）
            end
        end
    end
endmodule
`default_nettype wire
