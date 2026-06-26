`default_nettype none
module led2_top(input wire sys_clk, input wire sys_resetn, output wire [5:0] led);
    assign led = ~(6'b1 << 2);
endmodule
`default_nettype wire
