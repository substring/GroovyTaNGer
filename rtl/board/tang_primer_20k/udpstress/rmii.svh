// ===========================================================================
// VENDORED INTO Groovy_Tang — provenance header added; original content below.
// RMII SystemVerilog interface.
// Source : Sipeed TangPrimer-20K-example, Ethernet/verilog_UDP
//          https://github.com/sipeed/TangPrimer-20K-example
// Author : ZiyangYE (https://github.com/ZiyangYE/Verilog_TCP)
// License: Apache-2.0 (see ./LICENSE, ./NOTICE.md). Used in Groovy_Tang
//          (GPL-2.0-or-later) via Apache<->GPLv3 compatibility.
// ===========================================================================
`ifndef RMII_INTERFACE
`define RMII_INTERFACE
interface rmii(
    input clk50m, rx_crs,
    output mdc, txen,
    inout mdio,
    output [1:0] txd,
    input [1:0] rxd
);
/*
    logic clk50m;

    logic [1:0] txd;
    logic txen;
    logic [1:0] rxd;
    logic rx_crs;

    logic mdc;
    logic mdio;
*/
endinterface //rmii
`endif //RMII_INTERFACE