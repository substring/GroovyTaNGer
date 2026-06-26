// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - LED WALKER v2 (clean re-calibration). Lights led[0], then a DARK
// gap, then led[1], dark gap, ... led[5], dark gap, repeat. The dark gaps make the
// sequence unambiguous to read. Drives led[N] DIRECTLY (no scramble) so the user's
// reading IS the led[N] -> board-label map. NO DDR3/PLL - just the 27 MHz clock.
//
// Read off the 6 board LABELS in the order they light (skipping the dark gaps).
// That sequence = [label for led0, led1, led2, led3, led4, led5].
`default_nettype none

module ledwalk2_top (
    input  wire        sys_clk,
    input  wire        sys_resetn,
    output wire [5:0]  led
);
    // step counter: 12 steps = 6 (lit led[k]) interleaved with 6 (all dark).
    // ~1.2 s per step at 27 MHz (bit 24 wrap on a 25-bit counter).
    reg [24:0] cnt = 25'd0;
    reg [3:0]  step = 4'd0;       // 0..11
    always @(posedge sys_clk or negedge sys_resetn) begin
        if (!sys_resetn) begin
            cnt  <= 25'd0;
            step <= 4'd0;
        end else begin
            cnt <= cnt + 25'd1;
            if (cnt == 25'd0)
                step <= (step == 4'd11) ? 4'd0 : step + 4'd1;
        end
    end

    // even steps = light led[step/2]; odd steps = all dark (gap).
    wire        lit_phase = ~step[0];
    wire [2:0]  which     = step[3:1];     // 0..5
    assign led = lit_phase ? ~(6'b000001 << which) : 6'b111111;
endmodule

`default_nettype wire
