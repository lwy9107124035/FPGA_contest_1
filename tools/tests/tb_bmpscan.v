// tb_bmpscan —— 独立仿真 bmp_read 扇区走位：5 张干净连续 BMP 卡模型
// 目的：复现/排除"板子只登记 4 张、第 5 张扫不到"的现场问题
// 编译：见文件尾注释
`timescale 1ns/1ps
module tb_bmpscan;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;                 // 100MHz

  // ---- DUT 控制 ----
  reg             scan_start = 0;
  reg  [31:0]     scan_start_sector = 0;
  reg  [31:0]     scan_max_sector = 32'd131071;
  reg  [2:0]      scan_target = 3'd7;
  reg             load_start = 0, load_abort = 0;
  reg  [31:0]     load_sector = 0;
  reg             sd_init_done = 0;

  wire            ready, scan_done, scan_found_valid;
  wire [31:0]     scan_found_sector;
  wire [2:0]      scan_found_total;
  wire [3:0]      state_code;
  wire            write_req, sd_sec_read;
  wire [31:0]     sd_sec_read_addr;
  wire            bmp_data_wr_en;
  wire [23:0]     bmp_data;
  reg  [7:0]      sd_sec_read_data = 0;
  reg             sd_sec_read_data_valid = 0;
  reg             sd_sec_read_end = 0;
  reg             write_req_ack = 0;

  // ---- 卡模型：文件头扇区表（可切换 4/5/6/7/13 张，含真实多分辨率） ----
  reg [31:0] hdr_sec [0:15];
  reg [15:0] fw      [0:15];   // v10.3 预检：每张图真实宽
  reg [15:0] fh      [0:15];   // 每张图真实高
  integer    ncard = 5;
  reg        mr      = 1'b0;   // 驱动 DUT multi_res（= SC 开关）

  function [7:0] card_byte;            // 扇区 sec 内第 off 字节
    input [31:0] sec; input [9:0] off;
    integer k; reg ish; integer mk;
    begin
      ish = 1'b0; mk = 0;
      for (k = 0; k < ncard; k = k + 1)
        if (sec == hdr_sec[k]) begin ish = 1'b1; mk = k; end
      if (!ish) card_byte = 8'h00;      // 空白区全 0
      else begin
        case (off)
          10'd0: card_byte = "B";
          10'd1: card_byte = "M";
          10'd2: card_byte = 8'h36;     // file_len = 921654 (0x000E1036)
          10'd3: card_byte = 8'h10;
          10'd4: card_byte = 8'h0E;
          10'd5: card_byte = 8'h00;
          10'd10: card_byte = 8'h36;    // pixel_offset = 54
          10'd11,10'd12,10'd13: card_byte = 8'h00;
          10'd18: card_byte = fw[mk][7:0];    // width  小端低字节
          10'd19: card_byte = fw[mk][15:8];   // width  高字节
          10'd20,10'd21: card_byte = 8'h00;
          10'd22: card_byte = fh[mk][7:0];    // height 小端低字节
          10'd23: card_byte = fh[mk][15:8];   // height 高字节
          10'd24,10'd25: card_byte = 8'h00;
          10'd26,10'd27: card_byte = 8'h00; // planes 低位（不影响匹配）
          10'd28: card_byte = 8'h18;    // 24bpp
          10'd29: card_byte = 8'h00;
          10'd30,10'd31,10'd32,10'd33: card_byte = 8'h00; // compression=0
          default: card_byte = 8'hA5;
        endcase
      end
    end
  endfunction

  // ---- SD 读模型：addr 变化即流 512 字节，末尾 end 脉冲 ----
  // 修复（对齐真实 SD 控制器时序）：数据恰好 512 拍（m_cnt 0..511），
  // end 在最后一拍 valid 之后一拍出现；read 被撤销（扇区边界）时 flush。
  // 旧模型多流一拍 valid，把 DUT 的 rd_cnt 复位分支吞掉，导致跳过文件后
  // 头寄存器残留旧值 → 幻影命中（曾误报 "6 张图"）。纯 TB 侧修复。
  reg  [31:0] m_addr = 32'hDEAD;
  reg  [9:0]  m_cnt = 0;
  reg         m_busy = 0;
  reg         m_fin  = 0;
  always @(posedge clk) begin
    sd_sec_read_data_valid <= 1'b0;
    sd_sec_read_end        <= 1'b0;
    if (sd_sec_read_addr !== m_addr) begin
      m_addr <= sd_sec_read_addr;          // 新扇区：一切重来
      m_cnt  <= 0;
      m_busy <= 1'b0;
      m_fin  <= 0;
    end else if (!sd_sec_read) begin
      m_busy <= 1'b0;                      // 扇区边界撤读：flush
      m_fin  <= 0;
    end else if (m_fin) begin
      sd_sec_read_end <= 1'b1;             // 512 拍数据之后：单独一拍 END
      m_fin  <= 1'b0;
      m_busy <= 1'b0;
    end else if (!m_busy) begin
      m_busy <= 1'b1;                      // 读稳定拉高，下一拍开始流
    end else begin
      sd_sec_read_data       <= card_byte(m_addr, m_cnt);
      sd_sec_read_data_valid <= 1'b1;
      if (m_cnt == 10'd511) m_fin <= 1'b1; // 最后一拍数据，END 下一拍
      m_cnt <= m_cnt + 10'd1;
    end
  end

  bmp_read dut (
    .clk(clk), .rst(rst), .ready(ready),
    .scan_start(scan_start), .scan_start_sector(scan_start_sector),
    .scan_max_sector(scan_max_sector), .scan_target_count(scan_target),
    .scan_done(scan_done), .scan_found_valid(scan_found_valid),
    .scan_found_sector(scan_found_sector), .scan_found_total(scan_found_total),
    .load_start(load_start), .load_abort(load_abort), .load_sector(load_sector),
    .sd_init_done(sd_init_done), .state_code(state_code),
    .bmp_width(16'd640), .bmp_height(16'd480),
    .write_req(write_req), .write_req_ack(write_req_ack),
    .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end),
    .bmp_data_wr_en(bmp_data_wr_en), .bmp_data(bmp_data),
    .multi_res(mr), .real_w(), .real_h(), .pix_sov(), .pix_eov()   // v10.3: mr 由测试驱动
  );

  // ---- found 收集 ----
  reg [31:0] got [0:31];
  integer ngot = 0;
  always @(posedge clk) if (scan_found_valid && ngot < 32) begin
    got[ngot] = scan_found_sector;
    $display("  [hit] #%0d @ sector %0d (total=%0d)", ngot+1, scan_found_sector, scan_found_total);
    ngot = ngot + 1;
  end
  always @(posedge clk) if (write_req) write_req_ack <= #1 1'b1;

  task automatic do_scan(input [31:0] start, input [2:0] target);
    real t_end; begin
      ngot = 0;
      @(negedge clk);
      scan_start_sector = start; scan_target = target; scan_start = 1;
      @(negedge clk); scan_start = 0;
      t_end = $time + 1_000_000_000.0;          // 1s 仿真上限（够爬 2 万扇区）
      while (!dut.scan_done && $time < t_end) #1000;
      #100;
    end
  endtask
  reg scan_done_seen;

  integer errors = 0;
  integer t0;
  task automatic ck(input cond, input [8*64-1:0] name);
    begin
      if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end
      else $display("PASS: %0s", name);
    end
  endtask

  initial begin
    hdr_sec[0]=3760; hdr_sec[1]=5616; hdr_sec[2]=7472; hdr_sec[3]=9328;
    hdr_sec[4]=11184; hdr_sec[5]=13040; hdr_sec[6]=14896; hdr_sec[7]=16752;
    for (t0 = 0; t0 < 16; t0 = t0 + 1) begin fw[t0] = 16'd640; fh[t0] = 16'd480; end
    mr = 1'b0;
    repeat (10) @(negedge clk); rst = 0;
    repeat (5)  @(negedge clk); sd_init_done = 1;
    repeat (5)  @(negedge clk);

    // T1：5 张连续卡（复刻现场），从 3504（数据区起点）扫，target=7
    ncard = 5;
    $display("[T1] 5-file card, start=3504, target=7");
    do_scan(3504, 3'd7);
    ck(scan_done,           "T1 scan_done 置起");
    ck(ngot == 5,           "T1 找到全部 5 张（现场板子=4，若这里是5说明RTL无罪）");
    ck(got[4] == 11184,     "T1 第5张落在 sector 11184");

    // T2：5 张卡但从 sector 0 起扫（复刻真实开机走位，前面 3760 空扇区）
    $display("[T2] 5-file card, start=0, target=7");
    do_scan(0, 3'd7);
    ck(ngot == 5,           "T2 从0起步也能找齐 5 张");

    // T3：6 张卡 target=7（间距同真实卡）
    $display("[T3] 6-file card, start=3504, target=7");
    ncard = 6;
    do_scan(3504, 3'd7);
    ck(ngot == 6,           "T3 6 张全找");

    // T4：5 张卡但第5张与第4张间隔 9000 空扇区（>8191 止损）——验证止损行为
    $display("[T4] 5-file card with 9000-gap before #5, start=3504, target=7");
    ncard = 5; hdr_sec[4] = 20184;   // 9328+1801+9055 ≈ 新位置
    do_scan(3504, 3'd7);
    ck(ngot == 4,           "T4 大间隙后第5张被止损（这是设计行为）");

    // ============ T5（v10.3 板测预检核心）：修卡脚本的 13 图卡里，
    //   BMP0000~0004 = 5 张标准 640×480，BMP0005~0012 = 8 张多分辨率演示图。
    //   模拟卡取前 7 张（5 标准 + 2 演示 1280×720/1024×768），对照扫描登记门：
    //   mr=0（SC 0 上电默认）演示图在"登记阶段"就被拒 → 只登 5；
    //   mr=1（先 SC 1）演示图按 mr_ok 放宽 → 7 张全登。
    //   ⇒ 板测第 0 步必须先 `SC 1` 再 `SCAN32`，否则 8 张演示图根本进不了候选表。
    $display("[T5] reformat-card mix: 5x640x480 + 1280x720 + 1024x768");
    hdr_sec[4] = 11184;   // 复位 T4 对被复用槽的改写（9000-gap 实验残留）
    ncard = 7; fw[5]=16'd1280; fh[5]=16'd720; fw[6]=16'd1024; fh[6]=16'd768;
    mr = 1'b0; scan_max_sector = 32'd13100;   // 只需越过被拒演示图(13040)即证"没登记"，避免长尾空扫（省仿真时间）
    do_scan(3504, 3'd7);
    ck(ngot == 5, "T5a SC=0 扫描登记：演示图被登记门拒（只 5 张）→ 板测必须先 SC 1 的铁证");
    mr = 1'b1; scan_max_sector = 32'd16800;   // T5b 要装得下 7 张全登记（末图 14896 + 1801）
    do_scan(3504, 3'd7);
    ck(ngot == 7, "T5b SC=1 扫描登记：7 张全登（含 1280×720 与 1024×768）");
    ck(got[5] == 13040 && got[6] == 14896, "T5b 演示图扇区位置正确");
    mr = 1'b0; scan_max_sector = 32'd131071;

    $display("=== tb_bmpscan 完成: errors=%0d ===", errors);
    $finish;
  end
endmodule
