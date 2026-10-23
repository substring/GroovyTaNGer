// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - UDP TX arbiter (Phase 5 Milestone B, extended Rung 4a).
//
// Muxes the reply byte-streams (groovy_ack_sender, groovy_features,
// groovy_switchres) onto the vendored udp block's TX interface. udp TX model:
//   tx_data_rdy_i = ~ob_full   -> push payload via tx_data_av_i + tx_data_i;
//   tx_req_rdy_i  = ~ob_busy   -> after payload buffered, pulse tx_req_i to send.
// req_valid gates the send until the reply destination is captured (absorbs the
// header-capture vs command race). One reply at a time (commands are sequential);
// priority sr > features > ack > beacon if they ever coincide (the unsolicited raster
// beacon, groovy_beacon_sender, never delays a reply the host is waiting for).
//
// A reply's bytes are streamed only while udp.sv's generator is IDLE (tx_req_rdy).
// The vendor udp_generator counts every incoming byte into the length and checksum of
// the packet it is still framing (state 1, ~30 + length cycles after tx_req) and then
// zeroes that count: bytes that arrive in that window corrupt the packet being framed
// and leave the TX FIFOs misaligned for good - garbage frames, then no TX at all
// (HW 2026-10-23: replies stopped a few hundred ms into a stream once an ACK and a
// raster beacon, or two status replies, followed each other closely). Its busy is a
// register that rises the cycle after tx_req, hence the two-cycle S_HOLD.
`default_nettype none

module groovy_tx_arbiter (
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] req_ip,
    input  wire [15:0] req_port,
    input  wire [15:0] our_port,
    input  wire        req_valid,

    // ACK sender
    input  wire        ack_valid, input wire [7:0] ack_data, input wire ack_last,
    output wire        ack_ready,
    // FEATURES sender
    input  wire        ft_valid,  input wire [7:0] ft_data,  input wire ft_last,
    output wire        ft_ready,
    // SWITCHRES-result sender
    input  wire        sr_valid,  input wire [7:0] sr_data,  input wire sr_last,
    output wire        sr_ready,
    // raster beacon sender (tie bc_valid to 0 where unused)
    input  wire        bc_valid,  input wire [7:0] bc_data,  input wire bc_last,
    output wire        bc_ready,

    // to udp block TX
    output wire [31:0] tx_ip,
    output wire [15:0] tx_src_port,
    output wire [15:0] tx_dst_port,
    output wire [7:0]  tx_data,
    output wire        tx_data_av,
    output reg         tx_req,
    input  wire        tx_req_rdy,
    input  wire        tx_data_rdy
);
    localparam [1:0] S_IDLE = 2'd0, S_STREAM = 2'd1, S_REQ = 2'd2, S_HOLD = 2'd3;
    localparam [1:0] SEL_ACK = 2'd0, SEL_FT = 2'd1, SEL_SR = 2'd2, SEL_BC = 2'd3;
    reg [1:0] state;
    reg [1:0] sel;
    reg       hold2;                    // second S_HOLD cycle

    wire        s_valid = (sel == SEL_SR) ? sr_valid : (sel == SEL_FT) ? ft_valid :
                          (sel == SEL_BC) ? bc_valid : ack_valid;
    wire [7:0]  s_data  = (sel == SEL_SR) ? sr_data  : (sel == SEL_FT) ? ft_data  :
                          (sel == SEL_BC) ? bc_data  : ack_data;
    wire        s_last  = (sel == SEL_SR) ? sr_last  : (sel == SEL_FT) ? ft_last  :
                          (sel == SEL_BC) ? bc_last  : ack_last;

    wire byte_xfer = (state == S_STREAM) && s_valid && tx_data_rdy;

    assign tx_data     = s_data;
    assign tx_data_av  = byte_xfer;
    assign sr_ready    = (state == S_STREAM) && (sel == SEL_SR) && tx_data_rdy;
    assign ft_ready    = (state == S_STREAM) && (sel == SEL_FT) && tx_data_rdy;
    assign ack_ready   = (state == S_STREAM) && (sel == SEL_ACK) && tx_data_rdy;
    assign bc_ready    = (state == S_STREAM) && (sel == SEL_BC) && tx_data_rdy;

    assign tx_ip       = req_ip;
    assign tx_src_port = our_port;
    assign tx_dst_port = req_port;

    always @(posedge clk) begin
        tx_req <= 1'b0;
        if (rst) begin
            state <= S_IDLE; sel <= SEL_ACK; hold2 <= 1'b0;
        end else begin
            case (state)
                S_IDLE: if (tx_req_rdy) begin             // generator idle: safe to stream
                    if (sr_valid)       begin sel <= SEL_SR;  state <= S_STREAM; end
                    else if (ft_valid)  begin sel <= SEL_FT;  state <= S_STREAM; end
                    else if (ack_valid) begin sel <= SEL_ACK; state <= S_STREAM; end
                    else if (bc_valid)  begin sel <= SEL_BC;  state <= S_STREAM; end
                end
                S_STREAM: if (byte_xfer && s_last) state <= S_REQ;
                S_REQ: if (tx_req_rdy && req_valid) begin tx_req <= 1'b1; state <= S_HOLD; hold2 <= 1'b0; end
                S_HOLD: begin                                 // let the generator's busy rise
                    hold2 <= 1'b1;
                    if (hold2) state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
