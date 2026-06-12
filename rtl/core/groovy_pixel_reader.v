// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - framebuffer read + integer scaler (Rung 5), ARBITRARY N.
//
// Maps each output pixel back to a source pixel by a reciprocal multiply
// (no division, any integer N >= 1):
//   src_x = (out_x * recip_h) >> 16,  src_y = (out_y * recip_v) >> 16
// where recip = ceil(65536 / N). For N=8 recip=8192 (== >>3); for N=3 recip=21846.
// This is the super-res replicator (each native pixel repeated N_h across) plus
// vertical scan-multiply (N_v). For a real CRT set N_v=1 (recip_v=65536).
//
// 3-stage pipeline (src -> addr -> VRAM read); de/hs/vs delayed 3 cycles to stay
// aligned (a harmless few-pixel shift). RGB565 -> RGB888 on output.
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
    input  wire [16:0] recip_h,        // ceil(65536 / N_h)
    input  wire [16:0] recip_v,        // ceil(65536 / N_v)
    output wire [ADDR_W-1:0] raddr,
    input  wire [15:0]       rdata,
    output wire [7:0]  r,
    output wire [7:0]  g,
    output wire [7:0]  b,
    output reg         de_o,
    output reg         hs_o,
    output reg         vs_o
);
    wire [32:0] sx_c = (hcount * recip_h) >> 16;
    wire [32:0] sy_c = (vcount * recip_v) >> 16;

    reg [15:0] sx, sy;
    reg [ADDR_W-1:0] raddr_r;
    reg de1, hs1, vs1, de2, hs2, vs2;
    always @(posedge clk) begin
        // stage 1: source coords
        sx<=sx_c[15:0]; sy<=sy_c[15:0]; de1<=de; hs1<=hsync; vs1<=vsync;
        // stage 2: linear address (uses the stage-1 registers)
        raddr_r <= (sy * native_w + sx);
        de2<=de1; hs2<=hs1; vs2<=vs1;
        // stage 3: aligns with the VRAM read of raddr_r
        de_o<=de2; hs_o<=hs2; vs_o<=vs2;
    end
    assign raddr = raddr_r;

    assign r = de_o ? {rdata[15:11], 3'b000} : 8'd0;
    assign g = de_o ? {rdata[10:5],  2'b00} : 8'd0;
    assign b = de_o ? {rdata[4:0],   3'b000} : 8'd0;
endmodule

`default_nettype wire
