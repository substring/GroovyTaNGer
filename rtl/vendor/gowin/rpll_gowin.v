// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - vendor wrapper: Gowin rPLL with DYNAMIC reconfiguration.
// Roadmap: Phase 4. Spec: section 7.
//
// STUB. Wraps the Gowin `rPLL` primitive (or `DynamicPLL`/`PLLVR`) and exposes
// runtime reconfiguration of IDIV/FBDIV/ODIV via the MDCLK/MDOPC/MDAINB reconfig
// interface so groovy_pll_solver's coefficients can be loaded at mode-change.
//
// TODO(Phase4):
//   - Instantiate the real Gowin primitive (gowin EDA: IP generator / `rPLL`).
//   - Wire the dynamic-reconfig (DPA) interface; confirm against UG290E.
//   - Drive `lock` from the primitive's LOCK output.
// Until then this is a behavioural placeholder that just asserts lock.
`default_nettype none

module rpll_gowin (
    input  wire        refclk,        // 27 MHz onboard
    input  wire        reset,
    // coefficients from groovy_pll_solver (loaded on `load`)
    input  wire        load,
    input  wire [6:0]  idiv,
    input  wire [6:0]  fbdiv,
    input  wire [7:0]  odiv,
    output wire        clkout,        // = refclk*fbdiv/(idiv*odiv)
    output reg         lock
);
    // TODO(Phase4): replace with real rPLL instance + DPA reconfig FSM.
    assign clkout = refclk;           // placeholder passthrough
    always @(posedge refclk or posedge reset)
        if (reset) lock <= 1'b0;
        else if (load) lock <= 1'b1;
endmodule

`default_nettype wire
