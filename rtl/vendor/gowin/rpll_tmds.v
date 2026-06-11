// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - vendor wrapper: Gowin rPLL for the TMDS serial clock.
//
// Plain instantiation of the Gowin `rPLL` device primitive (not licensed IP).
// FIXED at the 720p serial clock for Phase 2 bring-up:
//   CLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1) = 27 * 55 / 4 = 371.25 MHz
//   (= 5 x 74.25 MHz pixel clock; CLKDIV /5 in the top recovers the pixel clock)
// Coefficients match Sipeed's TMDS_rPLL (the proven HDMI example).
//
// Rung 4b will replace this with a DYNAMIC version: set DYN_{IDIV,FBDIV,ODIV}_SEL
// = "true" and drive IDSEL/FBDSEL/ODSEL from groovy_pll_solver so SWITCHRES
// retunes the pixel clock for super-res modes.
`default_nettype none

module rpll_tmds (
    input  wire clkin,     // 27 MHz
    output wire clkout,    // 371.25 MHz serial clock
    output wire lock
);
    wire gnd = 1'b0;
    wire clkoutp_o, clkoutd_o, clkoutd3_o;

    rPLL rpll_inst (
        .CLKOUT(clkout), .LOCK(lock),
        .CLKOUTP(clkoutp_o), .CLKOUTD(clkoutd_o), .CLKOUTD3(clkoutd3_o),
        .RESET(gnd), .RESET_P(gnd), .CLKIN(clkin), .CLKFB(gnd),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
    defparam rpll_inst.FCLKIN          = "27";
    defparam rpll_inst.DYN_IDIV_SEL    = "false";
    defparam rpll_inst.IDIV_SEL        = 3;       // /4
    defparam rpll_inst.DYN_FBDIV_SEL   = "false";
    defparam rpll_inst.FBDIV_SEL       = 54;      // x55
    defparam rpll_inst.DYN_ODIV_SEL    = "false";
    defparam rpll_inst.ODIV_SEL        = 2;
    defparam rpll_inst.PSDA_SEL        = "0000";
    defparam rpll_inst.DYN_DA_EN       = "true";
    defparam rpll_inst.DUTYDA_SEL      = "1000";
    defparam rpll_inst.CLKOUT_FT_DIR   = 1'b1;
    defparam rpll_inst.CLKOUTP_FT_DIR  = 1'b1;
    defparam rpll_inst.CLKOUT_DLY_STEP = 0;
    defparam rpll_inst.CLKOUTP_DLY_STEP= 0;
    defparam rpll_inst.CLKFB_SEL       = "internal";
    defparam rpll_inst.CLKOUT_BYPASS   = "false";
    defparam rpll_inst.CLKOUTP_BYPASS  = "false";
    defparam rpll_inst.CLKOUTD_BYPASS  = "false";
    defparam rpll_inst.DYN_SDIV_SEL    = 2;
    defparam rpll_inst.CLKOUTD_SRC     = "CLKOUT";
    defparam rpll_inst.CLKOUTD3_SRC    = "CLKOUT";
    defparam rpll_inst.DEVICE          = "GW2A-18C";
endmodule

`default_nettype wire
