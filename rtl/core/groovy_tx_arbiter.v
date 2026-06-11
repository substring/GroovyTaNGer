// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - UDP TX arbiter (Phase 5 Milestone B).
//
// Muxes the two reply byte-streams (groovy_ack_sender, groovy_features) onto the
// vendored udp block's TX interface. The udp TX model (confirmed in udp.sv):
//   tx_data_rdy_i = ~ob_full   -> assert tx_data_av_i + tx_data_i while ready to
//                                 push payload bytes into the output buffer;
//   tx_req_rdy_i  = ~ob_busy   -> after the payload is buffered, pulse tx_req_i
//                                 to send it to {tx_ip, tx_src_port, tx_dst_port}.
//
// One reply at a time (commands are sequential). FEATURES has priority over ACK
// if both ever present simultaneously (they don't in normal use).
`default_nettype none

module groovy_tx_arbiter (
    input  wire        clk,
    input  wire        rst,

    // reply destination (captured from the request's IP header)
    input  wire [31:0] req_ip,
    input  wire [15:0] req_port,
    input  wire [15:0] our_port,
    input  wire        req_valid,   // 1 = req_ip/req_port are captured & usable;
                                    // gates the send so we never transmit to 0.0.0.0
                                    // and absorbs the header-capture vs command race

    // ACK sender stream (groovy_ack_sender)
    input  wire        ack_valid,
    input  wire [7:0]  ack_data,
    input  wire        ack_last,
    output wire        ack_ready,

    // FEATURES sender stream (groovy_features)
    input  wire        ft_valid,
    input  wire [7:0]  ft_data,
    input  wire        ft_last,
    output wire        ft_ready,

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
    localparam [1:0] S_IDLE = 2'd0, S_STREAM = 2'd1, S_REQ = 2'd2;
    reg [1:0] state;
    reg       sel_ft;        // 1 = FEATURES, 0 = ACK

    wire        s_valid = sel_ft ? ft_valid : ack_valid;
    wire [7:0]  s_data  = sel_ft ? ft_data  : ack_data;
    wire        s_last  = sel_ft ? ft_last  : ack_last;

    // accept a byte only when the udp output buffer can take it
    wire byte_xfer = (state == S_STREAM) && s_valid && tx_data_rdy;

    assign tx_data     = s_data;
    assign tx_data_av  = byte_xfer;
    assign ft_ready    = (state == S_STREAM) &&  sel_ft && tx_data_rdy;
    assign ack_ready   = (state == S_STREAM) && !sel_ft && tx_data_rdy;

    assign tx_ip       = req_ip;
    assign tx_src_port = our_port;
    assign tx_dst_port = req_port;

    always @(posedge clk) begin
        tx_req <= 1'b0;
        if (rst) begin
            state  <= S_IDLE;
            sel_ft <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (ft_valid)       begin sel_ft <= 1'b1; state <= S_STREAM; end
                    else if (ack_valid) begin sel_ft <= 1'b0; state <= S_STREAM; end
                end
                S_STREAM: begin
                    // last payload byte accepted -> go request the send
                    if (byte_xfer && s_last) state <= S_REQ;
                end
                S_REQ: begin
                    // payload is already buffered in the udp output FIFO; hold
                    // here until the destination address is valid, then send.
                    if (tx_req_rdy && req_valid) begin
                        tx_req <= 1'b1;     // 1-cycle send pulse
                        state  <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
