// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - UDP/IPv4 packet builder for TX (generic). Roadmap: Phase 5/6.
//
// STUB. Prepends UDP + IPv4 + (fixed) MAC addressing around a payload (e.g. the
// 13-byte ACK from groovy_ack_sender, or input reports) and hands it to
// eth_mac_tx. The PC's source addr/port are latched from the last RX datagram.
// TODO(Phase5): IPv4/UDP header construction, IPv4 checksum, length fields.
`default_nettype none

module eth_udp_tx (
    input  wire        clk,
    input  wire        rst,
    // request
    input  wire        send,
    input  wire [15:0] dst_port,
    input  wire [15:0] src_port,
    input  wire [15:0] length,        // payload length
    // payload stream
    input  wire        pl_valid,
    input  wire [7:0]  pl_data,
    input  wire        pl_last,
    output wire        pl_ready,
    // to eth_mac_tx
    output wire        out_valid,
    output wire [7:0]  out_data,
    output wire        out_sop,
    output wire        out_eop,
    input  wire        out_ready
);
    assign pl_ready=1'b1;
    assign out_valid=1'b0; assign out_data=8'd0; assign out_sop=1'b0; assign out_eop=1'b0;
endmodule

`default_nettype wire
