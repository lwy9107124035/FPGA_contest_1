// tb_bmpgate - v13.0 BMP acceptance gate: does a header's declared geometry have to
//   be backed by the file's own bytes, and does end-of-frame still land on junk-tolerant
//   files? This is the layer that produced the repeated 0x18 / black-screen-with-banner
//   signature: a registered file that cannot reach its declared pixel count parks the
//   scaler (img_scaler.v row_ok/eovr), so write_finish never fires.
//
// Compile the same source against the pre-v13 snapshot to see the old failure:
//   iverilog -o ../_tbgate_old.vvp tb_bmpgate.v bmp_read_pre_v13.v
//   iverilog -o ../_tbgate_new.vvp tb_bmpgate.v ../../user_source/hdl_source/SD/bmp_read.v
//   vvp ../_tbgate_old.vvp   -> C2/C3 FAIL (eov never arrives)
//   vvp ../_tbgate_new.vvp   -> all PASS
`timescale 1ns/1ps
module tb_bmpgate;
  parameter BASE   = 32'd100;      // header sector
  parameter IMG_W  = 16'd320;      // smallest width that still passes mr_ok (>=320, %4==0)
  parameter IMG_H  = 16'd80;       // 4:1, the widest aspect mr_ok still allows; 76800 pixel bytes
  parameter PIXREQ = IMG_W * IMG_H * 3;      // 76800
  parameter HDRLEN = 32'd54;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // ---- card model: one BMP whose bfSize is forced per case ----
  reg [31:0] flen = 32'd0;         // declared file length as stored in the header

  function [7:0] card_byte;
    input [31:0] sec; input [9:0] off;
    reg [31:0] f;
    begin
      f = flen;
      if (sec != BASE)            card_byte = 8'hA5;   // body bytes: nonzero junk
      else case (off)
        10'd0:  card_byte = "B";
        10'd1:  card_byte = "M";
        10'd2:  card_byte = f[7:0];
        10'd3:  card_byte = f[15:8];
        10'd4:  card_byte = f[23:16];
        10'd5:  card_byte = f[31:24];
        10'd10: card_byte = HDRLEN[7:0];                // pixel_offset = 54
        10'd11, 10'd12, 10'd13: card_byte = 8'h00;
        10'd18: card_byte = IMG_W[7:0];
        10'd19: card_byte = IMG_W[15:8];
        10'd20, 10'd21: card_byte = 8'h00;
        10'd22: card_byte = IMG_H[7:0];
        10'd23: card_byte = IMG_H[15:8];
        10'd24, 10'd25: card_byte = 8'h00;
        10'd28: card_byte = 8'h18;                      // 24 bpp
        10'd29, 10'd30, 10'd31, 10'd32, 10'd33: card_byte = 8'h00;
        default: card_byte = 8'hA5;
      endcase
    end
  endfunction

  // ---- SD read model (same 512-exact-then-END contract tb_bmpscan uses) ----
  wire       sd_sec_read;
  wire [31:0] sd_sec_read_addr;
  reg  [7:0]  sd_sec_read_data    = 0;
  reg         sd_sec_read_data_valid = 0;
  reg         sd_sec_read_end     = 0;
  reg  [31:0] m_addr = 32'hDEAD;
  reg  [9:0]  m_cnt = 0;
  reg         m_busy = 0;
  reg         m_fin  = 0;
  always @(posedge clk) begin
    sd_sec_read_data_valid <= 1'b0;
    sd_sec_read_end        <= 1'b0;
    if (sd_sec_read_addr !== m_addr) begin
      m_addr <= sd_sec_read_addr; m_cnt <= 0; m_busy <= 1'b0; m_fin <= 0;
    end else if (!sd_sec_read) begin
      m_busy <= 1'b0; m_fin <= 0;
    end else if (m_fin) begin
      sd_sec_read_end <= 1'b1; m_fin <= 1'b0; m_busy <= 1'b0;
    end else if (!m_busy) begin
      m_busy <= 1'b1;
    end else begin
      sd_sec_read_data       <= card_byte(m_addr, m_cnt);
      sd_sec_read_data_valid <= 1'b1;
      if (m_cnt == 10'd511) m_fin <= 1'b1;
      m_cnt <= m_cnt + 10'd1;
    end
  end

  // ---- DUT ----
  reg  scan_start = 0, load_start = 0, load_abort = 0, write_req_ack = 0, sd_init_done = 0;
  reg  mr = 1'b1;
  wire ready, scan_done, scan_found_valid, write_req, bmp_data_wr_en, pix_sov, pix_eov;
  wire [31:0] scan_found_sector;
  wire [2:0]  scan_found_total;
  wire [3:0]  state_code;
  wire [15:0] real_w, real_h;
  wire [23:0] bmp_data;

  bmp_read dut (
    .clk(clk), .rst(rst), .ready(ready),
    .scan_start(scan_start), .scan_start_sector(BASE),
    .scan_max_sector(32'd4096), .scan_target_count(3'd1),
    .scan_done(scan_done), .scan_found_valid(scan_found_valid),
    .scan_found_sector(scan_found_sector), .scan_found_total(scan_found_total),
    .load_start(load_start), .load_abort(load_abort), .load_sector(BASE),
    .sd_init_done(sd_init_done), .state_code(state_code),
    .bmp_width(16'd640), .bmp_height(16'd480),
    .write_req(write_req), .write_req_ack(write_req_ack),
    .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end),
    .bmp_data_wr_en(bmp_data_wr_en), .bmp_data(bmp_data),
    .multi_res(mr), .real_w(real_w), .real_h(real_h),
    .pause(1'b0),
    .pix_sov(pix_sov), .pix_eov(pix_eov)
  );

  integer pix_seen, eov_seen, sov_seen;
  reg     write_req_handled;
  always @(posedge clk) begin
    if (bmp_data_wr_en) pix_seen = pix_seen + 1;
    if (pix_eov)        eov_seen = eov_seen + 1;
    if (pix_sov)        sov_seen = sov_seen + 1;
  end
  always @(posedge clk) if (write_req) write_req_ack <= #1 1'b1;
  always @(posedge clk) if (write_req_ack) write_req_handled <= 1'b1;

  integer errors = 0;
  task ck(input cond, input [8*72-1:0] name);
    begin
      if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end
      else       $display("PASS: %0s", name);
    end
  endtask

  integer dbg_beats = 0;
`ifdef DBG
  always @(negedge clk) begin
    dbg_beats = dbg_beats + 1;
    if ((dbg_beats % 2000) == 0)
      $display("  t=%0t st=%0d flen=%0d needed=%0d hm=%0b size_ok=%0b off=%0d w=%0d h=%0d fl=%0d",
               $time, state_code, flen, HDRLEN + PIXREQ, dut.header_match, dut.size_ok,
               dut.pixel_offset, dut.width[15:0], dut.height[15:0], dut.file_len);
  end
`endif

  // One load attempt. Runs a fixed window: 40 body sectors x 512 beats plus margin,
  // so a case that never terminates (the pre-v13 park) is visible as a missing eov
  // rather than hanging the simulation.
  localparam WINDOW = 140000;
  task automatic try_load(input [31:0] declared_len);
    integer t0;
    begin
      flen      = declared_len;
      pix_seen  = 0; eov_seen = 0; sov_seen = 0;
      write_req_handled = 0; write_req_ack = 0;
      @(negedge clk); rst = 1;
      repeat (4) @(negedge clk); rst = 0;
      repeat (4) @(negedge clk); sd_init_done = 1;
      @(negedge clk); load_start = 1;
      @(negedge clk); load_start = 0;
      for (t0 = 0; t0 < WINDOW; t0 = t0 + 1) @(negedge clk);
`ifdef DBG
      $display("  -> pix=%0d eov=%0d wr_en_total=%0d bmp_len_cnt=%0d st=%0d abort=%0b",
               pix_seen, eov_seen, pix_seen, dut.bmp_len_cnt, state_code, dut.load_abort);
`endif
    end
  endtask

  initial begin
    write_req_handled = 0;
    $display("=== tb_bmpgate: declared geometry vs actual bytes ===");

    // C1 well-formed: bfSize == 54 + 3*w*h. The gate must accept it and the frame must
    //   close with exactly IMG_W*IMG_H pixels and one eov.
    $display("[C1] exact file (bfSize = 54 + 3*w*h)");
    try_load(HDRLEN + PIXREQ);
    ck(write_req_handled,          "C1 accepted for load (header gate passes)");
    ck(pix_seen  == IMG_W*IMG_H,   "C1 pixel count == declared w*h");
    ck(eov_seen  == 1,             "C1 pix_eov fired exactly once");
    ck(sov_seen  == 1,             "C1 pix_sov fired once, ahead of first pixel");

    // C2 trailing junk: bfSize 4 bytes longer than the pixel area. A real card hits this
    //   (writer pads, or the file carries a trailer). Old code required the final byte to
    //   land on pixel byte index 2, so with junk in the way eov never arrived -> permanent
    //   park -> no write_finish -> black screen + banner.
    $display("[C2] file 4 bytes longer than the pixel area");
    write_req_handled = 0;
    try_load(HDRLEN + PIXREQ + 32'd4);
    ck(write_req_handled,          "C2 accepted for load");
    ck(pix_seen  == IMG_W*IMG_H,   "C2 pixel stream stops at declared w*h (no junk pixels)");
    ck(eov_seen  == 1,             "C2 pix_eov still fires exactly once  <== the park bug");

    // C3 truncated: bfSize claims the file is complete but the pixel area is short.
    //   Must be REJECTED at the header, not registered and loaded.
    $display("[C3] truncated file (bfSize < 54 + 3*w*h)");
    write_req_handled = 0;
    try_load(HDRLEN + PIXREQ - 32'd3072);
    ck(!write_req_handled,         "C3 refused: declared pixels not backed by bytes");
    ck(pix_seen == 0,              "C3 emitted no pixels");

    // C4 lying bfSize far too large: the load would only end on the 2.5 s timeout, so
    //   an over-claiming header is refused as well. (1 MiB slack over the pixel area.)
    $display("[C4] bfSize claims ~4 GB");
    try_load(32'hFFFF_FFF0);
    ck(!write_req_handled,         "C4 refused: bfSize implausibly larger than geometry");
    ck(pix_seen == 0,              "C4 emitted no pixels");

    // C5 slack inside the bound (writer added a small trailer): must still close.
    $display("[C5] bfSize 4 KiB over the pixel area (within slack)");
    try_load(HDRLEN + PIXREQ + 32'd4096);
    ck(write_req_handled,          "C5 accepted (slack not too tight)");
    ck(pix_seen == IMG_W*IMG_H,    "C5 pixel stream bounded by declared w*h");
    ck(eov_seen == 1,              "C5 pix_eov fired exactly once");

    $display("=== tb_bmpgate done: errors=%0d ===", errors);
    if (errors != 0) $display("RESULT: FAIL");
    else             $display("RESULT: PASS");
    $finish;
  end
endmodule
