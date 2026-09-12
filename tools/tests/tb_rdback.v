//=============================================================================
// tb_rdback.v -- 定点验证「边写边读」：读 BUF0 的同时以真实涓流写 BUF1
//
// 真板场景：显示一直在读当前帧缓冲，而缩放器同时在写另一个缓冲。
//   若读写争用让 rfifo 供不上，读回的就是陈旧/重复数据 —— 表现为
//   整块纯色 / 竖条（dout 保持），而不是像素算错。
//
// 本台：先把 BUF0 快速写成一幅已知图 -> 然后**同时**：
//   (a) 显示模型按 640x480 逐像素读 BUF0
//   (b) 缩放器节奏(1字/32拍) 把另一幅图写进 BUF1
//   -> 比对读回的 BUF0 是否与写入完全一致（含 VFLIP）。
//
// 用法: iverilog -g2005 -o r.vvp -s tb_rdback tb_rdback.v \
//            frame_read_write.v frame_fifo_write.v frame_fifo_read.v <fifo ip>
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_rdback;
    localparam FRAME = 640*480;
    localparam WRITE_GAP = 32;      // 缩放器节奏: 1 字 / 32 拍

    reg sclk = 0, mclk = 0, vclk = 0;
    always #5    sclk = ~sclk;
    always #4    mclk = ~mclk;
    always #19.86 vclk = ~vclk;
    reg rst = 1'b1;

    // ---- 写侧激励 ----
    reg        wen = 0;
    reg [31:0] wdat = 0;
    reg        wreq = 0;
    reg  [1:0] widx = 2'd0;
    wire       wack, wfin;

    // ---- 读侧 ----
    reg        rreq = 0;
    wire       rack;
    reg        ren = 0;
    reg  [1:0] ridx = 2'd0;
    wire [31:0] rdat;

    wire App_wr_en, App_rd_en, Sdr_rd_en;
    wire [20:0] App_wr_addr, App_rd_addr;
    wire [31:0] App_wr_din, Sdr_rd_dout;
    wire [3:0]  App_wr_dm;

    frame_read_write #(.WRITE_V_FLIP(1), .FRAME_WIDTH(640), .FRAME_HEIGHT(480)) u (
        .mem_clk(mclk), .rst(rst), .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b0), .Sdr_busy(1'b0),
        .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr), .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout),
        .read_clk(vclk), .read_req(rreq), .read_req_ack(rack), .read_finish(),
        .read_addr_0(21'd0), .read_addr_1(21'd307200), .read_addr_2(21'd0), .read_addr_3(21'd0),
        .read_addr_index(ridx), .read_len(21'd307200), .read_en(ren), .read_data(rdat),
        .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr), .App_wr_din(App_wr_din), .App_wr_dm(App_wr_dm),
        .write_clk(sclk), .write_req(wreq), .write_req_ack(wack), .write_finish(wfin),
        .write_addr_0(21'd0), .write_addr_1(21'd307200), .write_addr_2(21'd0), .write_addr_3(21'd0),
        .write_addr_index(widx), .write_len(21'd307200), .write_en(wen), .write_data(wdat)
    );

    // ---- 行为级 SDRAM ----
    reg [31:0] mem [0:2097151];
    reg [7:0]  vp [0:11];
    reg [20:0] ap [0:11];
    integer i;
    assign Sdr_rd_en   = vp[10];
    assign Sdr_rd_dout = mem[ap[10]];
    always @(posedge mclk) begin
        vp[0] <= App_rd_en;  ap[0] <= App_rd_addr;
        for (i=1;i<=11;i=i+1) begin vp[i] <= vp[i-1]; ap[i] <= ap[i-1]; end
        if (App_wr_en) mem[App_wr_addr] <= App_wr_din;
    end

    // ---- 参考图: dst(x,y) 唯一可解码 (高8位存 x[9:8]/y[8]) ----
    function [23:0] pix_at; input [9:0] x; input [8:0] y;
        begin pix_at = {x[9:8], y[8], 5'b0, x[7:0], y[7:0]}; end
    endfunction
    // VFLIP: dst 行 y -> 存储行 (479-y)
    task wr_word;   // 写一个词(4 拍/字, 留出排空余量)
        input [20:0] a; input [31:0] d;
        begin
            @(negedge sclk); wen = 1'b1; wdat = d;
            @(negedge sclk); wen = 1'b0;
            repeat (2) @(negedge sclk);
        end
    endtask

    integer x, y, a, k, bad, reported, cap_n;
    reg [23:0] cap [0:307199];
    reg ren_d;
    always @(posedge vclk) ren_d <= ren;
    // 只在 cap_n < 307200 时采集并计数(上一版计到 614400=2x, 判决失效)
    always @(posedge vclk) if (~rst && ren_d && cap_n < 307200) begin
        cap[cap_n] = rdat[31:8];
        cap_n = cap_n + 1;
    end

    task display_frame;      // 读一帧(640x480)
        integer l, c;
        begin
            @(posedge vclk);
            rreq = 1'b1;
            while (!rack) @(posedge vclk);
            rreq = 1'b0;
            for (l=0; l<480; l=l+1) begin
                for (c=0; c<640; c=c+1) begin
                    @(posedge vclk); ren = 1'b1;
                    @(posedge vclk); ren = 1'b0;
                    repeat (2) @(posedge vclk);
                end
                repeat (40) @(posedge vclk);
            end
            repeat (200) @(posedge vclk);
        end
    endtask

    reg [31:0] wd;
    integer wcount;
    integer sy_t, sx_t, dx_t, dy_t;
    reg [23:0] want_t;
    reg wfin_seen;      // write_finish 只活 1 个 mem_clk, 用粘滞位捕获(避免漏采)
    always @(posedge mclk) if (wfin) wfin_seen <= 1'b1;
    initial begin
        bad = 0; reported = 0; cap_n = 0; ren = 0; rreq = 0; wen = 0; wreq = 0; wfin_seen = 0;
        for (i=0;i<=11;i=i+1) begin vp[i]=0; ap[i]=0; end
        rst = 1'b1;
        repeat (20) @(posedge sclk);
        rst = 1'b0;
        // 启动写帧(BUF0)
        widx = 2'd0;
        @(negedge sclk); wreq = 1'b1;
        repeat (6) @(negedge sclk); wreq = 1'b0;
        repeat (30) @(negedge sclk);

        // ---- 阶段1: 快速把 BUF0 写成已知图 (1字/拍) ----
        // 存储序: 逐存储行 a=0..307199 -> 对应 dst 行 (479 - a/640), 列 a%640
        for (a=0; a<307200; a=a+1) begin
            sy_t = 479 - (a / 640);
            sx_t = a % 640;
            wd = {pix_at(sx_t[9:0], sy_t[8:0]), 8'h00};
            wr_word(a[20:0], wd);
        end
        $display("[RDBK] phase1 wrote BUF0, waiting write_finish...");
        wcount = 0;
        while (!wfin_seen && wcount < 600_000_000) begin @(posedge sclk); wcount=wcount+1; end
        $display("[RDBK] write_finish_seen=%b after %0d sclk", wfin_seen, wcount);
        repeat (5000) @(posedge sclk);

        // ---- 阶段2: 同时 读BUF0 + 慢速写BUF1 ----
        $display("[RDBK] phase2 start: concurrent read(BUF0) + slow write(BUF1)");
        fork
            // (a) 显示读 BUF0
            begin : rd
                integer l, c;
                @(posedge vclk);
                rreq = 1'b1;
                while (!rack) @(posedge vclk);
                rreq = 1'b0;
                for (l=0; l<480; l=l+1) begin
                    for (c=0; c<640; c=c+1) begin
                        @(posedge vclk); ren = 1'b1;
                        @(posedge vclk); ren = 1'b0;
                        repeat (2) @(posedge vclk);
                    end
                    repeat (40) @(posedge vclk);
                end
            end
            // (b) 涓流写 BUF1
            begin : wr
                integer b;
                widx = 2'd1;
                @(negedge sclk); wreq = 1'b1;
                repeat (6) @(negedge sclk); wreq = 1'b0;
                repeat (20) @(negedge sclk);
                for (b=0; b<307200; b=b+1) begin
                    @(negedge sclk); wen = 1'b1; wdat = 32'hDEAD_BEEF;
                    @(negedge sclk); wen = 1'b0;
                    repeat (WRITE_GAP-2) @(negedge sclk);
                end
            end
        join
        repeat (2000) @(posedge vclk);

        // ---- 比对读回的 BUF0 ----
        for (k=0; k<307200; k=k+1) begin
            dx_t = k % 640; dy_t = k / 640;
            want_t = pix_at(dx_t[9:0], dy_t[8:0]);
            if (cap[k] !== want_t) begin
                bad = bad + 1;
                if (reported < 8) begin
                    reported = reported + 1;
                    $display("  BAD k=%0d dst(%0d,%0d) got=%06x want=%06x", k, dx_t, dy_t, cap[k], want_t);
                end
            end
        end
        $display("[RDBK] captured=%0d  bad=%0d", cap_n, bad);
        if (bad==0 && cap_n>=307200) $display("### VERDICT: PASS (边写边读, BUF0 读回内容完好)");
        else $display("### VERDICT: FAIL");
        $finish;
    end

    initial begin
        #400_000_000;
        $display("[RDBK] GLOBAL TIMEOUT cap_n=%0d bad=%0d", cap_n, bad);
        $finish;
    end
endmodule
`default_nettype wire
