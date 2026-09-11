//=============================================================================
// tb_geom_probe.v -- 判定性探针：花屏到底是「几何算错」还是「读错行」
//
// 方法：直接观察 DUT 内部几何寄存器 + 每输出行的实际 rd_addr。
//   若 sx_step/sy_step/offx/offy/dst_* 在跑偏的那一帧里就已经是错值
//     -> 几何(除法/定点)缺陷
//   若几何值完全正确、但 ring[] 被读到的内容对不上 syc
//     -> 缓冲/流控缺陷
//
// 源合成与 tb_scaler_burst 完全一致：R=x[7:0] G=y[7:0] B=(x+y)[7:0]
//   -> 800x600 全宽缩放，offx=offy=0, sx_step=sy_step=10240
//   -> 理论映射 dx->sxc=floor((2dx+1)*10240>>14), dy->syc 同理
//
// 用法:
//   iverilog -DBURST_LEN_OVR=4096 -o g.vvp -s tb_geom_probe tb_geom_probe.v img_scaler.v
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

`ifndef BURST_LEN_OVR
`define BURST_LEN_OVR 4096
`endif

module tb_geom_probe;
    localparam SRC_W = 800;
    localparam SRC_H = 600;
    localparam BURST_LEN = `BURST_LEN_OVR;
    localparam BURST_GAP = 6000;

    reg clk = 0, rst_n = 0;
    reg in_en = 0, in_sov = 0, in_eov = 0;
    reg [31:0] in_data = 0;
    reg [15:0] src_w = SRC_W, src_h = SRC_H;

    wire out_en, frame_done;
    wire [31:0] out_data;

    img_scaler u_dut (
        .clk(clk), .rst_n(rst_n), .in_en(in_en), .in_data(in_data),
        .src_w(src_w), .src_h(src_h), .in_sov(in_sov), .in_eov(in_eov),
        .out_en(out_en), .out_data(out_data), .frame_done(frame_done)
    );

    always #5 clk = ~clk;

    integer src_col, src_row, burst_rem, gap_rem, feeding, timeout, n_out;
    integer fp;

    function [23:0] pix_at;
        input [15:0] x, y;
        begin pix_at = {x[7:0], y[7:0], x[7:0] + y[7:0]}; end
    endfunction

    // ---- 参考几何（Q14 定点，与 DUT 同式）----
    localparam integer SX_STEP = (SRC_W * 8192) / 640;   // 10240
    localparam integer SY_STEP = (SRC_H * 8192) / 480;   // 10240
    function integer ref_sx; input integer dx;
        begin ref_sx = (((2*dx + 1) * SX_STEP) >> 14); end
    endfunction
    function integer ref_sy; input integer dy;
        begin ref_sy = (((2*dy + 1) * SY_STEP) >> 14); end
    endfunction

    // 每次输出一个像素，报告 DUT 几何快照
    always @(posedge clk) if (rst_n && out_en) begin
        n_out = n_out + 1;
    end

    initial fp = $fopen("geom_probe.txt", "w");

    // 每 480 个输出像素（= 跑完一行）打印一次内部几何
    integer last_rep;
    always @(posedge clk) begin
        if (rst_n && out_en) begin
            // 在每行末尾报告：DUT 的 sx_step/sy_step/dst/off + 当前 dy/dx 与 ring 读地址
            if (u_dut.dx == 16'd639) begin
                $fwrite(fp, "OUTROW dy=%0d  dst_w/h=%0d/%0d off=(%0d,%0d) sx_step=%0d sy_step=%0d t_nd=%0d wide=%b pass=%b\n",
                        u_dut.dy, u_dut.dst_w, u_dut.dst_h, u_dut.offx, u_dut.offy,
                        u_dut.sx_step, u_dut.sy_step, u_dut.t_nd, u_dut.wide, u_dut.pass);
            end
        end
    end

    // 监听：当 DUT 要读 ring 时，把「DUT 认为要读的 syc」和「参考几何的 syc」都记下来
    // 采样 a_go（= ram_q 将被推出的那一拍）
    integer rowmis;
    initial rowmis = 0;
    reg [15:0] prev_dy;
    initial prev_dy = 16'hFFFF;
    always @(posedge clk) begin
        if (rst_n && u_dut.a_go) begin
            // 这一拍推出的像素对应 (dy-1, 639)? 太绕。改为：记录每行起点比对。
        end
        if (rst_n && u_dut.dx == 16'd0 && u_dut.dy != prev_dy && u_dut.dy < 16'd480) begin
            prev_dy <= u_dut.dy;
            // DUT 此刻算出的 syc 应当等于 ref_sy(dy)
            $fwrite(fp, "ROWMAP dy=%0d  dut_syc=%0d  ref_syc=%0d  %s\n",
                    u_dut.dy, u_dut.syc, ref_sy(u_dut.dy),
                    (u_dut.syc == ref_sy(u_dut.dy)) ? "OK" : "MISMATCH");
        end
    end

    initial begin
        n_out = 0; feeding = 0;
        src_col = 0; src_row = 0; burst_rem = BURST_LEN; gap_rem = 0;
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);
        @(negedge clk); in_sov = 1;
        @(negedge clk); in_sov = 0;
        @(negedge clk);
        feeding = 1; in_en = 1; in_data = {pix_at(0,0), 8'h00};

        timeout = 0;
        while (feeding && timeout < 80_000_000) begin @(posedge clk); timeout = timeout + 1; end
        timeout = 0;
        while (!frame_done && timeout < 80_000_000) begin @(posedge clk); timeout = timeout + 1; end
        repeat (5) @(posedge clk);

        $display("=== GEOM PROBE BURST=%0d ===", BURST_LEN);
        $display("out px = %0d", n_out);
        $display("final geom: sx_step=%0d sy_step=%0d dst=%0dx%0d off=(%0d,%0d) t_nd=%0d wide=%b",
                 u_dut.sx_step, u_dut.sy_step, u_dut.dst_w, u_dut.dst_h,
                 u_dut.offx, u_dut.offy, u_dut.t_nd, u_dut.wide);
        $fclose(fp);
        $finish;
    end

    // 上游 push 源（无视 DUT）
    always @(negedge clk) begin
        if (feeding) begin
            if (gap_rem > 0) begin
                gap_rem <= gap_rem - 1; in_en <= 0; in_eov <= 0;
            end else if (burst_rem > 0) begin
                if (src_row >= SRC_H) begin
                    feeding <= 0; in_en <= 0; in_eov <= 0;
                end else begin
                    burst_rem <= burst_rem - 1;
                    in_en <= 1;
                    in_data <= {pix_at(src_col[15:0], src_row[15:0]), 8'h00};
                    in_eov <= ((src_col == SRC_W-1) && (src_row == SRC_H-1)) ? 1 : 0;
                    if (src_col == SRC_W-1) begin src_col <= 0; src_row <= src_row + 1; end
                    else src_col <= src_col + 1;
                    if (burst_rem == 1) gap_rem <= BURST_GAP;
                end
            end else begin
                burst_rem <= BURST_LEN;
            end
        end else begin
            in_en <= 0; in_data <= 0; in_eov <= 0;
        end
    end
endmodule
`default_nettype wire
