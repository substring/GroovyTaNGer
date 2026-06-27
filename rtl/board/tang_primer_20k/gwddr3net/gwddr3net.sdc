// Groovy_Tang - network + DDR3 + HDMI merged timing constraints.
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Clocks present:
//   clk            27 MHz reference (-> PLL_6M for udp, -> mem_pll for DDR3,
//                  -> rpll_tmds for the 720p pixel clock)
//   netrmii_clk50m 50 MHz RMII clock from the PHY (network domain)
//   serial_clk     371.25 MHz TMDS serial (rpll_tmds net)
//   pix_clk        74.25 MHz 720p pixel clock (CLKDIV/5 net) - MUST be constrained
//                  or P&R won't time the line-buffer BRAM reads (garbage on HW).
// The DDR3 IP derives memory_clk / clk_out internally; the tool auto-constrains
// those. Cross-domain paths (network<->DDR3 via the async FIFO; DDR3<->scanout via
// the line buffer) are handled in RTL by synchronisers / the FIFO, so they are
// declared asynchronous here.
create_clock -name clk        -period 37.037 -waveform {0 18.518} [get_ports {clk}]
create_clock -name clk50      -period 20     -waveform {0 10}     [get_ports {netrmii_clk50m}]
create_clock -name serial_clk -period 2.6936 [get_nets {serial_clk}]
create_clock -name pix_clk    -period 13.468 [get_nets {pix_clk}]

// scanout (pix_clk/serial_clk) is async to everything else (line buffer is the CDC).
set_clock_groups -asynchronous -group [get_clocks {pix_clk serial_clk}]
// the 50 MHz network domain is async to the 27 MHz / DDR3 side (async FIFO is the CDC).
set_clock_groups -asynchronous -group [get_clocks {clk50}]
