// Groovy_Tang - DDR3 bring-up timing constraints.
// Adapted from nand2mario/ddr3-tang-primer-20k (src/ddr3.sdc, Gowin-generated).
// pclk ~99.5 MHz (10 ns), fclk 398.25 MHz (~2.5 ns) - declared on the PLL output
// nets and marked asynchronous to each other (the controller crosses them safely).
create_clock -name clk    -period 10  -waveform {0 5}    [get_nets {clk}]
create_clock -name clk_x4 -period 2.5 -waveform {0 1.25} [get_nets {clk_x4}]
// NOTE (audit #4): clk_ck (DDR3 CK, PLL clkoutp) is NOT a fabric net you can
// create_clock on - it feeds the Gowin DDR hard primitives directly, which own the
// DQS/DQ I/O timing internally (TA2003 if you try). So there is no STA gap here; the
// memory-clock timing is handled by the IP, not by these fabric constraints. This
// also means the byte-lane skew is NOT a fabric-timing/constraint issue (and it's
// 850x worse on ONE lane anyway -> per-lane DQS-IP read path, not global timing).
set_clock_groups -asynchronous -group [get_clocks {clk_x4}] -group [get_clocks {clk}]
