// dc3_pack.v - layer 2 of the DC3 link: packet framing, CRC32, session check.
// Sits on dc3_tx / dc3_rx (layer 1) and adds the header, the integrity trailer and the
// staleness rule the plan asks for (V3 sec 4.3).
//
// Wire format, one packet:
//   0        SYNC      8'hDC
//   1        VERSION   8'h01
//   2        TYPE      message type
//   3        SESSION   new value on every re-link; a packet whose session does not match
//                      the receiver's is dropped as stale, which is what stops an old
//                      result or an old key press from taking effect after a reconnect
//   4        TASK      task id, so several images/streams can be in flight
//   5..6     SEQ       16-bit chunk index, or PCM sample number
//   7..8     LEN       16-bit payload length, big endian
//   9..      payload
//   last 4   CRC32, big endian, over SYNC .. last payload byte
//
// CRC32 everywhere rather than CRC16-for-control: the plan says control "may" use CRC16,
// and two extra bytes on a control packet is cheaper than carrying a second algorithm and
// a "which one applies" failure mode through review.
//
// DELIVERY CONTRACT, and it matters: payload bytes are streamed to the consumer as they
// arrive, before the CRC at the end of the packet has been seen. That is deliberate -
// buffering a whole 512-byte block to validate it first would cost a BRAM per direction on
// a device that has none free. The consumer therefore accepts the block into a staging
// area and only commits it when m_eof arrives with m_err == E_OK. This is the plan's own
// ACCEPTED / APPLIED split, not a shortcut.

`timescale 1ns/1ps

// DC3_SYNC / DC3_VERSION / DC3_HDR_BYTES are declared inside each module: a file-scope
// localparam is SystemVerilog, and this tree has to stay -g2005 clean for TD.

// ---------------------------------------------------------------------------
// Packetiser. One packet at a time: pulse p_start, then feed exactly p_len
// payload bytes, holding p_valid until p_ready.
// ---------------------------------------------------------------------------
module dc3_pkt_tx (
    input  wire        clk,
    input  wire        rst,
    input  wire        p_start,
    input  wire [7:0]  p_type,
    input  wire [7:0]  p_session,
    input  wire [7:0]  p_task,
    input  wire [15:0] p_seq,
    input  wire [15:0] p_len,
    input  wire [7:0]  p_data,
    input  wire        p_valid,
    output wire        p_ready,
    output reg  [7:0]  s_data,
    output reg         s_valid,
    input  wire        s_ready,
    output reg  [7:0]  err_short       // source promised more than it delivered
);
    localparam ST_IDLE = 3'd0, ST_HDR = 3'd1, ST_PAY = 3'd2, ST_CRC = 3'd3;
    localparam [7:0] DC3_SYNC = 8'hDC;
    localparam [7:0] DC3_VERSION = 8'h01;
    localparam integer DC3_HDR_BYTES = 9;

    reg [2:0]   state;
    reg [3:0]   hidx;
    reg [15:0]  pidx, len_r;
    reg [7:0]   hdr [0:DC3_HDR_BYTES-1];
    reg [31:0]  crc_q;
    reg [1:0]   cidx;

    wire take       = s_valid && s_ready;
    wire first_byte = (state == ST_HDR) && (hidx == 4'd0);

    // CRC of the byte leaving this cycle, computed combinationally so it is already
    // accumulated by the time the next byte goes out.
    integer ci;
    reg [31:0] cx;
    reg [31:0] crc_nxt;
    always @* begin
        cx = first_byte ? 32'hFFFF_FFFF : crc_q;
        for (ci = 0; ci < 8; ci = ci + 1)
            cx = (cx >> 1) ^ (32'hEDB88320 & {32{cx[0] ^ s_data[ci]}});
        crc_nxt = cx;
    end

    assign p_ready = (state == ST_PAY);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ST_IDLE; s_valid <= 1'b0; s_data <= 8'h00;
            hidx <= 4'd0; pidx <= 16'd0; len_r <= 16'd0;
            crc_q <= 32'hFFFF_FFFF; cidx <= 2'd0; err_short <= 8'h00;
        end else begin
            case (state)
                // On entry present hdr[0]; from then on a byte is only replaced by the
                // next one at the moment it is taken. Re-loading s_data from hdr[hidx]
                // every cycle while also advancing hidx put the old index back on the
                // wire one cycle later, which duplicated SYNC and dropped VERSION.
                ST_IDLE: if (p_start) begin
                    hdr[0] <= DC3_SYNC;
                    hdr[1] <= DC3_VERSION;
                    hdr[2] <= p_type;
                    hdr[3] <= p_session;
                    hdr[4] <= p_task;
                    hdr[5] <= p_seq[15:8];
                    hdr[6] <= p_seq[7:0];
                    hdr[7] <= p_len[15:8];
                    hdr[8] <= p_len[7:0];
                    len_r <= p_len;
                    hidx  <= 4'd0;
                    pidx  <= 16'd0;
                    err_short <= 8'h00;
                    s_data  <= DC3_SYNC;
                    s_valid <= 1'b1;
                    state   <= ST_HDR;
                end

                ST_HDR: if (take) begin
                    crc_q <= crc_nxt;
                    if (hidx == DC3_HDR_BYTES - 1) begin
                        if (len_r == 16'd0) begin
                            s_valid <= 1'b1;             // first CRC byte goes out now
                            s_data  <= crc_q[31:24];
                            state   <= ST_CRC;
                        end else begin
                            s_valid <= 1'b0;
                            state   <= ST_PAY;
                        end
                    end else begin
                        hidx   <= hidx + 4'd1;
                        s_data <= hdr[hidx + 4'd1];
                    end
                end

                ST_PAY: if (p_valid) begin
                    s_valid <= 1'b1;
                    if (!take) s_data <= p_data;
                    if (take) begin
                        crc_q <= crc_nxt;
                        if (pidx == (len_r - 16'd1)) begin
                            s_valid <= 1'b1;             // first CRC byte goes out now
                            s_data  <= crc_q[31:24];
                            state   <= ST_CRC;
                        end else
                            pidx <= pidx + 16'd1;
                    end
                end else begin
                    s_valid <= 1'b0;
                    // sticky per packet, not per cycle: the counter answers "did a
                    // source promise bytes it never delivered", and counting cycles
                    // made it meaningless
                    if (pidx < len_r) err_short <= 8'h01;
                end

                ST_CRC: if (take) begin
                    if (cidx == 2'd3) begin
                        s_valid <= 1'b0;
                        cidx    <= 2'd0;
                        state   <= ST_IDLE;
                    end else begin
                        cidx   <= cidx + 2'd1;
                        s_data <= crc_q[(2-cidx)*8 +: 8];  // big endian on the wire
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule


// ---------------------------------------------------------------------------
// Depacketiser. Anything it cannot trust is dropped and it re-hunts for the next
// SYNC, so one corrupted byte costs one packet rather than the rest of the stream.
// ---------------------------------------------------------------------------
module dc3_pkt_rx (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  s_data,
    input  wire        s_valid,
    // packet out - see the delivery contract at the top of this file
    output wire [7:0]  m_data,
    output wire        m_valid,
    input  wire        m_ready,
    output reg  [7:0]  m_type,
    output reg  [7:0]  m_task,
    output reg  [15:0] m_seq,
    output reg  [15:0] m_len,
    output reg         m_sof,
    output reg         m_eof,
    output reg  [2:0]  m_err,
    input  wire [7:0]  expect_session,
    output reg  [15:0] cnt_ok,
    output reg  [15:0] cnt_crc,
    output reg  [15:0] cnt_stale,
    output reg  [15:0] cnt_resync
);
    localparam ST_HUNT = 3'd0, ST_HDR = 3'd1, ST_PAY = 3'd2, ST_CRC = 3'd3;
    localparam E_OK = 3'd0, E_CRC = 3'd1, E_VER = 3'd2, E_STALE = 3'd3, E_OVF = 3'd4;
    localparam [7:0] DC3_SYNC = 8'hDC;
    localparam [7:0] DC3_VERSION = 8'h01;
    localparam integer DC3_HDR_BYTES = 9;

    reg [2:0]  state;
    reg [3:0]  hidx;
    reg [15:0] pidx, len_r;
    reg [7:0]  hdr [0:DC3_HDR_BYTES-1];
    reg [31:0] crc_q;
    reg [31:0] rx_crc;
    reg [1:0]  cidx;
    reg        pay_lost;                  // a payload byte arrived while !m_ready

    assign m_valid = (state == ST_PAY) && s_valid;
    assign m_data  = s_data;

    integer ci;
    reg [31:0] cx;
    reg [31:0] crc_nxt;
    always @* begin
        cx = crc_q;
        for (ci = 0; ci < 8; ci = ci + 1)
            cx = (cx >> 1) ^ (32'hEDB88320 & {32{cx[0] ^ s_data[ci]}});
        crc_nxt = cx;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ST_HUNT; m_sof <= 1'b0; m_eof <= 1'b0; m_err <= E_OK;
            hidx <= 4'd0; pidx <= 16'd0; len_r <= 16'd0;
            crc_q <= 32'hFFFF_FFFF; rx_crc <= 32'h0; cidx <= 2'd0; pay_lost <= 1'b0;
            m_type <= 8'h00; m_task <= 8'h00; m_seq <= 16'd0; m_len <= 16'd0;
            cnt_ok <= 16'd0; cnt_crc <= 16'd0; cnt_stale <= 16'd0; cnt_resync <= 16'd0;
        end else begin
            m_sof <= 1'b0;
            m_eof <= 1'b0;

            case (state)
                ST_HUNT: if (s_valid && (s_data == DC3_SYNC)) begin
                    // store the SYNC in hdr[0] as well, so every index below matches
                    // the wire layout one-for-one. Skipping it was the bug: hdr[1]
                    // then held TYPE instead of VERSION and every packet was rejected
                    // as a version error.
                    hdr[0]  <= DC3_SYNC;
                    crc_q   <= crc_seed_byte(DC3_SYNC);
                    hidx    <= 4'd1;
                    pay_lost<= 1'b0;
                    state   <= ST_HDR;
                end

                ST_HDR: if (s_valid) begin
                    hdr[hidx] <= s_data;
                    crc_q     <= crc_nxt;
                    if (hidx == DC3_HDR_BYTES - 1) begin
                        if (hdr[1] !== DC3_VERSION) begin
                            m_err <= E_VER; cnt_resync <= cnt_resync + 1'b1;
                            state <= ST_HUNT;
                        end else if (hdr[3] !== expect_session) begin
                            m_err <= E_STALE; cnt_stale <= cnt_stale + 1'b1;
                            state <= ST_HUNT;
                        end else begin
                            m_type <= hdr[2];
                            m_task <= hdr[4];
                            m_seq  <= {hdr[5], hdr[6]};
                            m_len  <= {hdr[7], hdr[8]};
                            len_r  <= {hdr[7], hdr[8]};
                            pidx   <= 16'd0;
                            state  <= ({hdr[7], hdr[8]} == 16'd0) ? ST_CRC : ST_PAY;
                            if ({hdr[7], hdr[8]} == 16'd0) cidx <= 2'd0;
                        end
                    end else
                        hidx <= hidx + 4'd1;
                end

                ST_PAY: if (s_valid) begin
                    if (m_ready) begin
                        crc_q <= crc_nxt;
                        if (pidx == 16'd0) m_sof <= 1'b1;
                        if (pidx == (len_r - 16'd1)) begin
                            cidx  <= 2'd0;
                            state <= ST_CRC;
                        end else
                            pidx <= pidx + 16'd1;
                    end else begin
                        // the consumer could not take it: the block is now incomplete,
                        // so mark it and let the CRC stage finish the bookkeeping
                        pay_lost <= 1'b1;
                    end
                end

                ST_CRC: if (s_valid) begin
                    rx_crc <= {rx_crc[23:0], s_data};
                    if (cidx == 2'd3) begin
                        m_eof <= 1'b1;
                        if (pay_lost) begin
                            m_err <= E_OVF; cnt_resync <= cnt_resync + 1'b1;
                        end else if ({rx_crc[23:0], s_data} === crc_q) begin
                            m_err <= E_OK; cnt_ok <= cnt_ok + 1'b1;
                        end else begin
                            m_err <= E_CRC; cnt_crc <= cnt_crc + 1'b1;
                        end
                        pay_lost <= 1'b0;
                        state    <= ST_HUNT;
                    end else
                        cidx <= cidx + 2'd1;
                end

                default: state <= ST_HUNT;
            endcase
        end
    end

    // CRC32 of one byte starting from 0xFFFFFFFF. Written as a function so the intent
    // is readable instead of a magic constant sitting in the FSM. Verilog needs at
    // least one input on a function, so the byte is passed in even though today the
    // only caller ever passes DC3_SYNC.
    function [31:0] crc_seed_byte;
        input [7:0] b;
        integer k;
        reg [31:0] c;
        begin
            c = 32'hFFFF_FFFF;
            for (k = 0; k < 8; k = k + 1)
                c = (c >> 1) ^ (32'hEDB88320 & {32{c[0] ^ b[k]}});
            crc_seed_byte = c;
        end
    endfunction
endmodule
