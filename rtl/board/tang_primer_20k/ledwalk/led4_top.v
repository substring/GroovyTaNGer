// light ONLY led[4], static.
`default_nettype none
module led4_top(input wire sys_clk, input wire sys_resetn, output wire [5:0] led);
    assign led = ~6'b010000;   // only led[4]
endmodule
`default_nettype wire
