// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - framebuffer read + integer scaler (Rung 5).
//
// Walks the output raster (hcount/vcount from video_timing_gen) and maps each
// output pixel back to a source pixel by power-of-two integer division:
//   src_x = out_x >> shift_h,  src_y = out_y >> shift_v
// i.e. each native pixel is repeated 2^shift_h across (horizontal super-res) and
// each native line 2^shift_v down (scan-multiply), so a small native frame fills
// a standard output mode (e.g. 160x90 with shift=3 -> 1280x720). For a real CRT
// use shift_v=0 (native lines preserved).
//
// Addressing is combinational from hcount/vcount (no per-line counter -> no
// line-start/de coincidence hazard). 2-stage pipeline: (1) registered
// src_y*native_w+src_x, (2) registered VRAM read. de/hs/vs are delayed 2 cycles
// to stay aligned. RGB565 -> RGB888 on output.
//
// NOTE: power-of-two scale only (good for the first-picture path). Arbitrary
// super-res N (3,5,6...) needs a fractional accumulator - a later refinement.
`default_nettype none

module groovy_pixel_reader #(
    parameter integer ADDR_W = 15
) (
    input  wire        clk,            // pix_clk
    input  wire [15:0] hcount,
    input  wire [15:0] vcount,
    input  wire        de,
    input  wire        hsync,
    input  wire        vsync,
    input  wire [11:0] native_w,       // source width (pixels)
    input  wire [3:0]  shift_h,        // log2 horizontal scale
    input  wire [3:0]  shift_v,        // log2 vertical scale
    output wire [ADDR_W-1:0] raddr,
    input  wire [15:0]       rdata,
    output wire [7:0]  r,
    output wire [7:0]  g,
    output wire [7:0]  b,
    output reg         de_o,
    output reg         hs_o,
    output reg         vs_o
);
    wire [15:0] src_x = hcount >> shift_h;
    wire [15:0] src_y = vcount >> shift_v;
    wire [31:0] addr  = src_y * native_w + src_x;

    reg [ADDR_W-1:0] raddr_r;
    reg de1, hs1, vs1;
    always @(posedge clk) begin
        raddr_r <= addr[ADDR_W-1:0];     // stage 1: registered address (+multiply)
        de1<=de;   hs1<=hsync; vs1<=vsync;
        de_o<=de1; hs_o<=hs1;  vs_o<=vs1; // stage 2: align with VRAM read latency
    end
    assign raddr = raddr_r;

    // rdata = mem[raddr_r] one cycle later; gate with the 2-delayed de
    assign r = de_o ? {rdata[15:11], 3'b000} : 8'd0;
    assign g = de_o ? {rdata[10:5],  2'b00} : 8'd0;
    assign b = de_o ? {rdata[4:0],   3'b000} : 8'd0;
endmodule

`default_nettype wire
