`timescale 1 ns / 1 ps
// =============================================================================
// uart_tx.v — minimal UART transmitter 115200-8N1 in video_clk domain.
// start = 1-clk pulse accepted when idle. busy high during the frame.
// done pulses at stop-bit end. Line idles high.
// =============================================================================
module uart_tx #(
    parameter CLK_HZ = 25175000,
    parameter BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] byte_i,
    output reg        busy,
    output reg        done,
    output reg        tx_pad
);
    localparam [15:0] DIV = CLK_HZ / BAUD;   // 218

    reg [1:0]  st;
    reg [15:0] cnt;
    reg [3:0]  n;
    reg [7:0]  sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 2'd0; busy <= 1'b0; done <= 1'b0; tx_pad <= 1'b1;
            n <= 4'd0; cnt <= 16'd0; sh <= 8'd0;
        end else begin
            done <= 1'b0;
            case (st)
                2'd0: begin
                    tx_pad <= 1'b1;
                    if (start) begin
                        sh     <= byte_i;
                        tx_pad <= 1'b0;          // start bit
                        cnt    <= DIV - 1'b1;
                        busy   <= 1'b1;
                        st     <= 2'd1;
                    end
                end
                2'd1: begin                       // load first data bit after start centre
                    if (cnt == 16'd0) begin
                        tx_pad <= sh[0];
                        sh     <= {1'b0, sh[7:1]};
                        n      <= 4'd0;
                        cnt    <= DIV - 1'b1;
                        st     <= 2'd2;
                    end else cnt <= cnt - 16'd1;
                end
                2'd2: begin
                    if (cnt == 16'd0) begin
                        cnt <= DIV - 1'b1;
                        if (n == 4'd7) begin
                            tx_pad <= 1'b1;      // stop bit
                            st     <= 2'd3;
                        end else begin
                            tx_pad <= sh[0];
                            sh     <= {1'b0, sh[7:1]};
                            n      <= n + 4'd1;
                        end
                    end else cnt <= cnt - 16'd1;
                end
                2'd3: begin
                    if (cnt == 16'd0) begin
                        done <= 1'b1; busy <= 1'b0; st <= 2'd0;
                    end else cnt <= cnt - 16'd1;
                end
                default: st <= 2'd0;
            endcase
        end
    end
endmodule
