// top_tf_hdmi_audio.v (v10.3 ext3 comments partially garbled by an encoding accident; code is authoritative)
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // input key2, // (TD coredump if declared; implicit net keeps HDL-5314 warn, elab green)
	output [5:0]                seg_sel,
	output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso,

    // board USB-UART bridge (official demo16 pin map: rx=F12, tx=D12)
    input                       uart_rx,
    output                      uart_tx,

    // onboard passive buzzer (official 9_MUX_buzz pin map: H11; SW7 must be ON)
    output                      buzzer,

    // v5: user FLASH W25Q64 on general IO (schematic: CS=P8 SDO=N8 SDI=P7 SCLK=M9)
    output                      c_flash_cs,
    output                      c_flash_sck,
    output                      c_flash_mosi,     // FPGA -> flash (schematic SDO)
    input                       c_flash_miso,     // flash -> FPGA (schematic SDI)
    output                      c_flash_wp,       // tie 1
    output                      c_flash_hold      // tie 1
);

assign c_flash_wp   = 1'b1;
assign c_flash_hold = 1'b1;

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;

// v10 d_card_bmp -> msg_ink
// HDL-7225
wire [7:0]  stall_sig_now;
wire [7:0]  stall_hist1;
wire [7:0]  stall_hist2;
wire [7:0]  stall_cnt;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// F + HDMI
wire sys_pll_lock;
wire video_pll_lock;
wire rst_all;

reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg = 1'b1;

always @(posedge clk) begin
    if (!rst_n) begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end else if (!rst_all_reg) begin
        // PLL rst_all_reg <= 1'b0;
    end else if (sys_pll_lock && video_pll_lock) begin
        // PLL 20ms @ 50MHz
        if (rst_cnt < 20'd1_000_000) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_all_reg <= 1'b1;
        end else begin
            rst_all_reg <= 1'b0;
        end
    end else begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end
end

assign rst_all = rst_all_reg;

// TF / SDRAM / video
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

// mem_clk write_finish toggle sd_card_clk
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_all),
    .key_next          (key1),
    .key_auto          (key2),
    .soft_next_btn     (press1),
    .soft_auto_btn     (press2),
    .soft_prev_btn     (press3),
    .list_cnt_o        (list_cnt),
    .list_depth_o      (list_depth),
    .list_cur_o        (list_cur),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .multi_res         (msg_scale_en),      // v10.3 ext3
    .real_w            (sd_real_w),
    .real_h            (sd_real_h),
    .pix_sov           (sd_pix_sov),
    .pix_eov           (sd_pix_eov),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso),
    .dbg_o             (sd_dbg),
    // v10
    .stall_sig_now     (stall_sig_now),
    .stall_hist1       (stall_hist1),
    .stall_hist2       (stall_hist2),
    .stall_cnt         (stall_cnt),
    // v7: runtime playback params (SPD/T/PLY/PLYALL/SCAN4/SCAN7/SCAN32/VID), see PLAYER_V7_CONTRACT
    .prm_tgl           (prm_tgl),
    .prm_code          (prm_code),
    .prm_a             (prm_a),
    .prm_b             (prm_b)
);

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,7'b1111_111}),
    .seg_data_1        ({1'b1,7'b1111_111}),
    .seg_data_2        ({1'b1,7'b1111_111}),
    .seg_data_3        ({1'b1,7'b1111_111}),
    .seg_data_4        ({1'b1,7'b1111_111}),
    .seg_data_5        ({1'b1,seg_data_0})
);

// ===================== =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);


// (OSD) assign vout_baseosd_banner
wire [23:0] vout_base;
assign vout_base = display_valid ? vout_data_raw : 24'd0;
// ===================== v10.3 ext2 / ext4 / ext5 =====
wire [23:0] fx_rgb;
wire        fx_frame_start = de && (osd_x == 10'd0) && (osd_y == 9'd0);
vout_fx u_vout_fx (
    .clk         (video_clk),
    .rst_n       (~rst_all),
    .de          (de),
    .px          (osd_x),
    .py          (osd_y),
    .disp_idx    (disp_buf_idx),
    .br_lvl      (msg_br_lvl),
    .gn_lvl      (msg_gn_lvl),
    .fd_mode     (msg_fd_mode),
    .frame_start (fx_frame_start),
    .audio_valid (audio_valid),
    .audio_left  (audio_left),
    .vu_lvl0(fx_vu0), .vu_lvl1(fx_vu1), .vu_lvl2(fx_vu2), .vu_lvl3(fx_vu3),
    .vu_lvl4(fx_vu4), .vu_lvl5(fx_vu5), .vu_lvl6(fx_vu6), .vu_lvl7(fx_vu7),
    .rgb_in      (vout_base),
    .rgb_out     (fx_rgb)
);

// + + VU
v103_overlay u_v103_overlay (
    .clk      (video_clk),
    .rst_n    (~rst_all),
    .de       (de),
    .x        ({2'd0, osd_x}),
    .y        ({3'd0, osd_y}),
    .rgb_in   (vout_osd),
    .rgb_out  (vout_data),
    .clk_en   (msg_clk_on),
    .vu_en    (msg_vu_on),
    .vu0(fx_vu0), .vu1(fx_vu1), .vu2(fx_vu2), .vu3(fx_vu3),
    .vu4(fx_vu4), .vu5(fx_vu5), .vu6(fx_vu6), .vu7(fx_vu7),
    .br_lvl   (msg_br_lvl),
    .gn_lvl   (msg_gn_lvl),
    .vol_lvl  (vol_lvl)
);

// ===================== OSD =====================
// video_timing_data h_cnt/v_cnt vout_data_raw
// de/vsideo_delay 0 x/y// de=1 x 640 y+1 vs
reg [9:0] osd_x;
reg [8:0] osd_y;
reg       osd_vs_d0;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        osd_x     <= 10'd0;
        osd_y     <= 9'd0;
        osd_vs_d0 <= 1'b0;
    end else begin
        osd_vs_d0 <= vs;
        if (de) begin
            if (osd_x == 10'd639) begin
                osd_x <= 10'd0;
                osd_y <= (osd_y == 9'd479) ? 9'd0 : (osd_y + 1'b1);
            end else begin
                osd_x <= osd_x + 1'b1;
            end
        end else if (vs & ~osd_vs_d0) begin   // osd_x <= 10'd0;
            osd_y <= 9'd0;
        end
    end
end

// ===================== OSD vout_data =====================
// ---- v6: msg_ink -> osd 22B23121 we/waddr/wdata ----
wire        msg_we;
wire [4:0]  msg_wslot;
wire [15:0] msg_wcode;
wire        msg_commit;
// ---- v6: osd video 5SPI ----
wire        xcd_req_v;
wire [19:0] xcd_addr_v;
wire        xcd_new_v;
wire [255:0] xcd_out_v;
wire        xcd_busy_v;
wire        emg_mode;
wire [1:0]  emg_sel;
osd_banner u_osd_banner (
    .clk     (video_clk),
    .rst_n   (~rst_all),
    .de      (de),
    .x       ({2'd0, osd_x}),
    .y       ({3'd0, osd_y}),
    .rgb_in  (fx_rgb),
    .rgb_out (vout_osd),
    .msg_we     (msg_we),
    .msg_wslot  (msg_wslot),
    .msg_wcode  (msg_wcode),
    .msg_commit (msg_commit),
    .emg_mode(emg_mode),
    .emg_sel (emg_sel),
    .txt_col_sel(msg_txt_col),
    .col_exec    (msg_col_exec),   // v10.1 emg-red unlock
    .sr_spd      (msg_sr_spd),        // v10.3 ext1 smooth marquee
    .xcd_req_v     (xcd_req_v),
    .xcd_addr_v    (xcd_addr_v),
    .xcd_new_v     (xcd_new_v),
    .xcd_out_v     (xcd_out_v),
    .xcd_busy_v    (xcd_busy_v),
    .loader_inhibit(loader_active_v)
);

// ===================== UART SD v2ideo_clk =====================
reg uart_rx_d0, uart_rx_d1;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin uart_rx_d0 <= 1'b1; uart_rx_d1 <= 1'b1; end
    else begin uart_rx_d0 <= uart_rx; uart_rx_d1 <= uart_rx_d0; end
end

wire [7:0] urx_byte;
wire       urx_valid;
uart_rx #(.CLK_HZ(25175000), .BAUD(115200)) u_uart_rx (
    .clk      (video_clk),
    .rst_n    (~rst_all),
    .rx       (uart_rx_d1),
    .byte_o   (urx_byte),
    .byte_vld (urx_valid)
);

wire       tx_start, tx_done;
wire [7:0] tx_byte;
wire [3:0] vol_lvl;
wire       next_pulse, auto_pulse;
wire       prev_pulse;   // v10.2: PREV next
wire [5:0] list_cnt, list_depth;   // v10.2: LIST
wire [4:0] list_cur;
wire       ls_tgl;
wire [7:0] sd_dbg;                   // v5c: {scan_done,load_busy,auto_en,disp_valid,img_idx,load_idx}
wire       loader_active_v;          // from clk50 domain, 2FF-synced
// v7 WP-E/F: msg_ink -> player parameter channel (quasi-static data + toggle)
// v10: prm_code 7=SCAN32 8=VID()
wire       prm_tgl;
wire [3:0] prm_code, prm_a;
wire [7:0] prm_b;
wire [2:0] msg_txt_col;             // v7.2 "COL" palette, msg_ink -> osd (same domain)
wire       msg_col_exec;            // v10.1 "COL" execute strobe -> osd unlocks emg red// ---- v10.3 msg_ink -> vout_fx / v103_overlay----
wire [3:0] msg_br_lvl, msg_gn_lvl;
wire [1:0] msg_fd_mode;
wire       msg_clk_on, msg_vu_on;
wire [2:0] msg_sr_spd;
// ---- v10.3 ext3: multi-res scale (msg_ink "SC 0/1") + scaler taps ----
wire       msg_scale_en;
wire       sd_pix_sov, sd_pix_eov;
wire [15:0] sd_real_w, sd_real_h;
wire       sc_out_en;
wire [31:0] sc_out_data;
wire [23:0] vout_osd;                 // banner
wire [3:0]  fx_vu0, fx_vu1, fx_vu2, fx_vu3, fx_vu4, fx_vu5, fx_vu6, fx_vu7;
wire       msg_tx_pad;               // uart tx wire driven by msg_ink's tx
wire       ld_tx_pad;                // uart tx wire driven by loader's tx (50M)

msg_ink u_msg_ink (
    .clk      (video_clk),
    .rst_n    (~rst_all),
    .rx_byte  (urx_byte),
    .rx_vld   (urx_valid && !loader_active_v),   // v5: bytes belong to loader while active
    .de       (de),
    .msg_we    (msg_we),
    .msg_wslot (msg_wslot),
    .msg_wcode (msg_wcode),
    .msg_commit(msg_commit),
    .tx_start (tx_start),
    .tx_byte  (tx_byte),
    .tx_done  (tx_done),
    .emg_mode (emg_mode),
    .emg_sel  (emg_sel),
    .vol_lvl  (vol_lvl),
    .txt_col  (msg_txt_col),         // v7.2 "COL" msg text palette
    .col_exec (msg_col_exec),        // v10.1 emg-red unlock strobe
    .br_lvl   (msg_br_lvl),            // v10.3 "BR n"
    .gn_lvl   (msg_gn_lvl),            // v10.3 "GN n"
    .fd_mode  (msg_fd_mode),           // v10.3 "FD n"
    .clk_on   (msg_clk_on),            // v10.3 "CK n"
    .vu_on    (msg_vu_on),             // v10.3 "VU n"
    .sr_spd   (msg_sr_spd),            // v10.3 "SR n"
    .scale_en (msg_scale_en),          // v10.3 ext3 "SC n"
    .next_pulse (next_pulse),
    .auto_pulse (auto_pulse),
    .prev_pulse (prev_pulse),   // v10.2
    .list_cnt   (list_cnt),
    .list_depth (list_depth),
    .list_cur   (list_cur),
    .ls_tgl   (ls_tgl),
    .prm_tgl  (prm_tgl),
    .prm_code (prm_code),
    .prm_a    (prm_a),
    .prm_b    (prm_b),
    // v10 -> WHY
    .stall_now(stall_sig_now),
    .stall_h1 (stall_hist1),
    .stall_h2 (stall_hist2),
    .stall_cnt(stall_cnt),
    .dbg      (sd_dbg)
);

// ---- v4b: NEXT/AUTO 150ms ""----
reg        press1, press2, press3;   // v10.2
reg [23:0] kc1, kc2, kc3;
localparam integer K150MS = 24'd7552500;               // v5: 300ms @ 25.175MHz
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        press1 <= 1'b0; press2 <= 1'b0; press3 <= 1'b0;
        kc1 <= 22'd0;   kc2 <= 22'd0;   kc3 <= 22'd0;
    end else begin
        if (next_pulse)          begin press1 <= 1'b1; kc1 <= 22'd0; end
        else if (press1)         begin if (kc1 >= K150MS) press1 <= 1'b0; else kc1 <= kc1 + 22'd1; end
        if (prev_pulse)          begin press3 <= 1'b1; kc3 <= 22'd0; end   // v10.2
        if (auto_pulse)          begin press2 <= 1'b1; kc2 <= 22'd0; end
        else if (press2)         begin if (kc2 >= K150MS) press2 <= 1'b0; else kc2 <= kc2 + 22'd1; end
        else if (press3)         begin if (kc3 >= K150MS) press3 <= 1'b0; else kc3 <= kc3 + 22'd1; end
    end
end
// v5d: sd_card_bmp soft_next_btn/soft_auto_btnress1/press2
// key1/key2 key1_eff/key2_eff

// ---- v3: EMG ~3.07kHz = video_clk / 8192---
reg [12:0] buzz_div;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) buzz_div <= 13'd0;
    else         buzz_div <= buzz_div + 13'd1;
end
assign buzzer = (emg_mode | press1 | press3) & buzz_div[12];   // v10.2: PREV // v5: press1=NEXT 300ms
uart_tx #(.CLK_HZ(25175000), .BAUD(115200)) u_uart_tx (
    .clk     (video_clk),
    .rst_n   (~rst_all),
    .start   (tx_start),
    .byte_i  (tx_byte),
    .busy    (),
    .done    (tx_done),
    .tx_pad  (msg_tx_pad)
);

// ===================== v5: LOAD lk50 + + TX=====================
wire       ld_tx_start;
wire [7:0] ld_tx_byte;
wire       ld_tx_done;
wire       loader_active;            // authoritative, lives in clk50
wire [1:0] fp_cmd;
wire [23:0] fp_addr;
wire       fp_buf_we, fp_busy, fp_done, fp_to;
wire [7:0] fp_buf_widx, fp_buf_wdata;
wire [255:0] fp_rd_q;

// ---- (a) LOAD ideo toggle clk50 1 ----
reg        ls_s1, ls_s2, ls_s3;
always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin ls_s1 <= 1'b0; ls_s2 <= 1'b0; ls_s3 <= 1'b0; end
    else begin ls_s1 <= ls_tgl; ls_s2 <= ls_s1; ls_s3 <= ls_s2; end
end
wire ls_pulse = ls_s2 ^ ls_s3;

// ---- (b) RX video togglebyte_holdclk50 ----
reg [7:0]  ld_byte_hold;
reg        ld_byte_tgl;
reg        lb_s1, lb_s2, lb_s3;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin ld_byte_hold <= 8'd0; ld_byte_tgl <= 1'b0; end
    else if (urx_valid) begin
        ld_byte_hold <= urx_byte;
        ld_byte_tgl  <= ~ld_byte_tgl;              // gl 50M
    end
end
always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin lb_s1 <= 1'b0; lb_s2 <= 1'b0; lb_s3 <= 1'b0; end
    else begin lb_s1 <= ld_byte_tgl; lb_s2 <= lb_s1; lb_s3 <= lb_s2; end
end
wire       ld_rx_vld  = lb_s2 ^ lb_s3;
wire [7:0] ld_rx_byte = ld_byte_hold;              // >=2 6us
// ---- (c) loader_active video ----
reg act_s1, act_s2;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin act_s1 <= 1'b0; act_s2 <= 1'b0; end
    else begin act_s1 <= loader_active; act_s2 <= act_s1; end
end
assign loader_active_v = act_s2;

// ---- (d) uart_txlk50pad loader_active_v ----
uart_tx #(.CLK_HZ(50000000), .BAUD(115200)) u_uart_tx_ld (
    .clk     (clk),
    .rst_n   (~rst_all),
    .start   (ld_tx_start),
    .byte_i  (ld_tx_byte),
    .busy    (),
    .done    (ld_tx_done),
    .tx_pad  (ld_tx_pad)
);
assign uart_tx = loader_active ? ld_tx_pad : msg_tx_pad;   // 50M 1

// ---- (e) loader + flash ----
uart_loader u_uart_loader (
    .clk50         (clk),
    .I_rst         (rst_all),
    .loader_start  (ls_pulse),
    .rx_byte       (ld_rx_byte),
    .rx_vld        (ld_rx_vld),
    .loader_active (loader_active),
    .ld_tx_start   (ld_tx_start),
    .ld_tx_byte    (ld_tx_byte),
    .ld_tx_done    (ld_tx_done),
    .fp_cmd        (fp_cmd),
    .fp_addr       (fp_addr),
    .fp_buf_we     (fp_buf_we),
    .fp_buf_widx   (fp_buf_widx),
    .fp_buf_wdata  (fp_buf_wdata),
    .fp_busy       (fp_busy),
    .fp_done       (fp_done),
    .fp_to         (fp_to),
    .fp_rd_q       (fp_rd_q)
);

flash_pp u_flash_pp (
    .clk50         (clk),
    .I_rst         (rst_all),
    .cmd_i         (fp_cmd),
    .cmd_addr_i    (fp_addr),
    .pp_buf_we     (fp_buf_we),
    .pp_buf_widx   (fp_buf_widx),
    .pp_buf_wdata  (fp_buf_wdata),
    .pp_busy       (fp_busy),
    .pp_done       (fp_done),
    .pp_to         (fp_to),
    .pp_rd_q       (fp_rd_q),
    .flash_cs_n    (pp_cs),      // v6: SPI
    .flash_sck     (pp_sck),
    .flash_mosi    (pp_mosi),
    .flash_miso    (c_flash_miso)
);

// ============ v6: W25Q64 9 SPI ============
// )FLASH // loader_active ISO
wire pp_cs, pp_sck, pp_mosi;
wire gf_cs, gf_sck, gf_mosi;
assign c_flash_cs   = loader_active ? pp_cs : gf_cs;
assign c_flash_sck  = loader_active ? pp_sck : gf_sck;
assign c_flash_mosi = loader_active ? pp_mosi : gf_mosi;

wire        g_x_fetch_req;
wire [19:0] g_x_fetch_addr;
wire        g_x_fetch_busy, g_x_fetch_done;
wire [255:0] g_x_fetch_data;

glyph_fetch u_glyph_fetch (
    .clk        (clk),
    .rst_n      (~rst_all),
    .fetch_req  (g_x_fetch_req),
    .glyph_addr (g_x_fetch_addr),
    .glyph_data (g_x_fetch_data),
    .fetch_done (g_x_fetch_done),
    .busy       (g_x_fetch_busy),
    .flash_cs_n (gf_cs),
    .flash_sck  (gf_sck),
    .flash_mosi (gf_mosi),
    .flash_miso (c_flash_miso)
);

glyph_xcd u_glyph_xcd (
    .clk50        (clk),
    .rst50_n      (~rst_all),
    .fetch_req    (g_x_fetch_req),
    .fetch_addr   (g_x_fetch_addr),
    .fetch_busy   (g_x_fetch_busy),
    .fetch_done   (g_x_fetch_done),
    .fetch_data   (g_x_fetch_data),
    .vclk         (video_clk),
    .vrst_n       (~rst_all),
    .req_v        (xcd_req_v),
    .addr_v       (xcd_addr_v),
    .busy_v       (xcd_busy_v),
    .glyph_ready_v(),
    .new_v        (xcd_new_v),
    .out_v        (xcd_out_v),
    .out_addr_v   (),
    .drop_err_v   ()
);

// ===================== v4: HDMI =====================
// alarm_tone(+VOL0-9) --48k PCM--> HDMI1.4b
// audio_arc_calculate() --ACR-->
wire       audio_valid;
wire [23:0] audio_left, audio_right;
wire       acr_valid;
wire [19:0] acr_cts, acr_n;

alarm_tone u_alarm_tone (
    .I_clk             (video_clk),
    .I_rst             (rst_all),
    .tone_en           (emg_mode),
    .vol               (vol_lvl),
    .O_audio_valid     (audio_valid),
    .O_audio_left_data (audio_left),
    .O_audio_right_data(audio_right)
);

audio_arc_calculate #(.ACR_N(6144)) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ================= v10.3 3=================
// frame_read_write
// NOTE: all new ext3 wires declared at L422-426 (declare-before-use, no implicit nets).
// frame_read_write write_len rite_finish
// emo 640480
wire sc_fd;
// v10.3 ext3：多分辨率缩放器（SC 1 时替换 v10.2 逐拍直通路）
img_scaler u_img_scaler (
    .clk        (sd_card_clk),
    .rst_n      (~rst_all),
    .in_en      (sd_card_write_en),
    .in_data    (sd_card_write_data),
    .src_w      (sd_real_w),
    .src_h      (sd_real_h),
    .in_sov     (sd_pix_sov),
    .in_eov     (sd_pix_eov),
    .out_en     (sc_out_en),
    .out_data   (sc_out_data),
    .frame_done (sc_fd)
);

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd0),
    .read_addr_3       (24'd0),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (24'd0),
    .write_addr_3      (24'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (msg_scale_en ? sc_out_en : sd_card_write_en),
    .write_data        (msg_scale_en ? sc_out_data : sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== RGB/DE AXIS =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// EDID
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// ===================== HDMI 1.4b =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left),
    .I_audio_right_data (audio_right),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
