// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - light ONLY led[0], static. No walking, no scramble, no DDR3.
// The user names the ONE board label that lights = the definitive led[0]->label.
// (The walk and the ledcheck disagreed about led[0]; this settles it.)
`default_nettype none
module led0_top (
    input  wire        sys_clk,
    input  wire        sys_resetn,
    output wire [5:0]  led
);
    assign led = ~6'b000001;   // active-low: only led[0] lit
endmodule
`default_nettype wire
