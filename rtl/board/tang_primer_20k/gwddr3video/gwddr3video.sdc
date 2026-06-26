// Groovy_Tang - Gowin DDR3 IP -> line buffer -> 720p HDMI timing constraints.
// SPDX-License-Identifier: GPL-2.0-or-later
// The DDR3 IP derives its own clocks internally (memory_clk 302.4 MHz, clk_out user
// clock) - the tool auto-constrains those. We constrain the 27 MHz reference and the
// TMDS serial / pixel clocks (the scanout domain). pix_clk MUST be constrained or P&R
// won't time the line-buffer BRAM reads -> garbage on HW (see ddr3video.sdc note).
create_clock -name sys_clk    -period 37.037 [get_ports {sys_clk}]
create_clock -name serial_clk -period 2.6936 [get_nets {serial_clk}]
create_clock -name pix_clk    -period 13.468 [get_nets {pix_clk}]
// scanout (pix_clk/serial_clk) is async to the DDR3 user clock (clk_out) - the line
// buffer is the CDC.
set_clock_groups -asynchronous -group [get_clocks {pix_clk serial_clk}]
