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
// MONOTONIC read line (the wrap-safe fix): `src_line` is NOT the per-frame raster line
// (which resets to 0 every video frame and would make the write-side guard falsely see a
// huge lead -> the freeze bug). Instead we count video frames and export a monotonic
// index = frame_count*SRC_H + (vcount/V_REPL). The ring SLOT still uses the low bits
// (mod NLINES) so it wraps as intended, but the exported src_line marches on so
// write_line-read_line is always the true small gap. The top CDCs this to clk50m for the
// ring lap-guard and feeds it to the vCount ACK.
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

    // scaled pixel out (RGB565 path) + delayed sync, aligned to the BRAM latency
    output reg  [15:0]          pix_rgb565,
    output reg                  de_o,
    output reg                  hs_o,
    output reg                  vs_o,

    // MONOTONIC source line being scanned (for the ring guard + vCount ACK)
    output wire [15:0]          src_line
);
    // STABLE addressing: the read line is the raster's per-frame source line, derived
    // straight from vcount (0..SRC_H-1, wraps cleanly every video frame). NO monotonic
    // frame counter in the data path - that overflowed 16 bits after ~2s and desynced the
    // clamp, casting garbage. The ring SLOT = sline_frame mod NLINES; the raster always
    // reads "the source line at my current screen position". Phase alignment (writer puts
    // the right line in that slot in time) is a SEPARATE concern (host-mastered, later).
    // max_line is unused here now - kept in the port list for the write-side guard/ACK.
    wire [15:0] sline_frame = (V_REPL == 1) ? vcount :
                              (V_REPL == 2) ? (vcount >> 1) :
                              (V_REPL == 4) ? (vcount >> 2) :
                                              vcount / V_REPL[15:0];
    wire [15:0] scol = hcount >> H_SH;

    // Export the per-frame read line (bounded, never overflows). Informative for the host
    // and the write-side guard; 0 while held in reset (pre-have_frame) for a clean start.
    assign src_line = pix_rst ? 16'd0 : sline_frame;

    // ---- pipeline (3-stage, matched to the TRUE data latency) ----
    // The address -> pixel path has TWO register stages before r_data is right:
    //   T:   scol combinational
    //   T+1: r_col registered here (stage 1) -> feeds the ring address
    //   T+2: the ring's OWN output reg latches mem[{r_slot,r_col}] (r_data valid next)
    //   T+3: r_data now reflects the T+1 address -> present it as pix_rgb565
    // So de/hs/vs must be delayed by 3 to line up with the pixel (an earlier 2-deep delay
    // was one short -> at a barr boundary one output pixel showed the PREVIOUS column's
    // data = the thin dark/blue seam the user saw between colour bars). de1->de2->de_o.
    reg de1, hs1, vs1, de2, hs2, vs2;
    always @(posedge pix_clk) begin
        if (pix_rst) begin
            r_slot<=0; r_col<=0; de1<=0; hs1<=0; vs1<=0; de2<=0; hs2<=0; vs2<=0;
            de_o<=0; hs_o<=0; vs_o<=0; pix_rgb565<=16'd0;
        end else begin
            // stage 1: register the ring address (slot = per-frame line mod NLINES)
            r_slot <= sline_frame[LNSEL_W-1:0];
            r_col  <= scol[COL_W-1:0];
            de1<=de;   hs1<=hsync; vs1<=vsync;
            // stage 2: ring output reg is latching now; sync rides along
            de2<=de1;  hs2<=hs1;   vs2<=vs1;
            // stage 3: r_data now valid for the stage-1 address; present it, sync aligned
            de_o<=de2; hs_o<=hs2;  vs_o<=vs2;
            pix_rgb565 <= de2 ? r_data[15:0] : 16'd0;
        end
    end
endmodule

`default_nettype wire
