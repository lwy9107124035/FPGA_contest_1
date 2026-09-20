// dc3_link.v - layer 1 of the inter-board 8-bit source-synchronous link (plan V3 sec 4).
// Per direction: DATA[7:0] + forwarded CLK + VALID + reverse READY = 11 lines.
// The two directions use separate wires, so there is no bus contention.
//
// Phase convention, chosen so only posedge logic is inferred:
//   the sender launches a byte when the forwarded clock FALLS and the receiver
//   captures it on the next RISE, i.e. a full half period (50 ns at 10 MHz) of
//   setup budget instead of clock-to-out plus trace skew.
//
// READY is a level, not a brake. When the receiver drops it there are still
// RX_FREE_GUARANTEE free slots, while the sender can have at most one byte in
// flight plus the synchroniser latency. That is why no block-size coupling is
// needed here; the guarantee is deliberately much larger than the requirement.
//
// Not board-specific on purpose: no pin table, no PLL, no ODDR. Turning link_clk
// into a glitch-free forwarded clock at the pin, and the generated-clock / CDC
// constraints around it, is a separate implementation step that the plan refuses
// to guess at until the DC3 wiring is measured.

`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// Async FIFO, 8 bits wide, gray pointers with two-flop copies.
// Write clock is the recovered forwarded clock; read clock is the local domain.
// ---------------------------------------------------------------------------
module dc3_afifo8 #(
    parameter AW = 10                      // depth = 1 << AW
)(
    input  wire       wclk,
    input  wire       wreset,
    input  wire       winc,
    input  wire [7:0] wdata,
    input  wire       rclk,
    input  wire       rreset,
    input  wire       rinc,
    output wire [7:0] rdata,
    output wire       wfull,
    output wire       rempty,
    output reg  [AW:0] wfill,              // occupied slots, write-side view
    output reg  [AW:0] rfill               // occupied slots, read-side view
);
    localparam DEPTH = (1 << AW);

    reg [7:0] mem [0:DEPTH-1];

    reg  [AW:0] wptr_bin, wptr_gray;
    reg  [AW:0] rptr_bin, rptr_gray;
    reg  [AW:0] rptr_gray_w1, rptr_gray_w2;   // read pointer, in the write domain
    reg  [AW:0] wptr_gray_r1, wptr_gray_r2;   // write pointer, in the read domain

    // Gray codes cross one bit at a time, so a two-flop copy is exact; converting
    // the copy back to binary locally is what makes the fill levels safe. Binary
    // pointers must never be synchronised directly.
    function [AW:0] g2b;
        input [AW:0] g;
        integer i;
        begin
            for (i = 0; i <= AW; i = i + 1)
                g2b[i] = ^(g >> i);
        end
    endfunction

    wire [AW:0] rptr_bin_w = g2b(rptr_gray_w2);
    wire [AW:0] wptr_bin_r = g2b(wptr_gray_r2);

    // full: gray write pointer equals the read pointer with the two MSBs inverted.
    // empty: the two gray pointers are identical.
    assign wfull  = (wptr_gray == {~rptr_gray_w2[AW:AW-1], rptr_gray_w2[AW-2:0]});
    assign rempty = (rptr_gray == wptr_gray_r2);

    always @(posedge wclk or posedge wreset) begin
        if (wreset) begin
            wptr_bin  <= {(AW+1){1'b0}};
            wptr_gray <= {(AW+1){1'b0}};
        end else if (winc && !wfull) begin
            mem[wptr_bin[AW-1:0]] <= wdata;
            wptr_bin  <= wptr_bin + 1'b1;
            wptr_gray <= (wptr_bin + 1'b1) ^ (((wptr_bin + 1'b1) >> 1));
        end
    end

    assign rdata = mem[rptr_bin[AW-1:0]];    // head of line, valid while !rempty

    always @(posedge rclk or posedge rreset) begin
        if (rreset) begin
            rptr_bin  <= {(AW+1){1'b0}};
            rptr_gray <= {(AW+1){1'b0}};
        end else if (rinc && !rempty) begin
            rptr_bin  <= rptr_bin + 1'b1;
            rptr_gray <= (rptr_bin + 1'b1) ^ (((rptr_bin + 1'b1) >> 1));
        end
    end

    always @(posedge wclk or posedge wreset) begin
        if (wreset) begin rptr_gray_w1 <= 0; rptr_gray_w2 <= 0; end
        else begin rptr_gray_w1 <= rptr_gray; rptr_gray_w2 <= rptr_gray_w1; end
    end

    always @(posedge rclk or posedge rreset) begin
        if (rreset) begin wptr_gray_r1 <= 0; wptr_gray_r2 <= 0; end
        else begin wptr_gray_r1 <= wptr_gray; wptr_gray_r2 <= wptr_gray_r1; end
    end

    always @(posedge wclk or posedge wreset)
        if (wreset) wfill <= 0;
        else        wfill <= wptr_bin - rptr_bin_w;

    always @(posedge rclk or posedge rreset)
        if (rreset) rfill <= 0;
        else        rfill <= wptr_bin_r - rptr_bin;
endmodule


// ---------------------------------------------------------------------------
// Transmitter. The local producer must hold s_valid/s_data until s_ready is high
// on the same cycle - s_ready only opens once per link period.
// clk_div is a runtime input, in local clocks per HALF link period, so the same
// build can be walked 2 MHz / 5 MHz / 10 MHz without re-synthesising: the plan
// asks for exactly that bring-up ladder.
// ---------------------------------------------------------------------------
module dc3_tx (
    input  wire       clk,
    input  wire       rst,
    input  wire [6:0] clk_div,             // half period in local clocks (>=2)
    input  wire [7:0] s_data,
    input  wire       s_valid,
    output wire       s_ready,
    input  wire       rx_ready,            // remote receiver's level, asynchronous
    output reg  [7:0] link_data,
    output reg        link_valid,
    output reg        link_clk
);
    reg [6:0] cnt;

    // link_clk is high while cnt is in [0, clk_div-1] and low while cnt is in
    // [clk_div, 2*clk_div-1]. It therefore falls on the edge into cnt==clk_div, and
    // that same edge is where a new byte is presented. The receiver samples on the
    // next rise, clk_div local cycles later - the half-period budget.
    //
    // Interface contract: clk_div must be held stable while the link is running.
    // Changing it mid-stream shortens the period under the counter and duplicates a
    // byte; bringing up 2 MHz -> 5 MHz -> 10 MHz the way the plan asks means idling
    // the link and pulsing rst across each step, which is what tb_dc3_link does.
    wire launch = (cnt == (clk_div - 1));
    wire [6:0] period_last = (clk_div * 2) - 1;
    wire wrap = (cnt >= period_last);      // ">=" so the counter self-heals after a reset

    always @(posedge clk or posedge rst)
        if (rst) cnt <= 0;
        else     cnt <= wrap ? 0 : cnt + 1'b1;

    always @(posedge clk or posedge rst)
        if (rst)                     link_clk <= 1'b1;
        else if (launch || wrap)     link_clk <= ~link_clk;
    // link_clk resets HIGH on purpose. The first toggle lands on the launch cycle, so
    // starting at 0 made that toggle a 0->1 rise and put a fresh byte on the wire at the
    // very instant the receiver samples - zero setup margin, and every capture one period
    // stale. Starting at 1 makes the launch a fall and the capture a rise half a period
    // later, which is the entire point of the phase convention.

    // The remote level is synchronised; the cost is latency, which the receiver's
    // RX_FREE_GUARANTEE already pays for.
    reg rdy_m1, rdy_sync;
    always @(posedge clk or posedge rst) begin
        if (rst) begin rdy_m1 <= 1'b0; rdy_sync <= 1'b0; end
        else     begin rdy_m1 <= rx_ready; rdy_sync <= rdy_m1; end
    end

    // Skid stage. Without it s_ready opens for exactly one local cycle per link
    // period, so a producer that is not phase-aligned to the launch instant silently
    // loses a whole period per byte and the link runs at half rate - measured 5.09
    // MB/s at the 10 MHz setting without it, which fails the plan's 6 MB/s number.
    reg       hold_valid;
    reg [7:0] hold_data;

    wire send = launch && rdy_sync;          // a byte leaves onto the link now
    wire take = s_ready && s_valid;          // a byte enters the skid now
    assign s_ready = !hold_valid || send;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            link_data  <= 8'h00;
            link_valid <= 1'b0;
            hold_valid <= 1'b0;
            hold_data  <= 8'h00;
        end else begin
            // link_valid is written ONLY on a launch cycle: it has to stay up for the
            // whole period after the byte was presented, because the receiver does not
            // look at it until the rising edge, half a period later. Clearing it on
            // idle cycles makes every capture miss.
            if (send) begin
                if (hold_valid || take) begin
                    link_valid <= 1'b1;
                    link_data  <= hold_valid ? hold_data : s_data;
                end else begin
                    link_valid <= 1'b0;
                end
            end
            if (take) hold_data <= s_data;
            hold_valid <= send ? take : (hold_valid || take);
        end
    end
endmodule


// ---------------------------------------------------------------------------
// Receiver. Captures on the rising edge of the forwarded clock and hands the
// bytes to the local domain through dc3_afifo8.
// ---------------------------------------------------------------------------
module dc3_rx #(
    parameter AW                = 10,      // 1024-byte FIFO
    parameter RX_FREE_GUARANTEE = 576,
    parameter LOW_WATER         = 128
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       link_clk,
    input  wire       link_valid,
    input  wire [7:0] link_data,
    output wire [7:0] m_data,
    output wire       m_valid,
    input  wire       m_ready,
    output reg        rx_ready,
    output wire       overflow
);
    localparam DEPTH      = (1 << AW);
    localparam HIGH_WATER = (DEPTH - RX_FREE_GUARANTEE);

    wire [7:0]  rdata;
    wire        wfull, rempty;
    wire [AW:0] wfill, rfill;
    wire        winc_l;

    // Sampled right on the rising edge, which is a half period after it was
    // launched, so no capture register of its own is needed.
    assign winc_l   = link_valid && !wfull;
    assign overflow = link_valid && wfull;

    dc3_afifo8 #(.AW(AW)) fifo (
        .wclk(link_clk), .wreset(rst),
        .winc(winc_l), .wdata(link_data),
        .rclk(clk), .rreset(rst),
        .rinc(m_valid && m_ready), .rdata(rdata),
        .wfull(wfull), .rempty(rempty),
        .wfill(wfill), .rfill(rfill)
    );

    assign m_data  = rdata;
    assign m_valid = !rempty;

    // Hysteresis. Drop READY only once the queue has grown to HIGH_WATER, which
    // still leaves RX_FREE_GUARANTEE slots free for whatever is in flight; bring
    // it back up once it has drained to LOW_WATER so the sender is not ping-ponged.
    always @(posedge clk or posedge rst) begin
        if (rst)                      rx_ready <= 1'b1;
        else if (rfill >= HIGH_WATER) rx_ready <= 1'b0;
        else if (rfill <= LOW_WATER)  rx_ready <= 1'b1;
    end
endmodule
