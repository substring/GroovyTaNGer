// Groovy_Tang - diagnostic (no DDR3) timing. 27MHz ref; pclk + TMDS derived.
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk}]
create_clock -name clk    -period 10  -waveform {0 5}    [get_nets {pclk}]
// No ddr_fclk here: the fake memory runs on pclk only (the real DDR3 controller's
// 398 MHz fclk doesn't exist in this build), so don't constrain it.
// pix_clk (74.25 MHz) clocks the WHOLE scanout (line-buffer BRAM reads + tag-match
// mux). MUST be constrained or P&R doesn't time it -> setup violations -> garbage.
create_clock -name serial_clk -period 2.6936 [get_nets {serial_clk}]
create_clock -name pix_clk    -period 13.468 [get_nets {pix_clk}]
// pclk (fake-mem fetch) and pix_clk are async - the line buffer is the CDC.
set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {pix_clk serial_clk}]
