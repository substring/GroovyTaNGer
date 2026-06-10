// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - IPv4 + UDP parser (generic). Roadmap: Phase 5. Spec section 5.1.
//
// STUB. Strips IPv4 header (check version/IHL/proto=UDP, optional checksum),
// then UDP header, demuxing by dest port to the Groovy paths:
//   32100 -> data (commands + pixel/audio stream)   [primary]
//   32101 -> inputs
//   32105 -> GMC (spec Q6, investigate)
// Emits the UDP payload with sop/eop plus the matched port id.
// TODO(Phase5): header field extraction, length tracking, port demux.
`default_nettype none

module eth_ipv4_parser (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    input  wire        in_sop,
    input  wire        in_eop,
    output wire        out_valid,
    output wire [7:0]  out_data,
    output wire        out_sop,
    output wire        out_eop,
    output wire [15:0] dst_port,
    output wire [15:0] src_port,
    output wire        is_data,    // dst_port == 32100
    output wire        is_inputs,  // dst_port == 32101
    output wire        is_gmc      // dst_port == 32105
);
    assign out_valid=1'b0; assign out_data=8'd0; assign out_sop=1'b0; assign out_eop=1'b0;
    assign dst_port=16'd0; assign src_port=16'd0;
    assign is_data=1'b0; assign is_inputs=1'b0; assign is_gmc=1'b0;
endmodule

`default_nettype wire
