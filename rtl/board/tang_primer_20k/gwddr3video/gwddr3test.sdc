// Gowin DDR3 IP self-test clocks.
// sys_clk = 27 MHz (H11) -> rPLL memory_clk ~398 MHz. The IP derives its own clocks
// (clk_out ~99.5 MHz user clock) internally; leave those to the tool.
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk}]
