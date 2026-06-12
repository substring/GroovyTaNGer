// Groovy_Tang - merged design timing constraints.
// SPDX-License-Identifier: GPL-2.0-or-later
// 27 MHz ref (-> PLL_6M for udp, -> rpll_tmds_dyn for video) + 50 MHz RMII clock.
// (Gowin's get_clocks can't reference the auto-generated PLL/CLKDIV clocks, so
//  async clock-groups aren't expressible here; cross-domain paths are handled in
//  RTL via synchronizers, and the read path is pipelined for slack.)
create_clock -name clk   -period 37.037 -waveform {0 18.518} [get_ports {clk}]
create_clock -name clk50 -period 20     -waveform {0 10}     [get_ports {netrmii_clk50m}]
create_clock -name clk1  -period 1000   -waveform {0 500}    [get_nets {netrmii_mdc_d}]
set_false_path -from [get_clocks {clk1}]  -to [get_clocks {clk50}]
set_false_path -from [get_clocks {clk50}] -to [get_clocks {clk1}]
