//=============================================================================
// tb_full_pipe.v -- 端到端「写↔读争用」验证台
//
// 动机：真板症状是「整块纯色 / 5 条竖长条」，纯色块是 FIFO 吐陈旧数据(dout 保持)
//       的典型特征，不是像素算错。故必须验证 frame_read_write 的**读口**在
//       写侧持续涓流时，能否把整帧原样读出来。
//
// 结构：真速率源 -> 真 img_scaler -> 真 frame_read_write -> 行为级 SDRAM
//       -> 显示读取模型(read_req/ack + 640x480 read_en) -> 抓回帧 -> 与期望比对
//
// 用法: iverilog -g2005 -DSRC_W=320 -DSRC_H=240 -DT_PX=180 -o f.vvp \
//            -s tb_full_pipe tb_full_pipe.v <img_scaler.v> <frame_read_write.v> <fifo deps>
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

`ifndef SRC_W
`define SRC_W 320
`endif
`ifndef SRC_H
`define SRC_H 240
`endif
`ifndef T_PX
`define T_PX 180
`endif
`ifndef SEC_PX
`define SEC_PX 170
`endif
`ifndef USE_PAUSE
`define USE_PAUSE 1
`endif

module tb_full_pipe;
    localparam SW = `SRC_W;
    localparam SH = `SRC_H;
    localparam TPX = `T_PX;
    localparam SECPX = `SEC_PX;
    localparam FRAME_PIXELS = 640*480;

    // ---- 时钟: sd_card_clk 100M / ext_mem_clk 125M / video_clk 25.175M ----
    reg sclk = 0, mclk = 0, vclk = 0;
    always #5    sclk = ~sclk;      // 100 MHz
    always #4    mclk = ~mclk;      // 125 MHz
    always #19.86 vclk = ~vclk;     // ~25.175 MHz

    reg rst = 1'b1;

    // ================= 源 + 缩放器 =================
    reg in_en = 0, in_sov = 0, in_eov = 0;
    reg [31:0] in_data = 0;
    reg [15:0] src_w = SW, src_h = SH;
    wire sc_out_en, sc_fd, sc_pause;
    wire [31:0] sc_out_data;

    img_scaler u_sc (
        .clk(sclk), .rst_n(~rst), .in_en(in_en), .in_data(in_data),
        .src_w(src_w), .src_h(src_h), .in_sov(in_sov), .in_eov(in_eov),
        .out_en(sc_out_en), .out_data(sc_out_data), .frame_done(sc_fd),
        .src_pause(sc_pause)
    );

    integer push_cnt, feeding, tick, gap_rem, sec_rem, timeout;
    integer px_x, px_y;
    reg [23:0] push_pix;
    always @(*) begin px_x = push_cnt % SW; px_y = push_cnt / SW; end
    always @(*) in_data = {push_pix, 8'h00};

`ifdef NOUSE_PAUSE
    wire src_hold = 1'b0;
`else
    wire src_hold = sc_pause;
`endif

    always @(posedge sclk) if (~rst && feeding) begin
        if (tick < TPX-1) tick <= tick + 1; else tick <= 0;
    end

    always @(negedge sclk) begin
        if (rst) begin in_en <= 0; in_eov <= 0; end
        else if (feeding) begin
            if (gap_rem > 0) begin gap_rem <= gap_rem-1; in_en <= 0; in_eov <= 0; end
            else if (tick != TPX-1) begin in_en <= 0; in_eov <= 0; end
            else if (src_hold) begin in_en <= 0; in_eov <= 0; end
            else if (push_cnt >= SW*SH) begin feeding <= 0; in_en <= 0; in_eov <= 0; end
            else begin
                in_en <= 1;
                push_pix <= {px_x[7:0], px_y[7:0], px_x[11:8], px_y[11:8]};
                in_eov <= (push_cnt == SW*SH-1) ? 1'b1 : 1'b0;
                push_cnt <= push_cnt + 1;
                sec_rem <= sec_rem - 1;
                if (sec_rem == 1) begin sec_rem <= SECPX; gap_rem <= 0; end
            end
        end else begin in_en <= 0; in_eov <= 0; end
    end

    // ================= frame_read_write =================
    wire        wr_req, wr_ack, wr_finish;
    wire        App_wr_en, App_rd_en, Sdr_rd_en;
    wire [20:0] App_wr_addr, App_rd_addr;
    wire [31:0] App_wr_din, Sdr_rd_dout;
    wire [3:0]  App_wr_dm;

    reg         rd_req_from_v;
    wire        rd_req_ack;
    reg         vread_en;          // 显示读使能(TB 驱动)
    wire [31:0] vread_data;
    reg  [1:0]  wr_buf_idx;        // 写缓冲索引(TB 驱动)

    frame_read_write #(
        .WRITE_V_FLIP (1), .FRAME_WIDTH (640), .FRAME_HEIGHT (480)
    ) u_frw (
        .mem_clk           (mclk),
        .rst               (rst),
        .Sdr_init_done     (1'b1),
        .Sdr_init_ref_vld  (1'b0),
        .Sdr_busy          (1'b0),
        .App_rd_en         (App_rd_en),
        .App_rd_addr       (App_rd_addr),
        .Sdr_rd_en         (Sdr_rd_en),
        .Sdr_rd_dout       (Sdr_rd_dout),
        .read_clk          (vclk),
        .read_req          (rd_req_from_v),
        .read_req_ack      (rd_req_ack),
        .read_finish       (),
        .read_addr_0       (21'd0),
        .read_addr_1       (21'd307200),
        .read_addr_2       (21'd0),
        .read_addr_3       (21'd0),
        .read_addr_index   (rd_buf_idx),
        .read_len          (21'd307200),
        .read_en           (vread_en),
        .read_data         (vread_data),
        .App_wr_en         (App_wr_en),
        .App_wr_addr       (App_wr_addr),
        .App_wr_din        (App_wr_din),
        .App_wr_dm         (App_wr_dm),
        .write_clk         (sclk),
        .write_req         (wr_req),
        .write_req_ack     (wr_ack),
        .write_finish      (wr_finish),
        .write_addr_0      (21'd0),
        .write_addr_1      (21'd307200),
        .write_addr_2      (21'd0),
        .write_addr_3      (21'd0),
        .write_addr_index  (wr_buf_idx),
        .write_len         (21'd307200),
        .write_en          (sc_out_en),
        .write_data        (sc_out_data)
    );

    reg [1:0] rd_buf_idx;
    initial rd_buf_idx = 2'd0;

    // 写侧: 上升沿请求一次(模拟 bmp_read 的 write_req 脉冲), 索引固定 BUF0
    reg wr_req_r;
    initial begin wr_req_r = 0; wr_buf_idx = 2'd0; end
    always @(posedge sclk) if (rst) wr_req_r <= 1'b0;
    assign wr_req = wr_req_r;

    // ================= 行为级 SDRAM (App 口) =================
    reg [31:0] mem [0:2097151];
    integer i;
    reg [7:0]  rdv_pipe;
    reg [20:0] rda_pipe;
    reg [31:0] rdd_pipe;
    // 读延迟 ~10 个 mem_clk (与 frame_fifo_read 的 rd_delay==10 对齐)
    reg [7:0]  vpipe [0:11];
    reg [20:0] apipe [0:11];
    wire [7:0]  vp0 = vpipe[0];
    assign Sdr_rd_en = vpipe[10];
    assign Sdr_rd_dout = mem[apipe[10]];
    always @(posedge mclk) begin
        vpipe[0] <= App_rd_en;
        apipe[0] <= App_rd_addr;
        for (i=1;i<=11;i=i+1) begin vpipe[i] <= vpipe[i-1]; apipe[i] <= apipe[i-1]; end
        if (App_wr_en) mem[App_wr_addr] <= App_wr_din;
    end

    // ================= 显示读取模型 + 抓帧 =================
    reg [23:0] cap [0:307199];
    integer cap_n, line, col;
    reg [23:0] gv;   // 该拍读回的值
    reg        cap_en;

    // 采样相位: 与顶层一致(read_en 后一拍取数)
    reg vread_en_d;
    always @(posedge vclk) vread_en_d <= vread_en;
    always @(posedge vclk) if (~rst && vread_en_d) begin
        if (cap_n < 307200) cap[cap_n] = vread_data[31:8];
        cap_n = cap_n + 1;
    end

    integer frames_done;
    initial frames_done = 0;
    task do_frame_read;
        integer l, c;
        begin
            @(posedge vclk);
            rd_req_from_v = 1'b1;
            while (!rd_req_ack) @(posedge vclk);
            rd_req_from_v = 1'b0;
            for (l=0; l<480; l=l+1) begin
                for (c=0; c<640; c=c+1) begin
                    @(posedge vclk); vread_en = 1'b1;
                    @(posedge vclk); vread_en = 1'b0;
                    repeat (2) @(posedge vclk);      // 像素间隔(留出读取窗口)
                end
                repeat (40) @(posedge vclk);          // 行消隐
            end
            repeat (300) @(posedge vclk);             // 场消隐
            frames_done = frames_done + 1;
        end
    endtask

    // ================= 期望值与比对 =================
    integer E_L, E_R, EST_W, T_ND, TND_C, SXSTEP, SYSTEP, DSTW, DSTH, OFFX, OFFY;
    integer bad, rows_bad, reported, e_x, e_y, a_x, a_y, k;
    integer c_dy, c_dx, c_in_r;

    initial begin
        E_L = SW*512 - SW*32;  E_R = SH*512 + SH*128;
        EST_W = (E_L >= E_R) ? 1 : 0;
        T_ND = EST_W ? ((SH*640)/SW) : ((SW*480)/SH);
        TND_C = (T_ND==0) ? 1 : T_ND;
        SXSTEP = (SW*8192) / (EST_W ? 640 : TND_C);
        SYSTEP = (SH*8192) / (EST_W ? TND_C : 480);
        DSTW = EST_W ? 640 : TND_C;
        DSTH = EST_W ? TND_C : 480;
        OFFX = (640-DSTW)>>1;  OFFY = (480-DSTH)>>1;
    end

    // ================= 主流程 =================
    initial begin
        push_cnt = 0; feeding = 0; tick = 0; gap_rem = 0; sec_rem = SECPX;
        cap_n = 0; bad = 0; rows_bad = 0; reported = 0; timeout = 0;
        push_pix = 24'd0; rd_req_from_v = 0; vread_en = 0;
        for (i=0;i<=11;i=i+1) begin vpipe[i]=0; apipe[i]=0; end
        rst = 1'b1;
        repeat (20) @(posedge sclk);
        rst = 1'b0;
        wr_req_r <= 1'b1;
        repeat (4) @(posedge sclk);
        wr_req_r <= 1'b0;
        repeat (10) @(posedge sclk);

        // 帧开始
        @(negedge sclk); in_sov = 1;
        @(negedge sclk); in_sov = 0;
        @(negedge sclk); feeding = 1;

        // 源送完
        timeout = 0;
        while (feeding && timeout < 200_000_000) begin @(posedge sclk); timeout=timeout+1; end
        // 写完一帧
        timeout = 0;
        while (!wr_finish && timeout < 200_000_000) begin @(posedge sclk); timeout=timeout+1; end
        $display("[PIPE] source done: pushed=%0d/%0d  write_finish=%b", push_cnt, SW*SH, wr_finish);

        // 等写侧彻底静默, 再读一帧
        repeat (20000) @(posedge sclk);
        do_frame_read;
        $display("[PIPE] display read done: captured %0d pixels", cap_n);

        // 比对
        for (k=0; k<307200 && k<cap_n; k=k+1) begin
            c_dy = k / 640; c_dx = k % 640;
            c_in_r = (c_dx>=OFFX)&&(c_dx<OFFX+DSTW)&&(c_dy>=OFFY)&&(c_dy<OFFY+DSTH);
            if (!c_in_r) begin
                if (cap[k] != 24'd0) begin
                    bad = bad + 1;
                    if (reported < 6) begin reported=reported+1;
                        $display("  BORDER BAD k=%0d dst(%0d,%0d) got=%06x", k, c_dx, c_dy, cap[k]); end
                end
            end else begin
                e_x = (((2*(c_dx-OFFX)+1)*SXSTEP)>>14); if (e_x>SW-1) e_x=SW-1;
                e_y = (((2*(c_dy-OFFY)+1)*SYSTEP)>>14); if (e_y>SH-1) e_y=SH-1;
                if (cap[k] !== {e_x[7:0], e_y[7:0], e_x[11:8], e_y[11:8]}) begin
                    bad = bad + 1;
                    if (reported < 6) begin reported=reported+1;
                        $display("  PIXEL BAD k=%0d dst(%0d,%0d) got=%06x want=%06x",
                                 k, c_dx, c_dy, cap[k], {e_x[7:0],e_y[7:0],e_x[11:8],e_y[11:8]}); end
                end
            end
        end
        $display("[PIPE] geom est_w=%0d t_nd=%0d dst=%0dx%0d off=(%0d,%0d) sx=%0d sy=%0d",
                 EST_W, TND_C, DSTW, DSTH, OFFX, OFFY, SXSTEP, SYSTEP);
        $display("[PIPE] captured=%0d  bad=%0d", cap_n, bad);
        if (bad==0 && cap_n>=307200) $display("### VERDICT: PASS (读回帧与写入帧一致)");
        else $display("### VERDICT: FAIL");
        $finish;
    end

    initial begin
        #200_000_000;   // 200ms 硬超时
        $display("[PIPE] GLOBAL TIMEOUT (cap_n=%0d, frames=%0d)", cap_n, frames_done);
        $finish;
    end
endmodule
`default_nettype wire
