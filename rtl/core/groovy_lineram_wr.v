// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - line-ring write mapper (beam-race write side).
//
// Drains an elastic FIFO (groovy_sync_fifo, fed by groovy_blit_rx at net speed) into
// groovy_lineram, paced by the ring lap-guard. Derives {slot, col} incrementally from
// the pixel stream (like groovy_writeline): col counts 0..native_w-1, wrapping to
// advance the source line; slot = line mod NLINES (low bits). Exposes write_line
// (fully-written line count) for the top's beam-race feedback / invariant.
//
// RING INVARIANT GUARD: the writer must not LAP the reader (overwrite a slot the reader
// still needs). We take the reader's current source line (CDC'd in by the top) and only
// POP the FIFO when writing would NOT violate write_line - read_line < NLINES. A
// lap-stalled pixel is HELD IN THE FIFO (pop deasserts) instead of dropped - the FIFO
// is the back-pressure that groovy_blit_rx itself lacks. If the host outruns the raster
// for longer than the FIFO is deep, the FIFO (not this mapper) flags overflow.
//
// Handshake to the FIFO: pop = in_valid (!empty) && !lap. The popped word is registered
// as this mapper's ring write in the SAME cycle, so ring `we` == pop delayed 0 (we
// assert we on the cycle we accept the word). One-cycle FIFO read latency is fine: on
// pop we read mem[rptr] which is the head word already present (first-word-fall-through
// style: rd_data is combinational at the head).
//
// MONOTONIC line counter (the wrap-safe fix): `line` / `write_line` NEVER reset to 0 -
// they keep counting across frames (frame 0: 0..H-1, frame 1: H..2H-1, ...). The ring
// SLOT still wraps (line mod NLINES) - that's intended - but the write_line-read_line
// DISTANCE is now always the true small gap, so a raster wrap (read jumping frames) can
// never make the guard falsely see a huge lead and trap the writer. blit_valid only
// realigns the COLUMN (col<-0) at a new source frame; `line` marches on. `read_line`
// (CDC'd from the reader) is likewise monotonic - the two share a common origin set at
// SYNC/FILL and the host pacing keeps them within NLINES.
`default_nettype none

module groovy_lineram_wr #(
    parameter integer NLINES  = 8,
    parameter integer LNSEL_W = 3,
    parameter integer COL_W   = 10,
    parameter integer DATA_W  = 16
) (
    input  wire                 clk,          // network/write clock (clk50m)
    input  wire                 rst,
    input  wire                 frame_start,  // pulse: new frame (blit_valid)

    // from the elastic FIFO (fed by blit_rx). in_valid = FIFO !empty.
    input  wire                 in_valid,
    input  wire [DATA_W-1:0]    in_data,      // FIFO head word (combinational)
    output wire                 pop,          // FIFO rd_en: 1 when we accept in_data
    input  wire [15:0]          native_w,     // source pixels per line

    // ring flow control: reader's current source line (CDC'd from pix_clk by the top)
    input  wire [15:0]          read_line,

    // to groovy_lineram write port
    output reg                  we,
    output reg  [LNSEL_W-1:0]   w_slot,
    output reg  [COL_W-1:0]     w_col,
    output reg  [DATA_W-1:0]    w_data,

    // status
    output reg  [15:0]          write_line,   // count of fully-written source lines
    output wire                 stall         // high when held off by the ring guard
);
    reg [15:0] col;       // column within the current source line
    reg [15:0] line;      // current source line being written

    // Would writing the current line lap the reader? WRAP-SAFE: `gap` is the modulo-2^16
    // distance the writer is ahead of the reader (line - read_line as unsigned wraps
    // correctly as long as the real gap < 32768, which the read<=write clamp guarantees).
    // Lap when the writer would run NLINES ahead. read_line is the CLAMPED reader line
    // (never past write), so the writer never sees a bogus huge gap and never false-traps.
    wire [15:0] gap = line - read_line;
    wire lap = (gap >= NLINES[15:0]) && (gap < 16'h8000);
    assign stall = lap;

    // Accept a pixel from the FIFO only when one is present AND placing it would not lap
    // the reader. This is the back-pressure: a held pixel stays in the FIFO.
    wire accept = in_valid && !lap;
    assign pop = accept;

    always @(posedge clk) begin
        we <= 1'b0;
        if (rst) begin
            // full reset ONLY on hard reset: monotonic counters start at 0.
            col <= 16'd0; line <= 16'd0; write_line <= 16'd0;
            w_slot <= {LNSEL_W{1'b0}}; w_col <= {COL_W{1'b0}}; w_data <= {DATA_W{1'b0}};
        end else if (frame_start) begin
            // new SOURCE frame: realign BOTH col and line to 0. line is now PER-FRAME
            // (bounded 0..SRC_H-1), matching the reader's per-frame line - neither can
            // overflow 16 bits (the ~2s degeneration was a monotonic counter passing
            // 32768). write_line likewise restarts each frame. Slot = line mod NLINES.
            col <= 16'd0; line <= 16'd0; write_line <= 16'd0;
        end else if (accept) begin
            // place this pixel
            we     <= 1'b1;
            w_slot <= line[LNSEL_W-1:0];       // line mod NLINES (power of two)
            w_col  <= col[COL_W-1:0];
            w_data <= in_data;
            // advance col / line
            if (col + 16'd1 >= native_w) begin
                col        <= 16'd0;
                line       <= line + 16'd1;
                write_line <= line + 16'd1;     // this line is now fully written
            end else begin
                col <= col + 16'd1;
            end
        end
    end
endmodule

`default_nettype wire
