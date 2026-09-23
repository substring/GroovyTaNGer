// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - line-ring write mapper (beam-race write side). REWRITTEN 2026-07-20
// from scratch (not a copy of the prior version) after a session diagnosing why the
// ring writer stalled under real network bursts, to make the write path's own state
// directly observable (fifo_level_at_write / target_slot_at_write) instead of only
// inferring it from downstream symptoms.
//
// ROLE: drain an elastic FIFO (groovy_sync_fifo, filled by groovy_blit_rx at raw
// network speed, no back-pressure of its own) into groovy_lineram, one pixel per
// cycle when allowed. Track two positions in the incoming pixel stream:
//   col  - column within the CURRENT source line (0..native_w-1)
//   line - the CURRENT source line index, monotonic (see below)
// A line is "done" the instant its last column lands; that pulses write_line and
// (if the write was real, not a dropped pixel) marks the slot's ground truth.
//
// GUARD RULE (kept as validated this session, not re-derived here - see the guard
// block below for the exact rationale; may be revisited to protect actual reader
// LINES rather than a slot window, in a later pass): a slot may be written UNLESS it
// falls in the reader's near-future window (its current slot + MARGIN-1 ahead, wrapped
// mod NLINES). Everything else - including running arbitrarily far ahead of the
// reader in absolute line count - is fair game. The comparison is done on SLOT
// numbers (line mod NLINES), never on raw line/read_line values - an earlier version
// compared raw values and was wrong in 43% of cases (verified by brute-force
// enumeration), because a slot's protection status only depends on where it sits in
// the ring's own wrap order, not on how far apart the two line counters happen to be.
//
// DROPPED-PIXEL RECOVERY: if the FIFO was full when blit_rx tried to push (no
// back-pressure exists upstream of the FIFO), that pixel is gone - but col/line must
// still advance as if it had landed, or the position counters desync from the real
// column the network is now sending, corrupting every later pixel in the line, not
// just the lost one. The slot's ground truth (sl_*) is NOT updated for a lost pixel -
// its content is stale, not what its slot_line claims, and the reader-side stale-slot
// check (groovy_lineram_scan.v) is what actually protects display from showing it.
`default_nettype none

module groovy_lineram_wr #(
    parameter integer NLINES  = 8,
    parameter integer LNSEL_W = 3,
    parameter integer COL_W   = 10,
    parameter integer DATA_W  = 16,
    parameter integer MARGIN  = 16,   // reader's protected near-future window width;
                                       // same value/meaning as the top's SYNC/FILL
                                       // threshold, passed in rather than duplicated
    parameter integer ADDR_W_FIFO = 12  // must match the upstream FIFO's ADDR_W, so
                                         // fifo_level's width (ADDR_W_FIFO+1 bits, per
                                         // groovy_sync_fifo's own level port) lines up
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 frame_start,   // pulse: a new network frame began

    // upstream elastic FIFO (blit_rx -> here)
    input  wire                 in_valid,      // FIFO has a word ready (!empty)
    input  wire [DATA_W-1:0]    in_data,       // FIFO head word (combinational)
    output wire                 pop,           // FIFO rd_en: pulse to consume in_data
    input  wire [15:0]          native_w,      // source pixels per line
    input  wire                 fifo_overflow, // pulse: upstream just dropped a pixel

    // DIAGNOSTIC (2026-07-20): live FIFO fill level, sampled the cycle we act on a
    // pixel (accept or drop) - lets the top/UART show how full the buffer was AT THE
    // MOMENT of each write decision, not just after the fact via full/empty edges.
    // Width is ADDR_W_FIFO+1 to match groovy_sync_fifo's own fifo_level port exactly
    // (its counter needs one extra bit to represent "completely full", DEPTH itself).
    input  wire [ADDR_W_FIFO:0] fifo_level,

    // reader position (CDC'd from pix_clk by the top) and guard enable (held off
    // during SYNC/FILL, before the reader has a real position to compare against)
    input  wire [15:0]          read_line,
    input  wire                 guard_en,

    // ring write port
    output reg                  we,
    output reg  [LNSEL_W-1:0]   w_slot,
    output reg  [COL_W-1:0]     w_col,
    output reg  [DATA_W-1:0]    w_data,

    // status
    output reg  [15:0]          write_line,    // count of fully-written source lines
    output wire                 stall,         // 1 when the guard is holding the writer

    // per-slot ground truth feed (top wires this into groovy_slotline_ram)
    output reg                  sl_we,
    output reg  [LNSEL_W-1:0]   sl_slot,
    output reg  [15:0]          sl_line,

    // DIAGNOSTIC (2026-07-20): the ring slot a write decision is being made FOR, valid
    // the same cycle as `we`/the fifo_overflow branch - lets the top capture "which
    // slot, and how full was the FIFO" for every real write or drop, instead of only
    // the aggregate counters (write_line, stall) previously available.
    output reg  [LNSEL_W-1:0]   target_slot_at_write,
    output reg  [ADDR_W_FIFO:0] fifo_level_at_write,

    // DIAGNOSTIC (2026-08-09 HW investigation): write_line only updates when a line
    // FULLY completes, so on a real stall it silently shows the PREVIOUS line forever -
    // `cur_line` exposes the in-progress line directly (the one the guard is deciding
    // about right now), and `guard_stuck_cycles` counts consecutive cycles the guard has
    // blocked THIS SAME line without it ever completing - lets the UART distinguish "a
    // brief, self-clearing stall" from "genuinely wedged on one line", which write_line/
    // stall alone cannot show.
    output wire [15:0]          cur_line,
    output reg  [23:0]          guard_stuck_cycles
);
    reg [15:0] col;    // column within the line currently being written
    reg [15:0] line;   // current source line index (monotonic across one frame)
    assign cur_line = line;

    // CLEAR SWEEP: on rst (includes a CMD_INIT-driven video reset from the top), walk
    // all NLINES slot_line entries back to the FFFF "never written this session"
    // sentinel before accepting any pixel. Needed because groovy_slotline_ram is a
    // real BRAM on hardware - its content is whatever was left from a PREVIOUS test
    // until explicitly cleared, which would make SL=FFFF unreliable exactly when it's
    // needed most (right after a reset). NLINES cycles is negligible next to a frame.
    reg             clearing;
    reg [LNSEL_W:0] clear_idx;

    // GUARD: forbid writing a slot in the reader's near-future window. slot_off is the
    // wrap-safe distance (mod NLINES) from the reader's current slot to the candidate
    // write slot; forbidden when that distance is small (the reader is at it or about
    // to reach it soon), safe when large (the reader already passed it and won't
    // return until wrapping all the way around).
    //
    // DO NOT ADD AN ABSOLUTE-LEAD TERM HERE (tried 2026-08-02, removed 2026-08-09 after
    // it wedged real hardware). The attempt added `|| (abs_lead >= MARGIN)` alongside the
    // slot check, meaning to bound how far ahead the writer may run in ABSOLUTE lines,
    // since slot_off (being mod NLINES) cannot tell "1 lap ahead" from "3 laps ahead".
    // The two terms are LOGICALLY CONTRADICTORY and their intersection is EMPTY:
    //   slot_off >= MARGIN  requires the writer to be at LEAST MARGIN lines ahead,
    //   abs_lead  <  MARGIN  requires the writer to be LESS than MARGIN lines ahead.
    // So guard_blocks was true for EVERY possible writer/reader distance - a permanent
    // deadlock the instant guard_en rose, not an occasional timing corner case. It also
    // closes a feedback loop that cannot self-release: the reader is clamped to
    // write_line-1 (wr_top in groovy_lineram_scan.v), so read_line cannot advance until
    // the writer does, while the writer waits on the reader. HW-confirmed with the CL=/GS=
    // UART fields: CL=227 pinned mid-frame with GS=FFFFFF (saturated, >335 ms on one line),
    // most of the screen black. Simulation masked it because blit_valid reset `line` to 0
    // every network frame, handing back a few unguarded cycles each time.
    // The startup over-run this was meant to stop is already handled upstream by
    // gwline_top.sv's raster_en (the raster is frozen until START_THRESHOLD lines are
    // queued, so the writer can no longer build an unbounded lead before the guard
    // engages). See memory gwline-ring-startup-fifo-fix.md.
    wire [LNSEL_W-1:0] candidate_slot = line[LNSEL_W-1:0];
    wire [LNSEL_W-1:0] reader_slot    = read_line[LNSEL_W-1:0];
    wire [LNSEL_W-1:0] slot_off       = candidate_slot - reader_slot;
    wire               guard_blocks   = guard_en && (slot_off < MARGIN[LNSEL_W-1:0]);
    assign stall = guard_blocks;

    wire accept = in_valid && !guard_blocks && !clearing;
    assign pop  = accept;

    // DIAGNOSTIC (2026-08-09): count consecutive cycles guard_blocks holds while `line`
    // hasn't moved - saturates (does not wrap) so the UART can distinguish "briefly
    // stalled, recovered" (small/reset value) from "genuinely wedged for the rest of
    // the session" (pinned at max). Reset whenever line actually advances or the guard
    // releases, so it always reflects the CURRENT stall's age, not a lifetime total.
    reg [15:0] guard_stuck_line;
    always @(posedge clk) begin
        if (rst || frame_start) begin
            guard_stuck_cycles <= 24'd0;
            guard_stuck_line   <= 16'd0;
        end else if (guard_blocks) begin
            if (line != guard_stuck_line) begin
                guard_stuck_line   <= line;
                guard_stuck_cycles <= 24'd1;
            end else if (guard_stuck_cycles != 24'hFFFFFF) begin
                guard_stuck_cycles <= guard_stuck_cycles + 24'd1;
            end
        end else begin
            guard_stuck_cycles <= 24'd0;
        end
    end

    always @(posedge clk) begin
        we    <= 1'b0;
        sl_we <= 1'b0;

        if (rst) begin
            col <= 16'd0; line <= 16'd0; write_line <= 16'd0;
            w_slot <= {LNSEL_W{1'b0}}; w_col <= {COL_W{1'b0}}; w_data <= {DATA_W{1'b0}};
            clearing <= 1'b1; clear_idx <= {(LNSEL_W+1){1'b0}};
            target_slot_at_write <= {LNSEL_W{1'b0}};
            fifo_level_at_write  <= {(ADDR_W_FIFO+1){1'b0}};

        end else if (clearing) begin
            sl_we   <= 1'b1;
            sl_slot <= clear_idx[LNSEL_W-1:0];
            sl_line <= 16'hFFFF;
            clear_idx <= clear_idx + 1'b1;
            if (clear_idx == NLINES[LNSEL_W:0] - 1) clearing <= 1'b0;

        end else if (frame_start) begin
            // A new network frame restarts both counters at 0 - line is per-frame
            // (bounded 0..SRC_H-1), matching how the reader indexes its own position,
            // so neither counter risks the 16-bit wraparound a fully monotonic
            // across-frames counter would eventually hit.
            col <= 16'd0; line <= 16'd0; write_line <= 16'd0;

        end else if (accept) begin
            // Real write: capture the diagnostic snapshot for THIS decision...
            target_slot_at_write <= candidate_slot;
            fifo_level_at_write  <= fifo_level;
            // ...then place the pixel.
            we     <= 1'b1;
            w_slot <= candidate_slot;
            w_col  <= col[COL_W-1:0];
            w_data <= in_data;

            // Mark the slot "being rewritten" from the FIRST pixel of a new line, not
            // only once the whole line lands - a reader sampling mid-rewrite otherwise
            // sees a genuine mix of the old line's untouched columns and the new
            // line's just-written ones, while slot_line still claims the OLD line was
            // complete and correct. 0xFFFE is reserved (no real line index reaches it).
            if (col == 16'd0) begin
                sl_we   <= 1'b1;
                sl_slot <= candidate_slot;
                sl_line <= 16'hFFFE;
            end

            if (col + 16'd1 >= native_w) begin
                col        <= 16'd0;
                line       <= line + 16'd1;
                write_line <= line + 16'd1;
                sl_we      <= 1'b1;             // this slot now REALLY holds `line`
                sl_slot    <= candidate_slot;
                sl_line    <= line;
            end else begin
                col <= col + 16'd1;
            end

        end else if (fifo_overflow) begin
            // Same diagnostic snapshot for a DROPPED pixel, so the top can tell "the
            // guard held us off" (accept path, stall=1) apart from "we were allowed to
            // write but the FIFO had already lost the pixel upstream" (this path).
            target_slot_at_write <= candidate_slot;
            fifo_level_at_write  <= fifo_level;

            // Advance position counters as if the pixel had landed - it must, or every
            // later column in this line reads at the wrong offset - but do NOT touch
            // we/sl_we: no real data exists for this column, and the slot's ground
            // truth must keep pointing at whatever it last REALLY held.
            if (col + 16'd1 >= native_w) begin
                col        <= 16'd0;
                line       <= line + 16'd1;
                write_line <= line + 16'd1;
            end else begin
                col <= col + 16'd1;
            end
        end
    end
endmodule

`default_nettype wire
