// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - Ethernet MAC RX (generic). Roadmap: Phase 5. Spec section 6.4.
//
// STUB. Recovers frames from the PHY octet stream: preamble/SFD strip, FCS
// (CRC32) check, deliver payload with sop/eop. Vendor-neutral.
// TODO(Phase5): preamble detect, CRC32, length/error handling.
`default_nettype none

module eth_mac_rx (
    input  wire        clk,
    input  wire        rst,
    // from eth_phy_gowin
    input  wire        phy_valid,
    input  wire [7:0]  phy_data,
    input  wire        phy_sop,
    input  wire        phy_eop,
    // to eth_ipv4_parser (payload after MAC header, FCS-validated)
    output wire        out_valid,
    output wire [7:0]  out_data,
    output wire        out_sop,
    output wire        out_eop,
    output wire        crc_ok
);
    assign out_valid = 1'b0; assign out_data = 8'd0;
    assign out_sop = 1'b0; assign out_eop = 1'b0; assign crc_ok = 1'b0;
endmodule

`default_nettype wire
