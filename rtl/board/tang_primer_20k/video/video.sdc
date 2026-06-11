// Groovy_Tang - HDMI video bring-up timing constraints.
// SPDX-License-Identifier: GPL-2.0-or-later
// 27 MHz reference. The 371.25 MHz serial clock and 74.25 MHz pixel clock are
// derived (rPLL + CLKDIV) and analyzed from this source.
create_clock -name I_clk -period 37.037 [get_ports {I_clk}]
