// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - convert CMD_SWITCHRES pClock (IEEE-754 double, MHz) to integer kHz.
// Rung 4 groundwork. Bridges groovy_packet_parser.sr_pclk -> groovy_pll_solver.fout_khz.
//
// pClock arrives as a 64-bit little-endian double giving the pixel clock in MHz
// (e.g. 25.175). The PLL solver works in integer kHz, so:
//     kHz = round(value_MHz * 1000)
//         = round( mantissa_full * 1000 * 2^(exp-1075) )
// where value = (-1)^s * 1.mant * 2^(exp-1023), mantissa_full = (1<<52)|mant.
// Sign is ignored (pixel clock is positive). Combinational; evaluated once per
// mode change, so the variable shift is acceptable.
`default_nettype none

module pclk_double_to_khz (
    input  wire [63:0] pclk_dbl,      // IEEE-754 double, MHz
    output reg  [31:0] pclk_khz,
    output reg         valid          // 1 = normal value in a sane pixel-clock range
);
    wire [10:0] exp       = pclk_dbl[62:52];
    wire [51:0] mant      = pclk_dbl[51:0];
    wire [52:0] mant_full = {1'b1, mant};            // implicit leading 1 (normals)
    wire [63:0] num       = mant_full * 64'd1000;     // < 2^63

    integer    shift;
    reg [63:0] rounded;

    always @(*) begin
        rounded = 64'd0;                              // default (avoids latch inference)
        shift   = 1075 - exp;                         // exp-1075 right shift
        if (exp == 11'd0) begin                       // zero / subnormal
            pclk_khz = 32'd0;
            valid    = 1'b0;
        end else if (shift <= 0) begin                // >= ~2 GHz: unsupported
            pclk_khz = 32'hFFFFFFFF;
            valid    = 1'b0;
        end else if (shift >= 64) begin               // < 1 kHz: round to zero
            pclk_khz = 32'd0;
            valid    = 1'b0;
        end else begin
            rounded  = num + (64'd1 << (shift - 1));   // round to nearest
            pclk_khz = (rounded >> shift);             // truncate to 32 bits
            valid    = 1'b1;
        end
    end
endmodule

`default_nettype wire
