// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - framebuffer read + integer scaler (Rung 5), arbitrary N, DEEPLY
// PIPELINED so the read path has large timing slack (the 74 MHz pixel clock plus
// a ~460 Kb dual-bank BRAM is tight on the GW2A; pipelining absorbs placement/
// routing variance that otherwise causes intermittent pixel glitches).
//
//   src = (out * recip) >> 16   (recip = ceil(65536/N); for N=8 recip=8192 == >>3)
//   addr = src_y * native_w + src_x + bank_off
//
// 5 stages: (1) source coords, (2) multiply, (3) add, (4) route register to the
// BRAM, (5) BRAM read. de/hs/vs delayed 5 cycles to stay aligned. RGB565->RGB888.
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
    input  wire [11:0] native_w,
    input  wire [16:0] recip_h,        // ceil(65536 / N_h)
    input  wire [16:0] recip_v,        // ceil(65536 / N_v)
    input  wire [ADDR_W-1:0] bank_off,
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

    // stage 1: source coords
    reg [15:0] sx1, sy1;  reg [ADDR_W-1:0] bo1;  reg de1, hs1, vs1;
    // stage 2: multiply
    reg [27:0] mul2;  reg [15:0] sx2;  reg [ADDR_W-1:0] bo2;  reg de2, hs2, vs2;
    // stage 3: add
    reg [ADDR_W-1:0] raddr3;  reg de3, hs3, vs3;
    // stage 4: route register feeding the BRAM
    reg [ADDR_W-1:0] raddr_r;  reg de4, hs4, vs4;

    always @(posedge clk) begin
        sx1<=sx_c[15:0]; sy1<=sy_c[15:0]; bo1<=bank_off; de1<=de;  hs1<=hsync; vs1<=vsync;
        mul2<=sy1*native_w; sx2<=sx1; bo2<=bo1;          de2<=de1; hs2<=hs1;  vs2<=vs1;
        raddr3<=mul2[ADDR_W-1:0]+sx2+bo2;                de3<=de2; hs3<=hs2;  vs3<=vs2;
        raddr_r<=raddr3;                                 de4<=de3; hs4<=hs3;  vs4<=vs3;
        de_o<=de4; hs_o<=hs4; vs_o<=vs4;                 // stage 5 (aligns w/ BRAM)
    end
    assign raddr = raddr_r;

    // rdata = mem[raddr_r] one cycle after raddr_r (stage 5), gated by de_o
    assign r = de_o ? {rdata[15:11], 3'b000} : 8'd0;
    assign g = de_o ? {rdata[10:5],  2'b00} : 8'd0;
    assign b = de_o ? {rdata[4:0],   3'b000} : 8'd0;
endmodule

`default_nettype wire
