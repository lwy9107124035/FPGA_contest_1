// dc3_pack.v - layer 2 of the DC3 link: packet framing, CRC32 and session check.
// Sits on dc3_tx / dc3_rx (layer 1) and adds the header, the integrity trailer and the
// staleness rule from plan V3 sec 4.3.
//
// Wire format, one packet:
//   0        SYNC      8'hDC
//   1        VERSION   8'h01
//   2        TYPE
//   3        SESSION   new value per re-link; a mismatch is dropped as stale so an old
//                      result or key press can never take effect after a reconnect
//   4        TASK
//   5..6     SEQ       16-bit chunk index or PCM sample number, big endian
//   7..8     LEN       16-bit payload length, big endian
//   9..      payload
//   last 4   CRC32, big endian, over SYNC .. last payload byte
//
// CRC32 everywhere rather than CRC16-for-control: the plan says control "may" use CRC16,
// and two extra bytes per control packet is cheaper than carrying a second algorithm plus
// a "which one applies" failure mode through review.
//
// WHY THE BYTE SOURCE IS COMBINATIONAL. An earlier version registered s_data and advanced
// an index in the same clock. Reading a register in the cycle it is written then became a
// standing trap, and it bit three separate times: the header replayed SYNC and dropped
// VERSION, the trailer was emitted from a CRC that had not folded the last byte, and the
// payload re-sent a byte the caller believed consumed. Presenting the current byte through
// a mux and moving the FSM only on `take` removes that whole class instead of patching
// each instance of it.
//
// DELIVERY CONTRACT. Payload bytes reach the consumer before the trailing CRC has been
// seen; that is deliberate, because staging a whole 512-byte block to verify it first
// would cost a BRAM per direction on a device that has none free. The consumer therefore
// accepts into a staging area and commits only on m_eof with m_err == E_OK. This is the
// plan's own ACCEPTED / APPLIED split.

`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// Packetiser. The caller raises p_start for one cycle - at any time, even while a
// previous packet is still leaving - then holds p_valid/p_data stable until p_ready
// is high on the same cycle.
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
    output wire [7:0]  s_data,
    output wire        s_valid,
    input  wire        s_ready,
    output reg  [7:0]  err_short        // sticky per packet: source under-delivered
);
    localparam ST_IDLE = 3'd0, ST_HDR = 3'd1, ST_PAY = 3'd2, ST_CRC = 3'd3;
    localparam [7:0] DC3_SYNC    = 8'hDC;
    localparam [7:0] DC3_VERSION = 8'h01;
    localparam integer HDRN      = 9;

    reg [2:0]  state;
    reg [3:0]  hidx;
    reg [15:0] pidx, len_r;
    reg [7:0]  hdr [0:HDRN-1];
    reg [31:0] crc_q;
    reg [1:0]  cidx;

    // a start request arriving while a packet is still in flight is queued, not dropped
    reg        start_pending;
    reg [7:0]  sq_type, sq_session, sq_task;
    reg [15:0] sq_seq, sq_len;

    wire [15:0] use_seq = start_pending ? sq_seq : p_seq;
    wire [15:0] use_len = start_pending ? sq_len : p_len;

    // ---- combinational byte source ----
    // hdr[0] and hdr[1] are constants of the format, so they are not stored either.
    wire [7:0] hdr_byte = (hidx == 4'd0) ? DC3_SYNC    :
                          (hidx == 4'd1) ? DC3_VERSION : hdr[hidx];

    wire [7:0] crc_byte = crc_q[(3 - cidx)*8 +: 8];

    assign s_data  = (state == ST_HDR) ? hdr_byte :
                     (state == ST_PAY) ? p_data   :
                     (state == ST_CRC) ? crc_byte : 8'h00;

    // during the payload phase there is only a byte to send when the caller holds one
    assign s_valid = (state == ST_HDR) || (state == ST_CRC) ||
                     ((state == ST_PAY) && p_valid);

    wire take = s_valid && s_ready;

    // the caller's byte is consumed on exactly this cycle
    assign p_ready = (state == ST_PAY) && s_ready;

    // ---- CRC over the byte being consumed right now ----
    // Seeded on the first byte of the packet, so SYNC is folded exactly once and crc_q is
    // complete at the moment the last payload byte is taken - which is why the trailer can
    // simply be read out of crc_q.
    integer ci;
    reg [31:0] cx;
    reg [31:0] crc_nxt;
    always @* begin
        cx = (state == ST_HDR && hidx == 4'd0) ? 32'hFFFF_FFFF : crc_q;
        for (ci = 0; ci < 8; ci = ci + 1)
            cx = (cx >> 1) ^ (32'hEDB88320 & {32{cx[0] ^ s_data[ci]}});
        crc_nxt = cx;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ST_IDLE; hidx <= 4'd0; pidx <= 16'd0; len_r <= 16'd0;
            crc_q <= 32'hFFFF_FFFF; cidx <= 2'd0; err_short <= 8'h00;
            start_pending <= 1'b0;
        end else begin
            if (p_start && (state != ST_IDLE)) begin
                start_pending <= 1'b1;
                sq_type <= p_type; sq_session <= p_session; sq_task <= p_task;
                sq_seq  <= p_seq;  sq_len    <= p_len;
            end

            case (state)
                ST_IDLE: if (p_start || start_pending) begin
                    hdr[2] <= start_pending ? sq_type    : p_type;
                    hdr[3] <= start_pending ? sq_session : p_session;
                    hdr[4] <= start_pending ? sq_task    : p_task;
                    hdr[5] <= use_seq[15:8];
                    hdr[6] <= use_seq[7:0];
                    hdr[7] <= use_len[15:8];
                    hdr[8] <= use_len[7:0];
                    len_r  <= use_len;
                    hidx   <= 4'd0;
                    pidx   <= 16'd0;
                    cidx   <= 2'd0;
                    crc_q  <= 32'hFFFF_FFFF;
                    err_short     <= 8'h00;
                    start_pending <= 1'b0;
                    state         <= ST_HDR;
                end

                ST_HDR: if (take) begin
                    crc_q <= crc_nxt;
                    if (hidx == HDRN - 1) state <= (len_r == 16'd0) ? ST_CRC : ST_PAY;
                    else                  hidx <= hidx + 4'd1;
                end

                ST_PAY: if (take) begin
                    crc_q <= crc_nxt;
                    if (pidx == (len_r - 16'd1)) state <= ST_CRC;
                    else                         pidx <= pidx + 16'd1;
                end else if (!p_valid && (pidx < len_r)) begin
                    err_short <= 8'h01;        // sticky: the source broke its promise
                end

                ST_CRC: if (take) begin
                    if (cidx == 2'd3) begin
                        cidx  <= 2'd0;
                        state <= ST_IDLE;
                    end else
                        cidx <= cidx + 2'd1;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule


// ---------------------------------------------------------------------------
// Depacketiser. Anything it cannot trust is dropped, and the remainder of that packet
// is drained so the next one stays aligned.
// ---------------------------------------------------------------------------
module dc3_pkt_rx (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  s_data,
    input  wire        s_valid,
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
    localparam ST_DRAIN = 3'd4;
    localparam E_OK = 3'd0, E_CRC = 3'd1, E_VER = 3'd2, E_STALE = 3'd3, E_OVF = 3'd4;
    localparam [7:0] DC3_SYNC    = 8'hDC;
    localparam [7:0] DC3_VERSION = 8'h01;
    localparam integer HDRN      = 9;

    reg [2:0]  state;
    reg [3:0]  hidx;
    reg [15:0] pidx, len_r, drain_n;
    reg [7:0]  hdr [0:HDRN-1];
    reg [31:0] crc_q, rx_crc;
    reg [1:0]  cidx;
    reg        pay_lost;

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

    // CRC32 of one byte from the 0xFFFFFFFF seed, so the intent is readable instead of
    // a magic constant sitting in the FSM.
    function [31:0] crc_seed;
        input [7:0] b;
        integer k;
        reg [31:0] c;
        begin
            c = 32'hFFFF_FFFF;
            for (k = 0; k < 8; k = k + 1)
                c = (c >> 1) ^ (32'hEDB88320 & {32{c[0] ^ b[k]}});
            crc_seed = c;
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ST_HUNT; hidx <= 4'd0; pidx <= 16'd0; len_r <= 16'd0;
            crc_q <= 32'hFFFF_FFFF; rx_crc <= 32'h0; cidx <= 2'd0;
            m_sof <= 1'b0; m_eof <= 1'b0; m_err <= E_OK; pay_lost <= 1'b0;
            drain_n <= 16'd0;
            m_type <= 8'h00; m_task <= 8'h00; m_seq <= 16'd0; m_len <= 16'd0;
            cnt_ok <= 16'd0; cnt_crc <= 16'd0; cnt_stale <= 16'd0; cnt_resync <= 16'd0;
        end else begin
            m_sof <= 1'b0;
            m_eof <= 1'b0;

            case (state)
                ST_HUNT: if (s_valid && (s_data == DC3_SYNC)) begin
                    crc_q  <= crc_seed(DC3_SYNC);
                    hdr[0] <= DC3_SYNC;
                    hidx   <= 4'd1;
                    state  <= ST_HDR;
                end

                ST_HDR: if (s_valid) begin
                    hdr[hidx] <= s_data;
                    crc_q     <= crc_nxt;
                    if (hidx == HDRN - 1) begin
                        // s_data IS hdr[8] this cycle; reading hdr[8] would return the
                        // value from before this cycle's write, i.e. X on the first packet
                        if (hdr[1] !== DC3_VERSION) begin
                            m_err      <= E_VER;
                            cnt_resync <= cnt_resync + 1'b1;
                            drain_n    <= {hdr[7], s_data} + 16'd4;
                            state      <= ({hdr[7], s_data} == 16'd0) ? ST_HUNT : ST_DRAIN;
                        end else if (hdr[3] !== expect_session) begin
                            m_err     <= E_STALE;
                            cnt_stale <= cnt_stale + 1'b1;
                            drain_n   <= {hdr[7], s_data} + 16'd4;
                            state     <= ({hdr[7], s_data} == 16'd0) ? ST_HUNT : ST_DRAIN;
                        end else begin
                            m_type <= hdr[2];
                            m_task <= hdr[4];
                            m_seq  <= {hdr[5], hdr[6]};
                            m_len  <= {hdr[7], s_data};
                            len_r  <= {hdr[7], s_data};
                            pidx   <= 16'd0;
                            cidx   <= 2'd0;
                            rx_crc <= 32'h0;
                            state  <= ({hdr[7], s_data} == 16'd0) ? ST_CRC : ST_PAY;
                        end
                    end else
                        hidx <= hidx + 4'd1;
                end

                ST_PAY: if (s_valid) begin
                    if (m_ready) begin
                        crc_q <= crc_nxt;
                        if (pidx == 16'd0) m_sof <= 1'b1;
                        if (pidx == (len_r - 16'd1)) state <= ST_CRC;
                        else                          pidx <= pidx + 16'd1;
                    end else
                        pay_lost <= 1'b1;     // a byte was dropped: block is incomplete
                end

                ST_CRC: if (s_valid) begin
                    rx_crc <= {rx_crc[23:0], s_data};
                    if (cidx == 2'd3) begin
                        m_eof <= 1'b1;
                        if (pay_lost) begin
                            m_err <= E_OVF;  cnt_resync <= cnt_resync + 1'b1;
                        end else if ({rx_crc[23:0], s_data} === crc_q) begin
                            m_err <= E_OK;   cnt_ok     <= cnt_ok + 1'b1;
                        end else begin
                            m_err <= E_CRC;  cnt_crc    <= cnt_crc + 1'b1;
                        end
                        pay_lost <= 1'b0;
                        state    <= ST_HUNT;
                    end else
                        cidx <= cidx + 2'd1;
                end

                // A packet rejected at the header still has its payload and trailer on
                // the way. Going straight back to HUNT let a trailer byte equal to 0xDC
                // false-sync and eat the NEXT packet's header - that was P3's failure.
                ST_DRAIN: if (s_valid) begin
                    if (drain_n <= 16'd1) state <= ST_HUNT;
                    else                  drain_n <= drain_n - 16'd1;
                end

                default: state <= ST_HUNT;
            endcase
        end
    end
endmodule
