// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - simple dual-clock framebuffer (Rung 5, BRAM path).
//
// One write port (network/clk50m) + one read port (video/pix_clk). RGB565.
// DEPTH = native pixels stored; keep it within the GW2A BRAM budget (~828 Kb,
// shared with the UDP/parser FIFOs) - e.g. 160x120 = 19200 px = 307 Kb. A full
// arcade frame (320x240) does NOT fit here; that's the DDR3 path (later).
// Single-buffered for the first picture (tearing OK; beam-racing comes next).
`default_nettype none

module groovy_vram #(
    parameter integer DEPTH  = 19200,    // native pixel count (e.g. 160*120)
    parameter integer ADDR_W = 15        // >= clog2(DEPTH)
) (
    input  wire                clk_w,
    input  wire                we,
    input  wire [ADDR_W-1:0]   waddr,
    input  wire [15:0]         wdata,

    input  wire                clk_r,
    input  wire [ADDR_W-1:0]   raddr,
    output reg  [15:0]         rdata
);
    reg [15:0] mem [0:DEPTH-1];

    always @(posedge clk_w) if (we && waddr < DEPTH[ADDR_W-1:0]) mem[waddr] <= wdata;
    always @(posedge clk_r) rdata <= mem[raddr];
endmodule

`default_nettype wire
