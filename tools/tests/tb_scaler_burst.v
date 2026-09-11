//=============================================================================
// tb_scaler_burst.v — 真实数据源模型 TB（判定 A 的 in_ready 是否有意义）
//
// 背景：板上真实像素源是 SD 卡 SPI 扇区读，数据以「扇区间歇 + 扇区内连续」的
//       突发形式到达，不是 TB 里的连续每拍供给。A 方案（写侧门控 room_ok）
//       只有在「写侧停滞时上游能同步停住」才有效；若上游是 push 模式，
//       门控只是丢数据（frame_fifo_write 永远收不满 307200 字 -> 卡死）。
//
// 本 TB 分别用两种源模型跑同一份 DUT：
//   MODE=0  CONTINUOUS : 上游跟随 DUT 写指针（旧 A3 模型的理想源）
//   MODE=1  BURST_PUSH : 上游按固定节奏狂推，无视 in_ready（=板上真实 SD 行为）
//
// 输出：scaler_out_burst.txt（MODE 由 +define+MODE=n 选择）
//
//   iverilog -DMODE=1 -o tb_burst.out -s tb_scaler_burst tb_scaler_burst.v <dut>.v
//   vvp tb_burst.out
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

`ifndef MODE
`define MODE 1
`endif

module tb_scaler_burst;

    localparam SRC_W = 800;
    localparam SRC_H = 600;
    // 板上节奏：SD 扇区读 512 字节 @ ~6.25MB/s，SD 域 100MHz
    //   -> 512 字约 8192 clk；扇区之间空档约 6000 clk（保守取 1/2 占空）
`ifdef BURST_LEN_OVR
    localparam BURST_LEN  = `BURST_LEN_OVR;
`else
    localparam BURST_LEN  = 1024;
`endif
    localparam BURST_GAP  = 6000;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg        in_en = 1'b0;
    reg [31:0] in_data = 32'd0;
    reg        in_sov = 1'b0;
    reg        in_eov = 1'b0;
    reg [15:0] src_w = SRC_W[15:0];
    reg [15:0] src_h = SRC_H[15:0];

    wire        out_en, frame_done, in_ready;
    wire [31:0] out_data;

    img_scaler u_dut (
        .clk(clk), .rst_n(rst_n), .in_en(in_en), .in_data(in_data),
        .src_w(src_w), .src_h(src_h), .in_sov(in_sov), .in_eov(in_eov),
        .out_en(out_en), .out_data(out_data), .frame_done(frame_done)
`ifdef HAS_READY
        , .in_ready(in_ready)
`endif
    );

    always #5 clk = ~clk;

    integer fp, n_out;
    reg        feeding;
    integer    timeout;

    // ---- 上游源指针（TB 自己维护，不跟随 DUT —— 这才是 push 源）----
    integer src_col, src_row;
    integer burst_rem, gap_rem;
    reg     last_px;

    function [23:0] pix_at;
        input [15:0] x, y;
        reg [7:0] r8, g8, b8;
        begin
            r8 = x[7:0]; g8 = y[7:0]; b8 = x[7:0] + y[7:0];
            pix_at = {r8, g8, b8};
        end
    endfunction

    initial fp = $fopen("scaler_out_burst.txt", "w");

`ifdef MODE_CONT
    // ---------- MODE 0: 理想连续源（跟随 DUT 写指针）----------
    always @(negedge clk) begin
        if (feeding) begin
            if (u_dut.rows_done >= SRC_H) begin
                feeding <= 1'b0;
                in_en   <= 1'b0;
            end else begin
                in_en   <= 1'b1;
                in_data <= {pix_at(u_dut.wr_i, u_dut.rows_done), 8'h00};
                in_eov  <= ((u_dut.wr_i == SRC_W-1) && (u_dut.rows_done == SRC_H-1)) ? 1'b1 : 1'b0;
            end
        end else begin
            in_en <= 1'b0; in_data <= 32'd0; in_eov <= 1'b0;
        end
    end
`else
    // ---------- MODE 1: 突发 push 源（无视 in_ready，模拟 SD 扇区读）----------
    always @(negedge clk) begin
        if (feeding) begin
            if (gap_rem > 0) begin
                gap_rem <= gap_rem - 1;
                in_en   <= 1'b0;
                in_eov  <= 1'b0;
            end else if (burst_rem > 0) begin
                if (src_row >= SRC_H) begin
                    feeding <= 1'b0;
                    in_en   <= 1'b0;
                    in_eov  <= 1'b0;
                end else begin
                    burst_rem <= burst_rem - 1;
                    in_en     <= 1'b1;
                    in_data   <= {pix_at(src_col[15:0], src_row[15:0]), 8'h00};
                    in_eov    <= ((src_col == SRC_W-1) && (src_row == SRC_H-1)) ? 1'b1 : 1'b0;
                    if (src_col == SRC_W-1) begin
                        src_col <= 0; src_row <= src_row + 1;
                    end else src_col <= src_col + 1;
                    if (burst_rem == 1) gap_rem <= BURST_GAP;
                end
            end else begin
                burst_rem <= BURST_LEN;
            end
        end else begin
            in_en <= 1'b0; in_data <= 32'd0; in_eov <= 1'b0;
        end
    end
`endif

    initial begin
        n_out = 0; feeding = 0;
        src_col = 0; src_row = 0; burst_rem = BURST_LEN; gap_rem = 0;
        rst_n = 0; in_en = 0; in_sov = 0; in_eov = 0; in_data = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        @(negedge clk); in_sov = 1'b1;
        @(negedge clk); in_sov = 1'b0;

        @(negedge clk);
        feeding = 1'b1;
        in_en   = 1'b1;
        in_data = {pix_at(0, 0), 8'h00};

        timeout = 0;
`ifdef MODE_CONT
        while (feeding && timeout < 80_000_000) begin
`else
        while (feeding && timeout < 80_000_000) begin
`endif
            @(posedge clk);
            timeout = timeout + 1;
        end

        timeout = 0;
        while (!frame_done && timeout < 80_000_000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        @(posedge clk);

        $display("=== BURST-SOURCE SCALER RUN ===");
        $display("src = %0d x %0d", SRC_W, SRC_H);
        $display("src pushed  = %0d px (expect %0d)", src_row*SRC_W + src_col, SRC_W*SRC_H);
        $display("out pixels  = %0d (expect %0d)", n_out, 640*480);
        $display("frame_done  = %b  feeding_end=%b", frame_done, ~feeding);
        if (n_out != 640*480) $display("### PIXEL COUNT MISMATCH: %0d", n_out);
        else                  $display("### pixel count OK");
        $fclose(fp);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && out_en) begin
            $fwrite(fp, "%06h\n", out_data[31:8]);
            n_out = n_out + 1;
        end
    end

endmodule
`default_nettype wire
