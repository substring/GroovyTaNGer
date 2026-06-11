// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - Gowin rPLL dynamic divider-select encoder (Rung 4b).
//
// Maps solver coefficients (idiv/fbdiv/odiv as plain divisor values) to the
// Gowin rPLL dynamic select inputs IDSEL/FBDSEL/ODSEL (used when
// DYN_{IDIV,FBDIV,ODIV}_SEL = "true"). Encoding per Gowin UG286:
//   IDSEL  = 64 - IDIV    (111111 -> IDIV=1 ... 000000 -> IDIV=64)
//   FBDSEL = 64 - FBDIV   (same)
//   ODSEL  : discrete table (see below)
// Cross-checked vs the example TMDS_rPLL: idiv4/fbdiv55/odiv2 (static
// IDIV_SEL3/FBDIV_SEL54/ODIV_SEL2) -> IDSEL=60, FBDSEL=9, ODSEL=63. Combinational.
`default_nettype none

module rpll_sel_encode (
    input  wire [6:0] idiv,    // 1..64
    input  wire [6:0] fbdiv,   // 1..64
    input  wire [7:0] odiv,    // 2,4,8,16,32,48,64,80,96,112,128
    output wire [5:0] idsel,
    output wire [5:0] fbdsel,
    output reg  [5:0] odsel
);
    // 64 - div fits in 6 bits for div in [1,64] (div=1 -> 63, div=64 -> 0)
    wire [6:0] idsel7  = 7'd64 - idiv;
    wire [6:0] fbdsel7 = 7'd64 - fbdiv;
    assign idsel  = idsel7[5:0];
    assign fbdsel = fbdsel7[5:0];

    always @(*) begin
        case (odiv)
            8'd2:   odsel = 6'b111111;
            8'd4:   odsel = 6'b111110;
            8'd8:   odsel = 6'b111100;
            8'd16:  odsel = 6'b111000;
            8'd32:  odsel = 6'b110000;
            8'd48:  odsel = 6'b101000;
            8'd64:  odsel = 6'b100000;
            8'd80:  odsel = 6'b011000;
            8'd96:  odsel = 6'b010000;
            8'd112: odsel = 6'b001000;
            8'd128: odsel = 6'b000000;
            default:odsel = 6'b111111;   // default /2
        endcase
    end
endmodule

`default_nettype wire
