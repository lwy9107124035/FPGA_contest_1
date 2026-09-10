`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// uart_rx.v — minimal UART receiver, single clock domain (video_clk 25.175MHz).
// 115200-8N1, direct-rate sampling (DIV = CLK/BAUD = 218), sample at bit centre.
// Falls back safe: line idle-high, false-start rejection, stop-bit validation.
// -----------------------------------------------------------------------------
module uart_rx #(
    parameter CLK_HZ = 25175000,
    parameter BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,          // pre-synchronised RX line (high when idle)
    output reg [7:0]  byte_o,
    output reg        byte_vld     // 1-clk pulse
);
    localparam [15:0] DIV = CLK_HZ / BAUD;   // 218

    reg [1:0]  st;
    reg [15:0] cnt;
    reg [3:0]  nbits;
    reg [7:0]  sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 2'd0; byte_vld <= 1'b0; nbits <= 4'd0; sh <= 8'd0;
        end else begin
            byte_vld <= 1'b0;
            case (st)
                2'd0: if (!rx) begin                      // start-bit falling edge
                          cnt <= DIV >> 1;                // to start-bit centre
                          st  <= 2'd1;
                      end
                2'd1: if (cnt == 16'd0) begin
                          if (rx) st <= 2'd0;             // glitch: abort
                          else begin cnt <= DIV - 1'b1; nbits <= 4'd0; st <= 2'd2; end
                      end else cnt <= cnt - 16'd1;
                2'd2: if (cnt == 16'd0) begin
                          cnt <= DIV - 1'b1;
                          sh  <= {rx, sh[7:1]};           // LSB first
                          if (nbits == 4'd7) begin
                              cnt <= DIV >> 1;            // to stop-bit centre
                              st  <= 2'd3;
                          end else nbits <= nbits + 4'd1;
                      end else cnt <= cnt - 16'd1;
                2'd3: if (cnt == 16'd0) begin
                          if (rx) begin byte_o <= sh; byte_vld <= 1'b1; end
                          st <= 2'd0;
                      end else cnt <= cnt - 16'd1;
                default: st <= 2'd0;
            endcase
        end
    end
endmodule
