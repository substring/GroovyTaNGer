// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - vendor wrapper: DYNAMIC Gowin rPLL for the TMDS serial clock (Rung 4b).
//
// Same rPLL primitive as rpll_tmds, but with DYN_{IDIV,FBDIV,ODIV}_SEL = "true"
// so the dividers come from the IDSEL/FBDSEL/ODSEL inputs at runtime (drive them
// from rpll_sel_encode). CLKOUT = FCLKIN*FBDIV/IDIV (the 5x TMDS serial clock).
// Assert `reset` while loading new selects, release, then wait for `lock`.
// IDIV_SEL/FBDIV_SEL/ODIV_SEL defparams are the power-up defaults (720p).
//
// Hardware-only (instantiates the Gowin rPLL primitive; not simulated here).
`default_nettype none

module rpll_tmds_dyn (
    input  wire       clkin,    // 27 MHz
    input  wire       reset,    // active-high; pulse while changing selects
    input  wire [5:0] idsel,
    input  wire [5:0] fbdsel,
    input  wire [5:0] odsel,
    output wire       clkout,   // TMDS serial clock = pixel*5
    output wire       lock
);
    wire clkoutp_o, clkoutd_o, clkoutd3_o;

    rPLL rpll_inst (
        .CLKOUT(clkout), .LOCK(lock),
        .CLKOUTP(clkoutp_o), .CLKOUTD(clkoutd_o), .CLKOUTD3(clkoutd3_o),
        .RESET(reset), .RESET_P(1'b0), .CLKIN(clkin), .CLKFB(1'b0),
        .FBDSEL(fbdsel), .IDSEL(idsel), .ODSEL(odsel),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
    defparam rpll_inst.FCLKIN          = "27";
    defparam rpll_inst.DYN_IDIV_SEL    = "true";    // dividers from inputs
    defparam rpll_inst.IDIV_SEL        = 3;         // default /4 (720p)
    defparam rpll_inst.DYN_FBDIV_SEL   = "true";
    defparam rpll_inst.FBDIV_SEL       = 54;        // default x55
    defparam rpll_inst.DYN_ODIV_SEL    = "true";
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
