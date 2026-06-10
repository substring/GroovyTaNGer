// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - generic binary -> packed BCD (double-dabble), combinational.
//
// Reusable, vendor-neutral. Equivalent role to Groovy_MiSTer rtl/binary_to_bcd.v.
//   DIGITS = number of decimal digits in the output (4 bits each).
//   Output is packed BCD: bits [4*DIGITS-1 -: 4] is the most significant digit.
`default_nettype none

module binary_to_bcd #(
    parameter IN_WIDTH = 16,
    parameter DIGITS   = 5
) (
    input  wire [IN_WIDTH-1:0]    bin,
    output reg  [DIGITS*4-1:0]    bcd
);
    integer i, d;
    reg [DIGITS*4-1:0] tmp;

    always @(*) begin
        tmp = {DIGITS*4{1'b0}};
        // shift IN_WIDTH bits through, adding 3 to any nibble >= 5 each step
        for (i = IN_WIDTH-1; i >= 0; i = i - 1) begin
            for (d = 0; d < DIGITS; d = d + 1) begin
                if (tmp[d*4 +: 4] >= 5)
                    tmp[d*4 +: 4] = tmp[d*4 +: 4] + 4'd3;
            end
            tmp = {tmp[DIGITS*4-2:0], bin[i]};
        end
        bcd = tmp;
    end
endmodule

`default_nettype wire
