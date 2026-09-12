//=============================================================================
// tb_scaler_real.v -- 真实 SD 速率下的 img_scaler 全面校验
//
// 动机：既有 TB(tb_scaler_burst) 把上游建成 "1 像素/拍"，比真板 SD 快 ~100 倍。
//       真板 SPI = 25MHz => 1 字节 ~32 拍 => 1 像素(3B) ~96-180 拍。
//       本 TB 按真速率建源，验证缩放链路在**真板条件下**到底对不对。
//
// 源图样：每像素唯一可解码 -> R=x[7:0] G=y[7:0] B={x[11:8],y[11:8]}
//         故 4096x4096 内 (x,y) 可唯一还原，比对无需 golden 模型。
//
// 几何参考 = 按设计意图(fit 640x480 保持宽高比, 最近邻, Q14 定点)独立算，
//          不引用 DUT 内部寄存器，避免"同错抵消"。
//
// 用法: iverilog -g2005 -DSRC_W=800 -DSRC_H=600 -DT_PX=180 -o r.vvp \
//            -s tb_scaler_real tb_scaler_real.v <img_scaler.v>
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

`ifndef SRC_W
`define SRC_W 800
`endif
`ifndef SRC_H
`define SRC_H 600
`endif
`ifndef T_PX
`define T_PX 180       // 每像素拍数(真板 ~96-180)
`endif
`ifndef SEC_PX
`define SEC_PX 170     // 每扇区产出的像素数(512B/3)
`endif
`ifndef GAP_CLK
`define GAP_CLK 0      // 扇区之间空窗拍数(真板可达 2.7 万拍, 这里 0=最坏连续)
`endif
`ifndef USE_PAUSE
`define USE_PAUSE 1    // 1=源尊重 src_pause(真板行为)
`endif

module tb_scaler_real;
    localparam SW = `SRC_W;
    localparam SH = `SRC_H;
    localparam TPX = `T_PX;
    localparam SECPX = `SEC_PX;
    localparam GAPC = `GAP_CLK;

    reg clk = 0, rst_n = 0;
    reg in_en = 0, in_sov = 0, in_eov = 0;
    reg [31:0] in_data = 0;
    reg [15:0] src_w = SW, src_h = SH;

    wire out_en, frame_done, src_pause;
    wire [31:0] out_data;

    img_scaler u_dut (
        .clk(clk), .rst_n(rst_n), .in_en(in_en), .in_data(in_data),
        .src_w(src_w), .src_h(src_h), .in_sov(in_sov), .in_eov(in_eov),
        .out_en(out_en), .out_data(out_data), .frame_done(frame_done),
        .src_pause(src_pause)
    );

    always #5 clk = ~clk;

    // ---------------- 设计意图几何(独立于 DUT 内部寄存器) ----------------
    localparam integer E_L = SW*512 - SW*32;      // w*480
    localparam integer E_R = SH*512 + SH*128;     // h*640
    localparam integer EST_W = (E_L >= E_R) ? 1 : 0;
    localparam integer T_ND  = EST_W ? ((SH*640)/SW) : ((SW*480)/SH);
    localparam integer TND_C = (T_ND == 0) ? 1 : T_ND;
    localparam integer SXSTEP = (SW*8192) / (EST_W ? 640 : TND_C);
    localparam integer SYSTEP = (SH*8192) / (EST_W ? TND_C : 480);
    localparam integer DSTW = EST_W ? 640 : TND_C;
    localparam integer DSTH = EST_W ? TND_C : 480;
    localparam integer OFFX = (640 - DSTW) >> 1;
    localparam integer OFFY = (480 - DSTH) >> 1;

    // 期望: 只能在"图片矩形"内期望图像内容; 矩形外(letterbox 四边)一律应为黑。
    //   ★ 2026-09-12 修正: 旧版只判 dy<OFFY(上边), 漏判下边/左右边, 导致
    //     凡是带黑边的分辨率(off!=0)全被误判 FAIL(失败像素数恰好=黑边像素数)。
    wire in_rect = (odx >= OFFX) && (odx < OFFX+DSTW) &&
                   (ody >= OFFY) && (ody < OFFY+DSTH);

    function integer exp_sx; input integer dx;
        begin
            if (dx < OFFX) exp_sx = -1;
            else begin
                exp_sx = (((2*(dx-OFFX)+1) * SXSTEP) >> 14);
                if (exp_sx > SW-1) exp_sx = SW-1;
            end
        end
    endfunction
    function integer exp_sy; input integer dy;
        begin
            if (dy < OFFY) exp_sy = -1;
            else begin
                exp_sy = (((2*(dy-OFFY)+1) * SYSTEP) >> 14);
                if (exp_sy > SH-1) exp_sy = SH-1;
            end
        end
    endfunction

    integer n_out, bad, row_bad, rows_bad_total, first_bad_dx, first_bad_dy, n_bad_print;
    integer got_x, got_y, want_x, want_y;
    integer timeout, feeding, push_cnt, gap_rem, sec_rem;

    // ---------------- 源: 1 像素 / TPX 拍, 每 SECPX 像素插 GAPC 空窗 ----------------
    integer tick;
    initial tick = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (feeding) begin
                if (tick < TPX-1) tick <= tick + 1;
                else tick <= 0;
            end else tick <= 0;
        end
    end

`ifdef NOUSE_PAUSE
    wire src_hold = 1'b0;
`else
    wire src_hold = src_pause;    // 真板: bmp_read 在扇区间隙看 pause
`endif

    always @(negedge clk) begin
        if (!rst_n) begin
            in_en <= 0; in_eov <= 0;
        end else if (feeding) begin
            if (gap_rem > 0) begin
                gap_rem <= gap_rem - 1; in_en <= 0; in_eov <= 0;
            end else if (tick != TPX-1) begin
                in_en <= 0; in_eov <= 0;             // 字节间隙
            end else if (src_hold) begin
                in_en <= 0; in_eov <= 0;             // 被限流
            end else if (push_cnt >= SW*SH) begin
                feeding <= 0; in_en <= 0; in_eov <= 0;
            end else begin
                in_en   <= 1;
                // 关键: 寄存"本拍将要推出的像素", 否则与 push_cnt 的自增错开一拍
                push_pix <= {px_x[7:0], px_y[7:0], px_x[11:8], px_y[11:8]};
                in_eov  <= (push_cnt == SW*SH-1) ? 1'b1 : 1'b0;
                push_cnt <= push_cnt + 1;
                sec_rem <= sec_rem - 1;
                if (sec_rem == 1) begin
                    sec_rem <= SECPX;
                    gap_rem <= GAPC;
                end
            end
        end else begin
            in_en <= 0; in_eov <= 0;
        end
    end

    // 像素值: 24 位样图必须落在 in_data[31:8]（scaler 取的就是 [31:8]）
    //   R=x[7:0] G=y[7:0] B={x[11:8],y[11:8]}
    integer px_x, px_y;
    reg [23:0] push_pix;
    always @(*) begin
        px_x = push_cnt % SW;
        px_y = push_cnt / SW;
    end
    always @(*) in_data = {push_pix, 8'h00};

    // ---------------- 输出逐像素比对 ----------------
    integer odx, ody;
    integer e_x, e_y, a_x, a_y;
    initial begin odx = 0; ody = 0; end
    always @(posedge clk) begin
        if (rst_n && out_en) begin
            n_out = n_out + 1;
            if (ody < 480) begin
                e_x = exp_sx(odx); e_y = exp_sy(ody);
                // 解码: R=[31:24]=x[7:0]  G=[23:16]=y[7:0]  B=[15:8]={x[11:8],y[11:8]}
                a_x = out_data[31:24] | (out_data[15:12] << 8);
                a_y = out_data[23:16] | (out_data[11:8]  << 8);
                if (!in_rect) begin
                    // letterbox 四边: 必须是纯黑 (R=G=B=0)
                    if (out_data[31:8] != 24'd0) begin
                        bad = bad + 1; row_bad = row_bad + 1;
                        if (n_bad_print < 12) begin
                            n_bad_print = n_bad_print + 1;
                            $display("MISMATCH #%0d (border) dst(%0d,%0d) got=%0d,%0d raw=%08x",
                                     n_bad_print, odx, ody, a_x, a_y, out_data);
                        end
                        if (bad == 1) begin first_bad_dx = odx; first_bad_dy = ody; end
                    end
                end else if ((a_x != e_x) || (a_y != e_y)) begin
                    bad = bad + 1; row_bad = row_bad + 1;
                    if (n_bad_print < 12) begin
                        n_bad_print = n_bad_print + 1;
                        $display("MISMATCH #%0d dst(%0d,%0d) got=%0d,%0d want=%0d,%0d  raw=%08x",
                                 n_bad_print, odx, ody, a_x, a_y, e_x, e_y, out_data);
                    end
                    if (bad == 1) begin
                        first_bad_dx = odx; first_bad_dy = ody;
                        got_x = a_x; got_y = a_y; want_x = e_x; want_y = e_y;
                    end
                end
                if (odx == 639) begin
                    odx = 0;
                    if (row_bad) rows_bad_total = rows_bad_total + 1;
                    row_bad = 0;
                    ody = ody + 1;
                end else odx = odx + 1;
            end
        end
    end

    initial begin
        n_out = 0; bad = 0; row_bad = 0; rows_bad_total = 0; n_bad_print = 0;
        first_bad_dx = -1; first_bad_dy = -1;
        feeding = 0; push_cnt = 0; sec_rem = SECPX; gap_rem = 0; push_pix = 24'd0;
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);
        @(negedge clk); in_sov = 1;
        @(negedge clk); in_sov = 0;
        @(negedge clk);
        feeding = 1;

        timeout = 0;
        while (feeding && timeout < 200_000_000) begin @(posedge clk); timeout = timeout + 1; end
        timeout = 0;
        while (!frame_done && timeout < 200_000_000) begin @(posedge clk); timeout = timeout + 1; end
        repeat (3) @(posedge clk);

        $display("=== tb_scaler_real  src=%0dx%0d  T_PX=%0d  SEC_PX=%0d  GAP=%0d  pause=%0d ===",
                 SW, SH, TPX, SECPX, GAPC, `USE_PAUSE);
        $display("geom: est_w=%0d t_nd=%0d sx_step=%0d sy_step=%0d dst=%0dx%0d off=(%0d,%0d)",
                 EST_W, TND_C, SXSTEP, SYSTEP, DSTW, DSTH, OFFX, OFFY);
        $display("pushed=%0d/%0d  out=%0d/307200  frame_done=%b", push_cnt, SW*SH, n_out, frame_done);
        $display("wrong px=%0d  rows_with_err=%0d", bad, rows_bad_total);
        if (first_bad_dx >= 0)
            $display("first err @dst(%0d,%0d) got_src=(%0d,%0d) want_src=(%0d,%0d)",
                     first_bad_dx, first_bad_dy, got_x, got_y, want_x, want_y);
        if (bad == 0 && n_out == 640*480) $display("### VERDICT: PASS");
        else $display("### VERDICT: FAIL");
        $finish;
    end
endmodule
`default_nettype wire
