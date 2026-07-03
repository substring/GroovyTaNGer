// Groovy_Tang - BRAM line-ring beam-race timing constraints.
// SPDX-License-Identifier: GPL-2.0-or-later
// 27MHz ref + 50MHz RMII + TMDS serial/pixel. No DDR3. The line ring is dual-port
// BRAM (clk50m write / pix_clk read) - the CDC is the BRAM itself + the write/read
// line synchronisers, declared async here.
create_clock -name clk        -period 37.037 -waveform {0 18.518} [get_ports {clk}]
create_clock -name clk50      -period 20     -waveform {0 10}     [get_ports {netrmii_clk50m}]
create_clock -name serial_clk -period 2.6936 [get_nets {serial_clk}]
create_clock -name pix_clk    -period 13.468 [get_nets {pix_clk}]
set_clock_groups -asynchronous -group [get_clocks {pix_clk serial_clk}]
set_clock_groups -asynchronous -group [get_clocks {clk50}]
