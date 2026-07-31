// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - per-slot "ground truth" ring: which SOURCE LINE does ring slot N
// actually hold right now? Same dual-port shape as groovy_lineram (one write clock,
// one read clock, no CDC synchronizer needed - the tool infers a true dual-port block),
// but indexed by slot only (NLINES entries), not {slot,col}.
//
// Why this exists (2026-07-19): groovy_lineram_wr's fifo_overflow recovery advances
// col/line/write_line even for a pixel that was DROPPED (FIFO full), so write_line
// alone can no longer prove the ring's physical content is fresh - a slot that missed
// its rewrite this lap still holds an OLDER frame's line (line - k*NLINES for some
// k>=1), and the old combinational-only "write_line reached SRC_H" check can't tell.
// This ring makes that observable: groovy_lineram_scan compares slot_line[r_slot]
// against the line it's ABOUT to display and holds the last good pixel instead of
// showing a stale line from a previous lap (reproduced on HW: sf2.png showed a
// mid-frame block repeating from the very start - slot content was correct, but
// several laps old, and nothing was rejecting it before this fix).
`default_nettype none

module groovy_slotline_ram #(
    parameter integer NLINES  = 32,
    parameter integer LNSEL_W = 5
) (
    // ---- write port (network / clk50m): record the REAL line just written to a slot ----
    input  wire                 wr_clk,
    input  wire                 we,          // 1 when a slot's line is genuinely written
    input  wire [LNSEL_W-1:0]   w_slot,
    input  wire [15:0]          w_line,

    // ---- read port (scanout / pix_clk) ----
    input  wire                 rd_clk,
    input  wire [LNSEL_W-1:0]   r_slot,
    output reg  [15:0]          r_line
);
    reg [15:0] mem [0:NLINES-1];
    integer i;
    initial for (i = 0; i < NLINES; i = i + 1) mem[i] = 16'hFFFF;

    always @(posedge wr_clk) if (we) mem[w_slot] <= w_line;
    always @(posedge rd_clk) r_line <= mem[r_slot];
endmodule

`default_nettype wire
