// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - Ethernet MAC TX (generic). Roadmap: Phase 5. Spec section 6.4.
//
// STUB. Frames outgoing payload: preamble/SFD, dest/src MAC, ethertype, payload,
// CRC32, inter-frame gap. Used to emit ACKs and input packets.
// TODO(Phase5): preamble gen, CRC32, IFG, padding to 64-byte min frame.
`default_nettype none

module eth_mac_tx (
    input  wire        clk,
    input  wire        rst,
    // from eth_udp_tx
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    input  wire        in_sop,
    input  wire        in_eop,
    output wire        in_ready,
    // to eth_phy_gowin
    output wire        phy_valid,
    output wire [7:0]  phy_data,
    output wire        phy_sop,
    output wire        phy_eop
);
    assign in_ready = 1'b1;
    assign phy_valid = 1'b0; assign phy_data = 8'd0;
    assign phy_sop = 1'b0; assign phy_eop = 1'b0;
endmodule

`default_nettype wire
