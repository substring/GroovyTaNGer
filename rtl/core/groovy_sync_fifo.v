// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - small single-clock (synchronous) FIFO.
//
// Elastic buffer for the beam-race write path: groovy_blit_rx emits pixels at network
// wire speed (no back-pressure - it just follows in_valid), but the line-ring write
// mapper can only place a pixel when the ring lap-guard allows (it must not lap the
// reader). Without a buffer the mapper's throttle = DROPPING the pixel that arrives
// during a lap-stall (the WL=0 bug on HW). This FIFO sits between them: blit_rx pushes
// at net speed, the mapper pops paced by the raster/lap-guard, and the FIFO absorbs the
// burst. blit_rx and the mapper are BOTH on clk50m, so a plain synchronous FIFO
// suffices - no Gray-code CDC (that is groovy_async_fifo, for true dual-clock).
//
// If the FIFO ever fills (host far outruns the raster for longer than DEPTH pixels),
// push is dropped and `overflow` latches - a status bit, not corruption. In beam-race
// the vCount ACK keeps the host paced so this should not happen; the flag proves it.
//
// full/empty are REGISTERED off the *_nxt pointers (one-cycle-pessimistic, standard).
`default_nettype none

module groovy_sync_fifo #(
    parameter integer DATA_W = 16,
    parameter integer ADDR_W = 6       // depth = 2^ADDR_W (64 default)
) (
    input  wire               clk,
    input  wire               rst,      // active-high, synchronous

    // write side (producer)
    input  wire               wr_en,
    input  wire [DATA_W-1:0]  wr_data,
    output wire               full,

    // read side (consumer)
    input  wire               rd_en,
    output wire [DATA_W-1:0]  rd_data,  // head word, valid while !empty
    output wire               empty,

    output reg                overflow  // sticky: a wr_en was dropped because full
);
    localparam integer DEPTH = (1 << ADDR_W);

    reg [DATA_W-1:0] mem [0:DEPTH-1];

    // ADDR_W+1 bits: extra MSB distinguishes full (equal but wrap bit differs) from
    // empty (fully equal).
    reg  [ADDR_W:0] wptr, rptr;

    wire do_wr = wr_en & ~full;
    wire do_rd = rd_en & ~empty;

    wire [ADDR_W:0] wptr_nxt = wptr + {{ADDR_W{1'b0}}, do_wr};
    wire [ADDR_W:0] rptr_nxt = rptr + {{ADDR_W{1'b0}}, do_rd};

    // empty: pointers fully equal. full: equal low bits, differing wrap MSB.
    assign empty = (wptr == rptr);
    assign full  = (wptr[ADDR_W] != rptr[ADDR_W]) &&
                   (wptr[ADDR_W-1:0] == rptr[ADDR_W-1:0]);

    assign rd_data = mem[rptr[ADDR_W-1:0]];

    always @(posedge clk) begin
        if (rst) begin
            wptr <= {(ADDR_W+1){1'b0}};
            rptr <= {(ADDR_W+1){1'b0}};
            overflow <= 1'b0;
        end else begin
            if (do_wr) mem[wptr[ADDR_W-1:0]] <= wr_data;
            wptr <= wptr_nxt;
            rptr <= rptr_nxt;
            if (wr_en && full) overflow <= 1'b1;   // dropped a pixel
        end
    end
endmodule

`default_nettype wire
