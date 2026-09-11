`timescale 1ns/1ps
// ============================================================================
// tb_v103_fw.v — 路线B真身帧写手台 (2026-09-07 深夜, 0x18 案专用)
// 目的: 真wfifo_32_32_512 + 真frame_fifo_write(BURST_SIZE=256) + 真img_scaler,
//       复现"装载后 W 18 (源完帧不完, write_finish 永不到)"并定位净丢字点。
// 铁律⑰要求: 计数点钉在与真身完全相同的信号上 —— 本台直接用真身, 无替身。
//
// 机制账本(读码实证):
//   into_burst = (write_len_latch <= rdusedw+write_cnt || rdusedw > 256) && ~App_rd_busy
//   write_cnt 只在每次 burst 完成时 +256; S_END 判据 write_cnt >= 307200
//   => FIFO 净丢 >=1 字(满溢出/aclr 抹除/源短供) => 末次 burst 永不触发 => 0x18
//
// 用法(plusargs):
//   +mode=direct|scaler   direct=直通锚(170字阵发); scaler=真img_scaler链(默认320x240)
//   +gap=<n>              每个170字阵发之间的空窗(wclk拍), 默认500
//   +busy_pct=<0-90>      假HDMI读干扰占空%(周期5000拍mclk), 默认40
//   +b2b=1                完帧后立即背靠背第二装载(L6用例)
// 判据: write_finish 出现 + drained==307200 + write_cnt 终值
// 编译(见 tools/tests/_run_fw.sh): afifo_16_32_256.v frame_fifo_write.v sdiv24.v img_scaler.v 本文件
// ============================================================================
`default_nettype wire
module tb_v103_fw;

    // ---------------- clocks: 真板频率 ----------------
    reg wclk = 1'b0;                     // sd_card_clk 100MHz (10ns)
    reg mclk = 1'b0;                     // ext_mem_clk 125MHz (8ns)
    always #5  wclk = ~wclk;
    always #4  mclk = ~mclk;

    // ---------------- plusargs ----------------
    reg [1023:0] mode_str;
    integer      gap;
    integer      busy_pct;
    integer      b2b;
    reg [15:0]   src_w, src_h;
    reg          mode_scaler;

    // ---------------- reset / sdram ready ----------------
    reg rst = 1'b1;
    reg Sdr_init_done = 1'b0;

    // ---------------- 干扰源: 假HDMI读口 App_rd_busy ----------------
    // 周期 EPOCH=5000 mclk, 高 busy_pct% ; 0%=无干扰
    reg App_rd_busy = 1'b0;
    localparam integer EPOCH = 5000;

    // ---------------- 写手DUT连线 ----------------
    reg         write_req = 1'b0;
    wire        write_req_ack, write_finish, fifo_aclr;
    wire        App_wr_en;
    wire [20:0] App_wr_addr;
    reg  [20:0] write_addr_0 = 21'd0;
    reg  [1:0]  write_addr_index = 2'd0;
    localparam [20:0] FRAME_PIXELS = 21'd307200;

    // ---------------- 源->FIFO ----------------
    reg         src_we = 1'b0;
    reg  [31:0] src_data = 32'h0;
    wire        sc_en;
    wire [31:0] sc_data;
    wire        sc_fd;
    wire        fifo_we;
    wire [31:0] fifo_di;

    // ---------------- 真缩放器 (scaler 模式启用) ----------------
    reg  [15:0] scaler_srcw = 16'd320, scaler_srch = 16'd240;
    reg         in_sov_q = 1'b0, in_eov_q = 1'b0;
    wire        in_eov_w;

    img_scaler u_scaler (
        .clk        (wclk),
        .rst_n      (~rst),
        .in_en      (src_we),
        .in_data    (src_data),
        .src_w      (scaler_srcw),
        .src_h      (scaler_srch),
        .in_sov     (in_sov_q),
        .in_eov     (in_eov_w),
        .out_en     (sc_en),
        .out_data   (sc_data),
        .frame_done (sc_fd)
    );
    // in_eov 与最后一个 in_en 精确同拍(仿真里用纯组合再与, 匹配 pix_eov 生成法)
    assign in_eov_w = in_eov_q && src_we;

    assign fifo_we = mode_scaler ? sc_en   : src_we;
    assign fifo_di = mode_scaler ? sc_data : src_data;

    // ---------------- 真FIFO (满行为/计数语义与真身一致) ----------------
    wire        fifo_full, fifo_empty, fifo_valid;
    wire [8:0]  fifo_wrusedw;
    wire [9:0]  rdusedw;
    wire [31:0] fifo_dout;

    wfifo_32_32_512 u_fifo (
        .clkr       (mclk),
        .clkw       (wclk),
        .rst        (fifo_aclr),
        .we         (fifo_we),
        .re         (App_wr_en),
        .di         (fifo_di),
        .dout       (fifo_dout),
        .valid      (fifo_valid),
        .empty_flag (fifo_empty),
        .full_flag  (fifo_full),
        .wrusedw    (fifo_wrusedw),
        .rdusedw    (rdusedw)
    );

    // ---------------- 真写手 (BURST_SIZE=256 与 frame_read_write 覆写一致) ----------------
    frame_fifo_write #(
        .BURST_SIZE   (256),
        .WRITE_V_FLIP (1)
    ) u_fw (
        .rst              (rst),
        .mem_clk          (mclk),
        .Sdr_init_done    (Sdr_init_done),
        .Sdr_init_ref_vld (1'b1),
        .Sdr_busy         (1'b0),
        .App_rd_busy      (App_rd_busy),
        .O_wr_busy        (),
        .App_wr_en        (App_wr_en),
        .App_wr_addr      (App_wr_addr),
        .write_req        (write_req),
        .write_req_ack    (write_req_ack),
        .write_finish     (write_finish),
        .write_addr_0     (write_addr_0),
        .write_addr_1     (21'd0),
        .write_addr_2     (21'd0),
        .write_addr_3     (21'd0),
        .write_addr_index (write_addr_index),
        .write_len        (FRAME_PIXELS),
        .rdusedw          (rdusedw),
        .fifo_aclr        (fifo_aclr)
    );

    // ---------------- 探针账本 (铁律⑰: 计数点=真身信号) ----------------
    integer pushed;      // FIFO 写口接受的字 (we 采样拍)
    integer attempted;   // FIFO 写口尝试的字 (we 拉高拍, 含被满拒绝)
    integer lost_full;   // 满丢弃: fifo_we && fifo_full
    integer wiped;       // aclr 抹除: fifo_we && fifo_aclr
    integer drained;     // 到达假SDRAM的字: App_wr_en 采样拍
    integer finish_cnt;  // write_finish 脉冲数
    reg [20:0] wc_snap;  // write_cnt 终值快照
    integer rdw_max, rdw_min;
    integer aclr_events;

    // mclk 域账本
    integer phantom_gate;   // App_wr_en=1 但 rdusedw==0 (门控应拦却没拦?)
    integer rd_en_s_cnt;    // FIFO 内部真实读脉冲
    integer empty_and_re;   // App_wr_en=1 且 empty_flag=1 (IP 内部会抑制的拍)
    // b-23 内容校验器: 直通模式逐字核对(源=1..N 递增), 缩放模式查低字节00不变量+帧XOR
    reg [31:0] exp_word;    // 期望的下一个排空字 (直通: exp+1)
    reg [31:0] frame_xor;   // 本帧已排空字 XOR
    reg [31:0] xor_a, xor_b; // 第1/2帧 XOR 快照 (b2b 同源必须相等)
    integer    data_err;    // 直通逐字不匹配数
    integer    sc_attr_err; // 缩放模式低字节!=00 计数
    integer    loads_done;  // 完成帧数
    always @(posedge mclk) begin
        if (App_wr_en) begin
            drained <= drained + 1;
            if (rdusedw == 0) phantom_gate <= phantom_gate + 1;
            if (u_fifo.empty_flag) empty_and_re <= empty_and_re + 1;
            // b-23 内容校验
            frame_xor <= frame_xor ^ fifo_dout;
            if (!mode_scaler && fifo_dout !== (exp_word + 32'h1))
                data_err <= data_err + 1;
            if (mode_scaler && fifo_dout[7:0] !== 8'h00)
                sc_attr_err <= sc_attr_err + 1;
            exp_word <= exp_word + 32'h1;
        end
        if (u_fifo.rd_en_s) rd_en_s_cnt <= rd_en_s_cnt + 1;
        if (write_finish) begin
            finish_cnt  <= finish_cnt + 1;
            wc_snap     <= u_fw.write_cnt;
            // b-23: 帧边界快照 XOR
            if (loads_done == 0) xor_a <= frame_xor; else xor_b <= frame_xor;
            loads_done  <= loads_done + 1;
            frame_xor   <= 32'h0;
            exp_word    <= 32'h0;
        end
        if (rdusedw > rdw_max) rdw_max <= rdusedw;
        if (rdusedw < rdw_min) rdw_min <= rdusedw;
    end
    // aclr 事件计数 (wclk 域采样, 异步清零以 wclk 观测)
    always @(posedge wclk) begin
        if (fifo_aclr) aclr_events <= aclr_events + 1;
        if (fifo_we) begin
            attempted <= attempted + 1;
            if (fifo_full) lost_full <= lost_full + 1;
        end
        if (fifo_we && !fifo_aclr && !fifo_full) pushed <= pushed + 1;
        if (fifo_we && fifo_aclr)  wiped  <= wiped  + 1;
    end

    // 水位追踪器: rdusedw>=300 时抓排空阻塞现行(前40次)
    integer trace_cnt = 0;
    always @(posedge mclk) begin
        if (rdusedw >= 300) begin
            trace_cnt <= trace_cnt + 1;
            if (trace_cnt < 40)
                $display("[TRACE] %0t rdw=%0d st=%0d busy=%b wr_en=%b bcnt=%0d wcnt=%0d aclr=%b req2=%b ack=%b",
                         $time, rdusedw, u_fw.state, App_rd_busy, App_wr_en,
                         u_fw.burst_cnt, u_fw.write_cnt, fifo_aclr,
                         u_fw.write_req_d2, write_req_ack);
        end
    end

    // ---------------- 假SDRAM写汇 + 干扰生成 (mclk域) ----------------
    integer busy_hi, busy_lo, epoch_cnt;
    initial begin
        if (! $value$plusargs("busy_pct=%d", busy_pct)) busy_pct = 40;
        busy_hi = (EPOCH * busy_pct) / 100;
        busy_lo = EPOCH - busy_hi;
        epoch_cnt = 0;
        forever begin
            if (busy_hi > 0) begin
                App_rd_busy = 1'b1;
                repeat (busy_hi) @(posedge mclk);
                App_rd_busy = 1'b0;
            end
            repeat (busy_lo) @(posedge mclk);
        end
    end

    // ---------------- 源驱动任务 (wclk域, 匹配 bmp_read 行为) ----------------
    // 帧协议: req -> 等 ack -> 撤 req (pix_sov 此拍) -> 空窗(SD读延迟) -> 170字阵发流
    integer burst_i, k, total_src, src_target;
    task do_one_load;
        begin
            @(posedge wclk);
            write_req <= 1'b1;
            wait (write_req_ack === 1'b1);
            @(posedge wclk);
            write_req <= 1'b0;
            if (mode_scaler) begin
                in_sov_q <= 1'b1;              // pix_sov: ack 拍, 领先首 in_en >=1 拍
            end
            repeat (100) @(posedge wclk);      // SD 扇区取数延迟(缩短版, 保持节奏形态)
            if (mode_scaler) in_sov_q <= 1'b0;

            src_data = 32'h0;
            total_src = 0;
            while (total_src < src_target) begin
                k = (src_target - total_src > 170) ? 170 : (src_target - total_src);
                for (burst_i = 0; burst_i < k; burst_i = burst_i + 1) begin
                    @(posedge wclk);
                    src_we   <= 1'b1;
                    src_data <= src_data + 32'h1;
                    if (mode_scaler && (total_src + burst_i == src_target - 1))
                        in_eov_q <= 1'b1;      // 与最后 in_en 同拍
                end
                total_src = total_src + k;
                @(posedge wclk);
                src_we   <= 1'b0;
                in_eov_q <= 1'b0;
                repeat (gap) @(posedge wclk);
            end
        end
    endtask

    // ---------------- 判决与报告 ----------------
    integer i;
    initial begin
        pushed = 0; attempted = 0; lost_full = 0; wiped = 0; drained = 0;
        finish_cnt = 0; wc_snap = 0; rdw_max = 0; rdw_min = 999; aclr_events = 0;
        phantom_gate = 0; rd_en_s_cnt = 0; empty_and_re = 0;
        exp_word = 0; frame_xor = 0; xor_a = 0; xor_b = 0;
        data_err = 0; sc_attr_err = 0; loads_done = 0;

        if (! $value$plusargs("mode=%s", mode_str)) mode_str = "direct";
        if (mode_str == "scaler") mode_scaler = 1'b1; else mode_scaler = 1'b0;
        if (! $value$plusargs("gap=%d", gap)) gap = 500;
        if (! $value$plusargs("b2b=%d", b2b)) b2b = 0;
        if (mode_scaler) begin
            if (! $value$plusargs("srcw=%d", src_w)) src_w = 16'd320;
            if (! $value$plusargs("srch=%d", src_h)) src_h = 16'd240;
            scaler_srcw = src_w; scaler_srch = src_h;
            src_target = src_w * src_h;          // 缩放器吃 w*h 字, 吐 307200
        end else begin
            src_target = 307200;                 // 直通: 进多少吐多少
        end

        $display("[TB] mode=%0s gap=%0d busy_pct=%0d src=%0dx%0d src_target=%0d b2b=%0d",
                 mode_str, gap, busy_pct, src_w, src_h, src_target, b2b);

        repeat (20) @(posedge wclk);
        rst = 1'b0;
        repeat (20) @(posedge mclk);
        Sdr_init_done = 1'b1;

        // 第一装载 (纯Verilog有界等待, 无fork)
        do_one_load;
        i = 0;
        // v12.1: 缩放路出货改 1字/32拍 后, 整帧输出需 ~307200*32=9.83M 拍,
        //   原 4M 窗口会在真因之外先超时(误报 0x18)。放宽到 12M。
        while (finish_cnt == 0 && i < 12_000_000) begin
            @(posedge wclk);
            i = i + 1;
        end
        if (finish_cnt == 0)
            $display("[TB][TIMEOUT] 源完+12M拍仍无 finish —— 0x18 复现");
        repeat (2000) @(posedge mclk);
        report_verdict(1);

        // L6 背靠背: finish 后立即再装一帧
        if (b2b && finish_cnt > 0) begin
            $display("[TB][L6] 背靠背第二装载开始");
            src_data = 32'h1000_0000;
            do_one_load;
            i = 0;
            while (finish_cnt < 2 && i < 12_000_000) begin
                @(posedge wclk);
                i = i + 1;
            end
            if (finish_cnt < 2)
                $display("[TB][L6][TIMEOUT] 第二装载无 finish");
            repeat (2000) @(posedge mclk);
            report_verdict(1);
        end

        $display("[TB] === 结束 ===");
        $finish;
    end

    task report_verdict;
        input integer final_check;
        integer ef;   // 有效帧数: b2b 第二次报告=2, 其余=1 (账本跨帧累计, 判决按帧归一)
        begin
            $display("[TB] ---- 账本 @%0t (final=%0d) ----", $time, final_check);
            $display("[TB] pushed=%0d attempted=%0d lost_full=%0d wiped=%0d drained=%0d",
                     pushed, attempted, lost_full, wiped, drained);
            $display("[TB] write_cnt=%0d finish_cnt=%0d rdusedw_max=%0d min=%0d aclr_events=%0d",
                     u_fw.write_cnt, finish_cnt, rdw_max, rdw_min, aclr_events);
            $display("[TB] 诊断: phantom_gate=%0d rd_en_s_cnt=%0d empty_and_re=%0d data_err=%0d sc_attr_err=%0d xor=%h  FIFO.rd_addr=%0d wr_addr=%0d sync_wr=%0d",
                     phantom_gate, rd_en_s_cnt, empty_and_re, data_err, sc_attr_err, frame_xor, u_fifo.rd_addr, u_fifo.wr_addr, u_fifo.wr_to_rd_addr);
            if (u_fw.state == 5) $display("[TB] state=S_END");
            else if (u_fw.state == 2) $display("[TB] state=S_CHECK_FIFO(在等料)");
            else $display("[TB] state=%0d", u_fw.state);
            ef = (finish_cnt >= 2) ? 2 : 1;
            if (finish_cnt == ef && drained == 307200*ef
                && u_fw.write_cnt == 307200
                && pushed == 307200*ef && lost_full == 0 && phantom_gate == 0
                && rd_en_s_cnt == 307200*ef
                && data_err == 0 && sc_attr_err == 0
                && (ef < 2 || mode_scaler || xor_a == xor_b))
                $display("[TB] VERDICT: PASS (字数守恒+内容一致: 零丢字+零幻读+零错字, %0d 帧账平, xor=%h)", ef, (ef < 2 ? xor_a : xor_b));
            else if (finish_cnt > 0 && drained == 307200*ef)
                $display("[TB] VERDICT: FAIL-CONTENT (finish 到但账/内容不平: data_err=%0d sc_attr=%0d xor_a=%h xor_b=%h pushed=%0d lost=%0d phantom=%0d)",
                         data_err, sc_attr_err, xor_a, xor_b, pushed, lost_full, phantom_gate);
            else begin
                if (drained < 307200*ef && drained + rdusedw < 307200*ef)
                    $display("[TB] VERDICT: FAIL-0x18 (净供字不足: 缺口=%0d)",
                             307200*ef - drained - rdusedw);
                else
                    $display("[TB] VERDICT: FAIL-OTHER");
            end
        end
    endtask

endmodule
