// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - generic dual-clock (async) FIFO with Gray-coded pointer CDC.
//
// Standard textbook async FIFO (Cummings SNUG2002): a binary write pointer and a
// binary read pointer, each converted to GRAY and double-flopped into the other
// clock domain for the full/empty compares. Gray coding guarantees only one bit
// changes per increment, so a pointer sampled mid-transition resolves to either
// the old or the new value - never a bogus in-between - which keeps full/empty
// safe across the crossing.
//
// full and empty are REGISTERED (not combinational off the *_nxt pointers). A
// combinational form would create a loop - empty <- rgray_nxt <- rbin_nxt <- empty
// (the increment is gated by ~empty) - which deadlocks in simulation and is a real
// cycle in synthesis. Registering the flags from the *_nxt comparison breaks it:
// the increment is gated by the registered flag (a flop output), not by a wire that
// feeds back into itself. A one-cycle-pessimistic flag is the standard, safe trade.
//
// Storage is a simple inferred dual-port RAM (one write clock, one read clock).
// Depth = 2^ADDR_W entries of DATA_W bits. Used here for the network(50 MHz) ->
// DDR3(pclk ~75 MHz) pixel-write CDC: each entry = {ddr_word_addr, rgb565}.
//
// Pointers are ADDR_W+1 bits: the extra MSB distinguishes "full" (pointers equal
// except for the wrap bit) from "empty" (pointers fully equal).
`default_nettype none

module groovy_async_fifo #(
    parameter integer DATA_W = 35,    // {addr, data} width
    parameter integer ADDR_W = 9      // depth = 2^ADDR_W
) (
    // write side
    input  wire               wr_clk,
    input  wire               wr_rst,    // active-high, async to rd side
    input  wire               wr_en,
    input  wire [DATA_W-1:0]  wr_data,
    output reg                full,

    // read side
    input  wire               rd_clk,
    input  wire               rd_rst,    // active-high
    input  wire               rd_en,
    output reg                empty,
    output wire [DATA_W-1:0]  rd_data
);
    localparam integer DEPTH = (1 << ADDR_W);

    // ---- storage (dual-clock RAM) ----
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    // ===================== write pointer (wr_clk) =====================
    reg  [ADDR_W:0] wbin = 0, wgray = 0;
    // increment gated by the REGISTERED full flag (no comb loop)
    wire            do_wr     = wr_en & ~full;
    wire [ADDR_W:0] wbin_nxt  = wbin + {{ADDR_W{1'b0}}, do_wr};
    wire [ADDR_W:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;

    reg  [ADDR_W:0] rgray_w1 = 0, rgray_w2 = 0;   // read gray synced into wr_clk

    // FULL = next write gray would equal read gray with the top two bits inverted.
    wire full_nxt = (wgray_nxt == {~rgray_w2[ADDR_W:ADDR_W-1], rgray_w2[ADDR_W-2:0]});

    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) begin
            wbin <= 0; wgray <= 0; rgray_w1 <= 0; rgray_w2 <= 0; full <= 1'b0;
        end else begin
            if (do_wr) mem[wbin[ADDR_W-1:0]] <= wr_data;
            wbin     <= wbin_nxt;
            wgray    <= wgray_nxt;
            rgray_w1 <= rgray;       // CDC: read gray -> write domain
            rgray_w2 <= rgray_w1;
            full     <= full_nxt;
        end
    end

    // ===================== read pointer (rd_clk) =====================
    reg  [ADDR_W:0] rbin = 0, rgray = 0;
    wire            do_rd     = rd_en & ~empty;
    wire [ADDR_W:0] rbin_nxt  = rbin + {{ADDR_W{1'b0}}, do_rd};
    wire [ADDR_W:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

    reg  [ADDR_W:0] wgray_r1 = 0, wgray_r2 = 0;   // write gray synced into rd_clk

    // EMPTY = next read gray would equal the synced write gray (pointers equal).
    wire empty_nxt = (rgray_nxt == wgray_r2);

    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) begin
            rbin <= 0; rgray <= 0; wgray_r1 <= 0; wgray_r2 <= 0; empty <= 1'b1;
        end else begin
            rbin     <= rbin_nxt;
            rgray    <= rgray_nxt;
            wgray_r1 <= wgray;       // CDC: write gray -> read domain
            wgray_r2 <= wgray_r1;
            empty    <= empty_nxt;
        end
    end

    // combinational read data at the current read address (data for the head word is
    // presented while !empty; the consumer pulses rd_en to advance to the next).
    assign rd_data = mem[rbin[ADDR_W-1:0]];
endmodule

`default_nettype wire
