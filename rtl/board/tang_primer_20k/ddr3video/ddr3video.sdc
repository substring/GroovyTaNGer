// Groovy_Tang - DDR3 -> line buffer -> 720p HDMI timing constraints.
// SPDX-License-Identifier: GPL-2.0-or-later
// 27 MHz reference. Two PLLs derive: (a) the DDR3 clocks - clk (~99.5MHz pclk)
// and clk_x4 (398.25MHz fclk), declared + marked async (the controller crosses
// them safely, per the vendored ddr3.sdc); (b) the 371.25MHz TMDS serial clock
// and 74.25MHz pixel clock (CLKDIV/5), analyzed from the 27MHz source.
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk}]
create_clock -name clk    -period 10  -waveform {0 5}    [get_nets {pclk}]
create_clock -name clk_x4 -period 2.5 -waveform {0 1.25} [get_nets {ddr_fclk}]
// CRITICAL: pix_clk = 74.25 MHz (CLKDIV/5 of the 371.25 MHz TMDS serial) clocks the
// WHOLE scanout: line-buffer BRAM reads + the 3:1 read_idx mux + RGB565->888. Without
// constraining it, P&R does NOT time the scanout -> setup violations on HW -> garbage
// BRAM reads (gross corruption invisible in sim, which has ideal timing). serial_clk
// is the 371.25 MHz DVI SERDES clock (rpll_tmds -> CLKDIV -> pix_clk).
create_clock -name serial_clk -period 2.6936 [get_nets {serial_clk}]
create_clock -name pix_clk    -period 13.468 [get_nets {pix_clk}]
// pclk (DDR3 user side) and pix_clk are async - the line buffer is the CDC.
set_clock_groups -asynchronous -group [get_clocks {clk_x4}] -group [get_clocks {clk}] -group [get_clocks {pix_clk serial_clk}]
