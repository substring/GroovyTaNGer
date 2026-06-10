// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - vendor wrapper: Ethernet PHY interface (RMII/RGMII) on the Dock.
// Roadmap: Phase 5. Spec sections 6.4, 2.
//
// STUB. The Tang Primer 20K Dock RJ45 is a 10/100 PHY. Confirm the FPGA<->PHY
// interface (RMII vs MII) and pinout from the Dock schematic, then present a
// byte-wide RX/TX nibble/octet stream to the generic Ethernet MAC.
//
// TODO(Phase5):
//   - Identify PHY part + interface from Dock schematic (spec section 2).
//   - Implement clock recovery / IDDR-ODDR for RGMII if applicable.
//   - Expose a clean 8-bit MAC-facing stream (rx_valid/rx_data, tx_*).
`default_nettype none

module eth_phy_gowin (
    input  wire        clk_125_or_50,
    input  wire        reset,
    // ---- physical (placeholder, fill from schematic) ----
    // input  wire [3:0] rgmii_rxd, input wire rgmii_rxc, rgmii_rxctl, ...
    // ---- MAC-facing octet stream ----
    output wire        rx_valid,
    output wire [7:0]  rx_data,
    output wire        rx_sop,
    output wire        rx_eop,
    input  wire        tx_valid,
    input  wire [7:0]  tx_data,
    input  wire        tx_sop,
    input  wire        tx_eop,
    output wire        tx_ready
);
    // TODO(Phase5): real PHY adaptation.
    assign rx_valid = 1'b0;
    assign rx_data  = 8'd0;
    assign rx_sop   = 1'b0;
    assign rx_eop   = 1'b0;
    assign tx_ready = 1'b1;
endmodule

`default_nettype wire
