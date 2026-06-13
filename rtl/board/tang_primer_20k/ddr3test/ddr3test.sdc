// Groovy_Tang - DDR3 bring-up timing constraints.
// Adapted from nand2mario/ddr3-tang-primer-20k (src/ddr3.sdc, Gowin-generated).
// pclk ~99.5 MHz (10 ns), fclk 398.25 MHz (~2.5 ns) - declared on the PLL output
// nets and marked asynchronous to each other (the controller crosses them safely).
create_clock -name clk    -period 10  -waveform {0 5}    [get_nets {clk}]
create_clock -name clk_x4 -period 2.5 -waveform {0 1.25} [get_nets {clk_x4}]
set_clock_groups -asynchronous -group [get_clocks {clk_x4}] -group [get_clocks {clk}]
