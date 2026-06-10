// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - board top level for Sipeed Tang Primer 20K Dock.
// Roadmap: Phase 0/2. Spec section 6.2 (board layer).
//
// STUB. Pin-mapped top: 27 MHz refclk, HDMI TMDS pairs, Ethernet PHY, optional
// jack/PMOD. Instantiates the HDMI clocking (pll_hdmi + CLKDIV), the vendored
// hdmi2 serializer + ELVDS_OBUF, the Ethernet PHY wrapper, and groovy_top.
// Pin names must match tang_primer_20k.cst.
//
// TODO(Phase0): confirm refclk pin (spec section 2 says H11 "a confirmer").
// TODO(Phase2): HDMI clock tree + ELVDS_OBUF, see spec sections 6.5/8.
// TODO(Phase5): Ethernet PHY pins from Dock schematic.
`default_nettype none

module top_tang_primer (
    input  wire        clk_27,          // onboard oscillator
    input  wire        rst_n,           // active-low button

    // HDMI (TMDS differential pairs via ELVDS_OBUF)
    output wire        tmds_clk_p,  output wire tmds_clk_n,
    output wire [2:0]  tmds_d_p,    output wire [2:0] tmds_d_n

    // TODO(Phase5): Ethernet RGMII/RMII pins
    // TODO(Phase1): LEDs for bring-up
);
    wire rst = ~rst_n;

    // TODO(Phase2): gowin_pll_hdmi -> clk_pixel_x5, CLKDIV/5 -> clk_pixel
    // TODO(Phase2): hdmi2 top (DVI_OUTPUT first) -> tmds_d/tmds_clk
    // TODO(Phase5): eth_phy_gowin -> groovy_top RX/TX
    // groovy_top u_core (.clk_sys(clk_pixel), .rst(rst), ...);

    assign {tmds_clk_p, tmds_clk_n} = 2'b01;
    assign tmds_d_p = 3'b000;
    assign tmds_d_n = 3'b111;
endmodule

`default_nettype wire
