//=============================================================================
// tb_scaler_golden_A.v — 面向 fix-A（真握手背压）的像素级 golden 复验台
//
// 与 tb_scaler_golden.v 的差别：上游服从 in_ready 背压，不再盲目灌数据。
// 这是真 ready/valid 握手应有的行为，也是 A 方案能否生效的前提。
//
// 用法：
//   iverilog -o tb_A.out -s tb_scaler_golden_A tb_scaler_golden_A.v img_scaler_A.v
//   vvp tb_A.out
//   => 产出 scaler_out_A.txt
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_scaler_golden_A;

    localparam SRC_W = 800;
    localparam SRC_H = 600;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg        in_en = 1'b0;
    reg [31:0] in_data = 32'd0;
    reg        in_sov = 1'b0;
    reg        in_eov = 1'b0;
    reg [15:0] src_w = SRC_W[15:0];
    reg [15:0] src_h = SRC_H[15:0];

    wire        out_en;
    wire [31:0] out_data;
    wire        frame_done;
    wire        in_ready;

    img_scaler_A u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_en      (in_en),
        .in_data    (in_data),
        .src_w      (src_w),
        .src_h      (src_h),
        .in_sov     (in_sov),
        .in_eov     (in_eov),
        .out_en     (out_en),
        .out_data   (out_data),
        .frame_done (frame_done),
        .in_ready   (in_ready)
    );

    always #5 clk = ~clk;

    integer fp, n_out, timeout, stall_cycles;
    integer pixels_sent;
    integer ftr;
    reg do_trace;
    integer tr_n;

    // ---- 层次化 probe：只在关心的窗口打开，避免文件爆炸 ----
    initial begin
        ftr = $fopen("scaler_trace_A.txt", "w");
        do_trace = 0;
        tr_n = 0;
    end

    function [23:0] pix_at;
        input [15:0] x, y;
        reg [7:0] r8, g8, b8;
        begin
            r8 = x[7:0];
            g8 = y[7:0];
            b8 = x[7:0] + y[7:0];
            pix_at = {r8, g8, b8};
        end
    endfunction

    integer x, y;
    integer waitcnt;

    initial begin
        fp = $fopen("scaler_out_A.txt", "w");
        if (fp == 0) begin
            $display("ERROR: cannot open scaler_out_A.txt");
            $finish;
        end
    end

    initial begin
        rst_n = 0; in_en = 0; in_sov = 0; in_eov = 0; in_data = 0;
        n_out = 0; pixels_sent = 0; stall_cycles = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        @(posedge clk);
        in_sov <= 1'b1;
        @(posedge clk);
        in_sov <= 1'b0;

        for (y = 0; y < SRC_H; y = y + 1) begin
            for (x = 0; x < SRC_W; x = x + 1) begin
                // ---- honour backpressure: hold until in_ready ----
                waitcnt = 0;
                while (!in_ready && waitcnt < 50_000_000) begin
                    @(posedge clk);
                    in_en   <= 1'b0;
                    waitcnt = waitcnt + 1;
                    stall_cycles = stall_cycles + 1;
                end
                if (waitcnt >= 50_000_000) begin
                    $display("### DEADLOCK: in_ready stuck at src=(%0d,%0d)", x, y);
                    $fclose(fp);
                    $finish;
                end
                @(posedge clk);
                in_en   <= 1'b1;
                in_data <= {pix_at(x[15:0], y[15:0]), 8'h00};
                in_eov  <= ((x == SRC_W - 1) && (y == SRC_H - 1)) ? 1'b1 : 1'b0;
                pixels_sent = pixels_sent + 1;
            end
        end
        @(posedge clk);
        in_en  <= 1'b0;
        in_eov <= 1'b0;

        timeout = 0;
        while (!frame_done && timeout < 50_000_000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        @(posedge clk);

        $display("=== IMG_SCALER fix-A PIXEL RUN ===");
        $display("src = %0d x %0d  (pixels sent %0d)", SRC_W, SRC_H, pixels_sent);
        $display("backpressure stall cycles = %0d (upstream throttled)", stall_cycles);
        $display("out pixels captured = %0d (expect %0d)", n_out, 640*480);
        $display("timeout cycles waited = %0d", timeout);
        if (n_out != 640*480)
            $display("### PIXEL COUNT MISMATCH: %0d", n_out);
        else
            $display("### pixel count OK");
        $fclose(fp);
        $finish;
    end

    reg [23:0] pr0;
    always @(posedge clk) begin
        if (rst_n && u_dut.st && !u_dut.pass && (u_dut.ring[0] !== pr0)) begin
            $fwrite(ftr,
              "R0CHG t=%0d ring0=%06h in=%06h wr_a=%0h wr_i=%0d ws=%0d rows=%0d dy=%0d dx=%0d\n",
                $time, u_dut.ring[0], in_data[31:8], u_dut.wr_addr, u_dut.wr_i,
                u_dut.wr_slot, u_dut.rows_done, u_dut.dy, u_dut.dx);
        end
        pr0 <= u_dut.ring[0];
    end

    always @(posedge clk) begin
        if (rst_n && out_en) begin
            $fwrite(fp, "%06h\n", out_data[31:8]);
            n_out = n_out + 1;
        end
    end

    always @(posedge clk) begin
        // dy==3 那一行：每一拍全记录（占位符严格对齐 11 个参数）
        if (rst_n && u_dut.st && !u_dut.pass && u_dut.dy == 16'd3 && tr_n < 4000) begin
            $fwrite(ftr,
              "dy=%0d dx=%0d hc=%0d ro=%0b go=%0b oe=%0b rd=%0h sxc=%0d syc=%0d ie=%0b wr_a=%0h wr_i=%0d ws=%0d r0=%06h r1=%06h r2=%06h rq=%06h\n",
                u_dut.dy, u_dut.dx, u_dut.half_cnt, u_dut.row_ok, u_dut.a_go,
                out_en, u_dut.rd_addr, u_dut.sxc, u_dut.syc, in_en,
                u_dut.wr_addr, u_dut.wr_i, u_dut.wr_slot,
                u_dut.ring[0], u_dut.ring[1], u_dut.ring[2],
                u_dut.ram_q);
            tr_n = tr_n + 1;
        end
    end

endmodule
`default_nettype wire
