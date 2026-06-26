// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - LED WALKER: calibrate the led[N] -> physical-LED mapping.
//
// Nothing but a single lit LED stepping through led[0],1,2,3,4,5,0,... ~once per
// second. NO DDR3, NO PLL gymnastics - just the 27 MHz clock and a counter, so
// nothing can interfere with the LED behaviour. Watch which PHYSICAL led lights
// FIRST after power-up/reset (that's led[0]) and confirm it walks cleanly to the
// next physical LED each second and wraps after 6. Tell me the physical order and
// we have the mapping nailed for every future diagnostic.
//
// Active-low LEDs (0 = lit), same as all our projects.
`default_nettype none

module ledwalk_top (
    input  wire        sys_clk,      // 27 MHz, H11
    input  wire        sys_resetn,   // active-low, T10
    output wire [5:0]  led
);
    // ~1 second per step at 27 MHz: 27e6 ~ 2^24.7, so use bit 24 of a counter to
    // tick roughly twice/sec; divide further for ~1s. Use a 25-bit counter and
    // step on its wrap (2^25 / 27e6 ~ 1.24 s) for a comfortable, countable pace.
    reg [24:0] cnt = 25'd0;
    reg [2:0]  pos = 3'd0;            // which led is lit (0..5)
    always @(posedge sys_clk or negedge sys_resetn) begin
        if (!sys_resetn) begin
            cnt <= 25'd0;
            pos <= 3'd0;              // start on led[0] right after reset
        end else begin
            cnt <= cnt + 25'd1;
            if (cnt == 25'd0) begin   // wrap (~1.24 s) -> advance
                pos <= (pos == 3'd5) ? 3'd0 : pos + 3'd1;   // modulo 6
            end
        end
    end

    // one-hot: light exactly the led at `pos`. Active-low.
    assign led = ~(6'b000001 << pos);
endmodule

`default_nettype wire
