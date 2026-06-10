// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - generic Galois LFSR (pseudo-random / counter helper)
//
// Reusable, vendor-neutral. Ported in spirit from Groovy_MiSTer rtl/lfsr.v
// (which was a fixed maximal-length sequence). Parameterised here on width.
`default_nettype none

module lfsr #(
    parameter WIDTH = 8,
    // Galois taps mask. Default is a maximal-length tap set for WIDTH=8.
    parameter [WIDTH-1:0] TAPS = 8'hB8
) (
    input  wire             clk,
    input  wire             rst,    // sync, active high -> loads SEED
    input  wire             en,
    input  wire [WIDTH-1:0] seed,
    output reg  [WIDTH-1:0] q
);
    wire feedback = q[0];

    always @(posedge clk) begin
        if (rst)
            q <= (seed == {WIDTH{1'b0}}) ? {{(WIDTH-1){1'b0}}, 1'b1} : seed;
        else if (en)
            q <= feedback ? ((q >> 1) ^ TAPS) : (q >> 1);
    end
endmodule

`default_nettype wire
