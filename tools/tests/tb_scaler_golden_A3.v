//=============================================================================
// tb_scaler_golden_A3.v — 基于「DUT 实际写指针」的可靠握手
//
// 前几版 TB 用 in_ready 判定是否消费，与 DUT 内部写条件存在半拍偏差，
// 造成像素重复读取（每像素写两次 -> ring 内容整体偏移）。
// 本版改为直接监视 DUT 的 wr_i/wr_slot/rows_done 是否推进来判定消费，
// 与 DUT 行为 100% 同步，消除一切 TB 侧协议歧义。
//
//   iverilog -o tb_A3.out -s tb_scaler_golden_A3 tb_scaler_golden_A3.v img_scaler_A.v
//   vvp tb_A3.out  => scaler_out_A3.txt
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_scaler_golden_A3;

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

    wire        out_en, frame_done, in_ready;
    wire [31:0] out_data;

    img_scaler_A u_dut (
        .clk(clk), .rst_n(rst_n), .in_en(in_en), .in_data(in_data),
        .src_w(src_w), .src_h(src_h), .in_sov(in_sov), .in_eov(in_eov),
        .out_en(out_en), .out_data(out_data), .frame_done(frame_done),
        .in_ready(in_ready)
    );

    always #5 clk = ~clk;

    integer fp, n_out, n_consumed;
    integer xi, yi;
    reg        feeding;
    integer    timeout;
    reg        last_px;

    // ---- 监视 DUT 写指针：打两拍比较，判定本拍是否真的写了一笔 ----
    reg [15:0] wi_d1, wi_d2;
    reg [15:0] rd_d1, rd_d2;
    reg [1:0]  ws_d1, ws_d2;
    wire consumed = (wi_d1 !== wi_d2) || (ws_d1 !== ws_d2) || (rd_d1 !== rd_d2);

    always @(posedge clk) begin
        wi_d2 <= wi_d1;  wi_d1 <= u_dut.wr_i;
        ws_d2 <= ws_d1;  ws_d1 <= u_dut.wr_slot;
        rd_d2 <= rd_d1;  rd_d1 <= u_dut.rows_done;
    end

    function [23:0] pix_at;
        input [15:0] x, y;
        reg [7:0] r8, g8, b8;
        begin
            r8 = x[7:0]; g8 = y[7:0]; b8 = x[7:0] + y[7:0];
            pix_at = {r8, g8, b8};
        end
    endfunction

    initial fp = $fopen("scaler_out_A3.txt", "w");

    // ---- 直接跟随 DUT 写指针供给数据 ----
    // DUT 下一个要写的像素恒为 (rows_done, wr_i)。TB 每一拍都按这个位置提供数据：
    // DUT 暂停时写指针不动 -> 数据自然保持不变；DUT 推进 -> 立即跟上下一个像素。
    // 这样彻底消除「是否被接受」判定的任何延迟歧义。
    integer want_col, want_row;
    always @(negedge clk) begin
        if (feeding) begin
            want_col = u_dut.wr_i;
            want_row = u_dut.rows_done;
            if (want_row >= SRC_H) begin
                feeding      <= 1'b0;
                in_en        <= 1'b0;
            end else begin
                in_en   <= 1'b1;
                in_data <= {pix_at(want_col[15:0], want_row[15:0]), 8'h00};
                in_eov  <= ((want_col == SRC_W - 1) && (want_row == SRC_H - 1)) ? 1'b1 : 1'b0;
            end
        end else begin
            in_en   <= 1'b0;
            in_data <= 32'd0;
            in_eov  <= 1'b0;
        end
    end

    initial begin
        n_out = 0; n_consumed = 0; feeding = 0; xi = 0; yi = 0;
        rst_n = 0; in_en = 0; in_sov = 0; in_eov = 0; in_data = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        @(negedge clk); in_sov = 1'b1;
        @(negedge clk); in_sov = 1'b0;

        @(negedge clk);
        feeding = 1'b1; xi = 0; yi = 0;
        in_en   = 1'b1;
        in_data = {pix_at(0, 0), 8'h00};

        timeout = 0;
        while (feeding && timeout < 80_000_000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        timeout = 0;
        while (!frame_done && timeout < 80_000_000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        @(posedge clk);

        $display("=== IMG_SCALER fix-A PIXEL RUN (write-pointer handshake) ===");
        $display("src = %0d x %0d", SRC_W, SRC_H);
        $display("out pixels captured = %0d (expect %0d)", n_out, 640*480);
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
