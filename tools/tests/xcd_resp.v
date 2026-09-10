`default_nettype none
//=============================================================================
// xcd_resp.v -- behaviorally-correct glyph_xcd (video side) responder model
//
//   Contract implemented from osd_banner.v header 3)/5c G_* FSM comments:
//     * req_v (1-cycle strobe, addr_v stable with it, busy_v==0) is accepted.
//     * busy_v=1 while the FLASH fetch runs (LAT cycles; real HW ~23us).
//     * new_v=1 for exactly ONE cycle; during that cycle out_v STILL HOLDS
//       the previous content (xcd updates out_v at the end edge of new_v),
//       and busy_v clears together with new_v.
//     * From the cycle AFTER new_v, out_v is stable with the fresh glyph:
//       [255:240]=row0(top) ... [15:0]=row15, bit15 = leftmost pixel.
//
//   Glyph content = deterministic non-degenerate hash of (addr, row) so every
//   code fetches a visually distinct, mostly-on 16x16 pattern.  flip_mask is
//   XOR-ed into the generated glyph (negative control: a 1-bit change on ONE
//   responder instance must break the golden/current pixel comparison).
//
//   One instance per DUT -- no shared request path, no arbitration needed.
//=============================================================================
module xcd_resp #(
    parameter integer LAT = 580              // busy cycles after accept (580 ~= 23us @25.175MHz)
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         req_v,
    input  wire [19:0]  addr_v,
    input  wire [255:0] flip_mask,           // XOR'd into every generated glyph
    output wire         busy_v,
    output wire         new_v,
    output reg  [255:0] out_v,
    output reg  [15:0]  done_cnt             // completed transactions (TB visibility)
);
    localparam [1:0] S_IDLE = 2'd0, S_BUSY = 2'd1, S_RDY = 2'd2;

    reg [1:0]   st;
    reg [19:0]  a_r;
    reg [15:0]  cnt;

    function [31:0] mix32;
        input [31:0] x0;
        reg [31:0] x;
        begin
            x = x0;
            x = x ^ (x >> 16); x = x * 32'h7FEB352D;
            x = x ^ (x >> 15); x = x * 32'h846CA68B;
            x = x ^ (x >> 16);
            mix32 = x;
        end
    endfunction

    function [15:0] hash_word;
        input [19:0] a;
        input [3:0]  r;
        reg [31:0] h;
        begin
            h = mix32(({12'd0, a} * 32'h01000193) ^ {28'd0, r} ^ 32'hC2CCABBA);
            if (h[15:0] == 16'd0) h = h ^ 32'h00005A5A;   // never an all-dark row
            hash_word = h[15:0];
        end
    endfunction

    function [255:0] gen_glyph;
        input [19:0] a;
        integer i;
        reg [255:0] g;
        begin
            g = 256'd0;
            for (i = 0; i < 16; i = i + 1)
                g[(15 - i)*16 +: 16] = hash_word(a, i[3:0]);  // row0 at [255:240]
            gen_glyph = g;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            a_r      <= 20'd0;
            cnt      <= 16'd0;
            out_v    <= 256'd0;
            done_cnt <= 16'd0;
        end else begin
            case (st)
                S_IDLE: if (req_v) begin
                            a_r <= addr_v;
                            cnt <= 16'd0;
                            st  <= S_BUSY;
                        end
                S_BUSY: if (cnt == LAT - 1) st <= S_RDY;
                        else                cnt <= cnt + 16'd1;
                S_RDY: begin
                            out_v    <= gen_glyph(a_r) ^ flip_mask;  // end edge of new_v cycle
                            done_cnt <= done_cnt + 16'd1;
                            st       <= S_IDLE;
                        end
                default: st <= S_IDLE;
            endcase
        end
    end

    assign busy_v = (st == S_BUSY);
    assign new_v  = (st == S_RDY);

endmodule

`default_nettype wire
