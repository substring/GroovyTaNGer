// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - line-ring scanout reader (beam-race read side).
//
// Drives groovy_lineram's {slot,col} read port from the video raster and does integer
// nearest-neighbour upscale (H_REPL x V_REPL). The ring holds NATIVE-width lines, one
// per slot = (source_line mod NLINES); NLINES is a power of two so slot = the low bits
// of the source line - no divide. Horizontal replicate = src_col = hcount / H_REPL;
// vertical replicate = the source line only advances every V_REPL output lines.
//
// Pipelined like groovy_pixel_reader (the HW-proven scaler): the pixel clock (up to
// 74.25 MHz) + BRAM read is tight on the GW2A, so we register the address a cycle
// before the BRAM and delay de/hs/vs to match. RGB565 (16-bit) here; RGB888 is a later
// widening (DATA_W + the r/g/b extraction).
//
// TWO read lines are exported: `src_line` is the TRUE (unclamped) raster position, used
// only for host feedback. `read_guard` is a LATCHED, underrun-clamped line used by the
// writer's overwrite guard - see the "UNDERRUN clamp" comment below for why a plain
// combinational clamp is not enough (it was found to still wedge the writer, 2026-07-10:
// the free-running video raster completes MANY loops per network-paced source frame, so a
// combinational `sline_raster >= max_line ? wr_top : sline_raster` briefly looks
// "legitimately behind" every time the raster wraps back near 0, even though nothing new
// was actually written - this repeatedly fooled the writer's lap-guard into thinking the
// reader was far behind when it wasn't, stalling the writer after a small number of lines
// (reproduced in sim/tb/groovy_lineram_freeraster_tb.v with a non-cooperative raster).
`default_nettype none

module groovy_lineram_scan #(
    parameter integer NLINES  = 8,
    parameter integer LINE_W  = 1024,
    parameter integer DATA_W  = 16,
    parameter integer LNSEL_W = 3,
    parameter integer COL_W   = 10,
    parameter integer H_REPL  = 4,      // horizontal super-res factor
    parameter integer H_SH    = 2,      // log2(H_REPL)
    parameter integer V_REPL  = 1,      // vertical replicate (CRT native = 1)
    parameter integer SRC_H   = 240     // source lines per frame (for the monotonic index)
) (
    input  wire                 pix_clk,
    input  wire                 pix_rst,      // sync, active high
    input  wire [15:0]          hcount,       // from video_timing_gen
    input  wire [15:0]          vcount,
    input  wire                 de,
    input  wire                 hsync,
    input  wire                 vsync,
    input  wire                 frame_start,  // 1-cycle pulse at raster top-of-frame

    // beam-race clamp: highest source line the writer has committed (MONOTONIC, pix
    // domain). The reader must never read AHEAD of this - the raster is a free-running
    // 60Hz master that would otherwise sprint thousands of lines past the writer, and a
    // monotonic read line that laps the 16-bit range would cross write_line from below
    // and falsely trap the writer's guard. Clamping read <= write keeps the gap small and
    // positive so the wrap-safe subtraction stays valid, and shows the last written line
    // (a visible underrun freeze) instead of garbage when the reader catches up.
    input  wire [15:0]          max_line,     // = write_line (monotonic)

    // ring read port
    output reg  [LNSEL_W-1:0]   r_slot,
    output reg  [COL_W-1:0]     r_col,
    input  wire [DATA_W-1:0]    r_data,

    // per-slot ground truth (groovy_slotline_ram, same read latency as r_data - both are
    // a single synchronous output register on rd_clk/pix_clk, addressed by the same
    // r_slot). CORRECTNESS FIX (2026-07-19): groovy_lineram_wr's fifo_overflow recovery
    // lets write_line advance past a slot that was never actually rewritten this lap, so
    // that slot's PHYSICAL content is an older source line (line - k*NLINES). Comparing
    // slot_actual_line against the line we expect (the address we issued) catches this
    // and freezes the pixel instead of showing a stale line as if it were current
    // (reproduced on HW: sf2.png displayed a mid-frame block repeating from frame start).
    input  wire [15:0]          slot_actual_line,

    // scaled pixel out (RGB565 path) + delayed sync, aligned to the BRAM latency
    output reg  [15:0]          pix_rgb565,
    output reg                  de_o,
    output reg                  hs_o,
    output reg                  vs_o,

    // TWO read-line outputs, deliberately different:
    //   src_line   = the TRUE raster position (sline_raster) -> for the vCount ACK / host
    //                phase lock. The host needs where the beam really is.
    //   read_guard = the CLAMPED read line (sline_frame, <= write) -> for the WRITER's
    //                overwrite guard. The guard needs read<=write or the free raster
    //                (which sprints ahead) makes the guard stall by fits -> FIFO overflow.
    output wire [15:0]          src_line,
    output wire [15:0]          read_guard
);
    // STABLE addressing: the read line is the raster's per-frame source line, derived
    // straight from vcount (0..SRC_H-1, wraps cleanly every video frame). NO monotonic
    // frame counter in the data path - that overflowed 16 bits after ~2s and desynced the
    // clamp, casting garbage. The ring SLOT = sline_frame mod NLINES; the raster always
    // reads "the source line at my current screen position". Phase alignment (writer puts
    // the right line in that slot in time) is a SEPARATE concern (host-mastered, later).
    wire [15:0] sline_raster = (V_REPL == 1) ? vcount :
                               (V_REPL == 2) ? (vcount >> 1) :
                               (V_REPL == 4) ? (vcount >> 2) :
                                               vcount / V_REPL[15:0];
    wire [15:0] scol = hcount >> H_SH;

    // UNDERRUN clamp, LATCHED (not a plain combinational compare - see the module header
    // for why). The raster line (sline_raster) may run ahead of what the writer has
    // committed this frame (max_line = write_line, a COUNT). If so, reading that slot
    // returns a not-yet-written (stale/other-frame) line -> visible corruption. Once the
    // raster has caught up to wr_top (the last written line), STAY there - do not follow
    // sline_raster back down when the free-running video raster wraps to a new loop while
    // the writer is still stuck on the same source frame. Only two ways to unstick:
    //   (a) max_line advances past the displayed line (the writer wrote more - display can
    //       advance again, still clamped to the new wr_top), or
    //   (b) frame_start (a genuinely new source frame) - explicit realign to 0.
    // This makes read_guard MONOTONIC WITHIN A SOURCE FRAME regardless of how many video
    // raster loops occur while waiting, which is what the writer's lap-guard needs.
    wire [15:0] wr_top = (max_line == 16'd0) ? 16'd0 : (max_line - 16'd1);
    reg  [15:0] disp_line;                    // latched, clamp-aware displayed line
    always @(posedge pix_clk) begin
        if (pix_rst || frame_start) begin
            disp_line <= 16'd0;
        end else if (sline_raster < wr_top && sline_raster >= disp_line) begin
            // raster is progressing normally within this source frame and hasn't
            // caught up to the writer yet - follow it.
            disp_line <= sline_raster;
        end else begin
            // raster has caught up to (or passed) the writer, OR it just wrapped to a
            // new video loop (sline_raster < disp_line) - hold at the writer's last
            // committed line either way.
            disp_line <= wr_top;
        end
    end
    wire [15:0] sline_frame = disp_line;

    // src_line = TRUE raster position (for the ACK / host phase lock).
    // read_guard = LATCHED clamped read line (for the writer's overwrite guard).
    assign src_line   = pix_rst ? 16'd0 : sline_raster;
    assign read_guard = pix_rst ? 16'd0 : sline_frame;

    // ---- pipeline (3-stage, matched to the TRUE data latency) ----
    // The address -> pixel path has TWO register stages before r_data is right:
    //   T:   scol combinational
    //   T+1: r_col registered here (stage 1) -> feeds the ring address
    //   T+2: the ring's OWN output reg latches mem[{r_slot,r_col}] (r_data valid next)
    //   T+3: r_data now reflects the T+1 address -> present it as pix_rgb565
    // So de/hs/vs must be delayed by 3 to line up with the pixel (an earlier 2-deep delay
    // was one short -> at a barr boundary one output pixel showed the PREVIOUS column's
    // data = the thin dark/blue seam the user saw between colour bars). de1->de2->de_o.
    //
    // KNOWN, ACCEPTED MINOR ARTIFACT (2026-08-02, gwline_ring_e2e_tb.v investigation):
    // net_frame_start (a new network frame) resets disp_line/sline_frame - and therefore
    // r_slot - DISCONTINUOUSLY, at whatever hcount the raster happens to be at (network
    // frame boundaries are async to the raster, can legitimately land mid-line). r_col
    // keeps following scol/hcount CONTINUOUSLY through that same transition (correct -
    // the horizontal scan itself never pauses). Net effect: the very first pixel shown
    // after a network-frame boundary can briefly pair the NEW line with a column value
    // still catching up from the OLD line's scan position, for exactly one pixel. Traced
    // and confirmed via direct signal dump (r_slot/r_col/expect_line1/2) - this is NOT a
    // ring/data-corruption bug (the ring content itself is correct; slot_actual_line
    // still matches what's read), just a one-pixel visual seam at network-frame
    // boundaries, same family as (but distinct from) the H_REPL column seam above.
    // Deliberately left as-is - not visible to the eye, and "fixing" it would mean
    // forcing a col-0 restart on every net_frame_start, which fights the raster's own
    // continuous horizontal scan for no real benefit.
    reg de1, hs1, vs1, de2, hs2, vs2;
    reg [15:0] expect_line1, expect_line2;   // sline_frame carried alongside the pipeline
    always @(posedge pix_clk) begin
        if (pix_rst) begin
            r_slot<=0; r_col<=0; de1<=0; hs1<=0; vs1<=0; de2<=0; hs2<=0; vs2<=0;
            de_o<=0; hs_o<=0; vs_o<=0; pix_rgb565<=16'd0;
            expect_line1<=16'd0; expect_line2<=16'd0;
        end else begin
            // stage 1: register the ring address (slot = per-frame line mod NLINES)
            r_slot <= sline_frame[LNSEL_W-1:0];
            r_col  <= scol[COL_W-1:0];
            expect_line1 <= sline_frame;
            de1<=de;   hs1<=hsync; vs1<=vsync;
            // stage 2: ring output reg is latching now; sync rides along
            expect_line2 <= expect_line1;
            de2<=de1;  hs2<=hs1;   vs2<=vs1;
            // stage 3: r_data (and slot_actual_line) now valid for the stage-1 address.
            // If the slot doesn't actually hold the line we addressed, it's stale (a
            // dropped-pixel recovery left it un-rewritten this lap) - hold the LAST
            // pixel instead of showing wrong-lap content as if it were current.
            de_o<=de2; hs_o<=hs2;  vs_o<=vs2;
            if (de2 && slot_actual_line == expect_line2)
                pix_rgb565 <= r_data[15:0];
            else if (!de2)
                pix_rgb565 <= 16'd0;
            // else: stale slot - hold previous pix_rgb565 value (no assignment)
        end
    end
endmodule

`default_nettype wire
