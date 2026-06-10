// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - horizontal super-resolution factor selector (spec section 8).
//
// HDMI requires pixel clock >= 25 MHz, but arcade modelines are often 5-15 MHz.
// We replicate each source pixel N times so the output clock reaches >= 25 MHz.
// Pick the smallest N in [1..6] such that pclk_src * N >= MIN_KHZ.
//
// Combinational, vendor-neutral. Frequencies are integers in kHz to avoid float.
`default_nettype none

module superres_factor #(
    parameter integer MIN_KHZ = 25000,   // HDMI minimum pixel clock
    parameter integer MAX_N   = 6
) (
    input  wire [31:0] pclk_src_khz,
    output reg  [3:0]  n,                // chosen replication factor (1..MAX_N)
    output wire [31:0] pclk_out_khz      // pclk_src_khz * n
);
    integer k;
    always @(*) begin
        n = MAX_N[3:0];                  // fallback: clamp to MAX_N
        for (k = MAX_N; k >= 1; k = k - 1) begin
            if (pclk_src_khz * k >= MIN_KHZ)
                n = k[3:0];
        end
    end

    assign pclk_out_khz = pclk_src_khz * n;
endmodule

`default_nettype wire
