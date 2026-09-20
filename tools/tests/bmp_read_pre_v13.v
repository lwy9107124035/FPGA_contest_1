module bmp_read(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    // v12 (B3-lite): 源侧限流。1 = 下游缩放器环形缓存将满, 本拍不要发起下一个扇区读。
    //   只在扇区间隙生效: 控制器在 S_WAIT_READ_WRITE 等 sd_sec_read, 拉低即等待,
    //   不打断已发出的 CMD17(在飞扇区照常收完), 无超时/协议风险。
    input                       pause,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,

    // v10.3 扩展3：多分辨率放宽（multi_res=0 时一切与 v10.2 位级一致）
    input                       multi_res,       // = msg_ink scale_en（准静态）
    output      [15:0]          real_w, real_h,  // 头里读到的真实宽高（LOAD_DATA 期稳定）
    output                      pix_sov,         // 帧首：领先首个 bmp_data_wr_en ≥1 拍
    output wire                 pix_eov          // 与最后一个 bmp_data_wr_en 同拍
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
// v10.1: 目录尾止损——首次命中后连续空扇区计数。命中过 BMP 之后再连续 8192 个
//   扇区（4MB，大于一切真实的交错文件间隙：音频 ~0.5-2MB）无 BMP 即判定卡片穷尽。
//   9/6 实测: 4图卡 target=7 全卡单步爬 = 37 秒，SCAN32 链扫每趟尾都踩此雷。
//   hit_seen 门控另护引导/FAT 保留区（大卡上该区间可达数万扇区）。
reg [15:0] scan_miss_run;
reg        scan_hit_seen;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;

wire header_match;
wire bmp_data_valid;
wire [31:0] file_sector_count;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;

assign ready = (state == ST_IDLE);
// v10.3 扩展3：multi_res=0 走 v10.2 原判定(逐位一致)；=1 放宽为"缩放器合法域"：
//   320≤w≤1280, 16≤h≤1080, 宽高比≤4:1, 且 w%4==0 —— 最后一条件是关键防坑：
//   BMP 每行补零到 4 字节，w%4==0 时行内无填充，像素流才是"干净矩形"。
//   (w 的 4 倍数 ⇔ w*3 的 4 倍数，因 3 与 4 互质，故直接查 w[1:0]==0)
wire mr_ok = (width[15:0]  >= 16'd320 ) && (width[15:0]  <= 16'd1280) &&
             (height[15:0] >= 16'd16  ) && (height[15:0] <= 16'd1080) &&
             (width[15:0]  <= (height[15:0] << 2)) &&
             (height[15:0] <= (width[15:0]  << 2)) &&
             (width[1:0] == 2'b00);
assign header_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0) &&
                      (multi_res ? mr_ok
                               : ((width[15:0]  == bmp_width) &&
                                  (height[15:0] == bmp_height)));
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt <  file_len);
assign file_sector_count = (file_len == 32'd0) ? 32'd1 : ((file_len + 32'd511) >> 9);
assign next_scan_sector_if_match = scan_sector + file_sector_count;
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    bmp_data_wr_en  <= 1'b1;
                    bmp_data[23:16] <= sd_sec_read_data;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
    end
end

// v10.3 扩展3 帧边界/真实尺寸（multi_res=0 时下游旁路，这些信号无人认领也无害）
//   real_w/h：LOAD_HDR 期从 18..25 字节解析进 width/height 寄存器；LOAD_DATA 期
//     rd_cnt 冻结在 SCAN/LOAD_HDR 分支 ⇒ 像素流全程稳定，可直接喂缩放器锁存。
//   pix_sov：ack 收下进 LOAD_DATA 的那一拍脉冲；首像素要等扇区取数(≥数十拍)，
//     天然满足缩放器"sov 领先首个 in_en ≥1 拍"的契约。
//   pix_eov：文件最后一个字节恰为像素第 3 字节(idx==2) 时寄存一拍，
//     与最后一个 bmp_data_wr_en 精确同拍（防御性再与 wr_en 相与）。
assign real_w = width[15:0];
assign real_h = height[15:0];
reg pix_sov_q, pix_eov_q;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        pix_sov_q <= 1'b0;
        pix_eov_q <= 1'b0;
    end else begin
        pix_sov_q <= (state == ST_LOAD_WAIT) && write_req_ack;
        pix_eov_q <= (state == ST_LOAD_DATA) && bmp_data_valid &&
                     (bmp_len_cnt == (file_len - 32'd1)) && (bmp_byte_idx == 2'd2);
    end
end
assign pix_sov = pix_sov_q;
assign pix_eov = pix_eov_q && bmp_data_wr_en;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
    end else if (!sd_init_done || load_abort) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
    end else begin
        scan_found_valid <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    scan_miss_run    <= 16'd0;         // v10.1
                    // v10.1: 从 0 扫=目录尚未见到，hit_seen 归零（保护引导区/FAT 大段空区）；
                    //   续扫起点>0=已在目录中部，直接视为"见过"，让 8192 空扇区止损生效，
                    //   否则链式趟（卡上图数<target 的尾趟）会退回 37 秒全卡爬行。
                    scan_hit_seen    <= (scan_start_sector != 32'd0);
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_match) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;
                        scan_miss_run     <= 16'd0;          // v10.1
                        scan_hit_seen     <= 1'b1;           // v10.1

                        if ((scan_found_total + 3'd1 >= scan_target_count) || (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end
                    end else begin
                        if (scan_sector >= scan_max_sector ||
                            (scan_hit_seen && scan_miss_run >= 16'd8191)) begin   // v10.1: 目录尾止损
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            scan_miss_run    <= scan_miss_run + 16'd1;           // v10.1
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (bmp_len_cnt >= file_len) begin
                        state <= ST_IDLE;
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end else if (!pause) begin
                    // v12: pause=1 时不再发起新扇区（保持 0，等下游腾出环槽）。
                    //   已发出的 CMD17 不受影响：控制器在 S_CMD17/S_READ 期间不看
                    //   sd_sec_read，照样把该扇区收完再回 S_WAIT_READ_WRITE。
                    sd_sec_read <= 1'b1;
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
