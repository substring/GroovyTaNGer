// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - behavioural stand-ins for the Gowin primitives/IP that gwline_top.sv
// instantiates, so the REAL top (and everything under it) can be simulated unmodified.
// Clocks only; no video is encoded.
`timescale 1ns/1ps
`default_nettype none

module PLL_6M (output wire clkout, output wire clkoutd, input wire clkin);
    reg c6 = 0, c1 = 0;
    always #83.333 c6 = ~c6;        // 6 MHz
    always #500    c1 = ~c1;        // 1 MHz (udp.sv SMI clock)
    assign clkout = c6;  assign clkoutd = c1;
endmodule

// The VIDEO_MODE dividers are accepted but ignored: the bench models mode 0 (720p).
module rpll_tmds #(parameter integer IDIV_SEL = 3, parameter integer FBDIV_SEL = 54,
                   parameter integer ODIV_SEL = 2)
                  (input wire clkin, output wire clkout, output reg lock);
    reg c = 0;
    always #1.3468 c = ~c;          // 371.25 MHz TMDS serial clock
    assign clkout = c;
    initial begin lock = 0; #2000 lock = 1; end
endmodule

module CLKDIV #(parameter DIV_MODE = "2", parameter GSREN = "false")
               (input wire RESETN, input wire HCLKIN, output wire CLKOUT, input wire CALIB);
    reg c = 0;
    always #6.734 c = ~c;           // 74.25 MHz pixel clock (HCLKIN / 5)
    assign CLKOUT = c;
endmodule

module DVI_TX_Top (
    input wire I_rst_n, input wire I_serial_clk, input wire I_rgb_clk,
    input wire I_rgb_vs, input wire I_rgb_hs, input wire I_rgb_de,
    input wire [7:0] I_rgb_r, input wire [7:0] I_rgb_g, input wire [7:0] I_rgb_b,
    output wire O_tmds_clk_p, output wire O_tmds_clk_n,
    output wire [2:0] O_tmds_data_p, output wire [2:0] O_tmds_data_n);
    assign O_tmds_clk_p = 1'b0;  assign O_tmds_clk_n = 1'b1;
    assign O_tmds_data_p = 3'b0; assign O_tmds_data_n = 3'b111;
endmodule

`default_nettype wire
