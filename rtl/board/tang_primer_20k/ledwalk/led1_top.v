`default_nettype none
module led1_top(input wire sys_clk, input wire sys_resetn, output wire [5:0] led);
    assign led = ~(6'b1 << 1);
endmodule
`default_nettype wire
