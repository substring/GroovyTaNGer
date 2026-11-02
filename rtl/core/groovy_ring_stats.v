// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - per-frame health of the beam-race line ring (debug only, UART).
//
// lead_top (groovy_linering) is one unsigned value, read a few times per second: a frame
// that starts late reads as the previous frame's height. This module looks at EVERY frame
// and keeps the lead signed, from where the raster is when the host's frame starts:
//
//   frame start at raster line B, last raster line V:
//     B in the upper half: lead = V + 1 - B  > 0, the frame scanned from the next top
//     B in the lower half: lead = -B        <= 0, the frame being scanned, already late
//
// (V is measured, so it follows any modeline; interlaced, it is the field's own count.)
// lead_min / lead_max cover the frames since the last window_clear pulse. A frame shown
// with fewer good lines than expected is counted in bad_frames and in ONE cause:
//   late_frames   lead <= 0 or no frame start at all: the writer stays behind the raster
//   early_frames  lead >= NLINES-1: the writer overwrites slots before they are read
//   other_frames  the lead was fine: something else (lost datagram...)
// All of it restarts with rst (CMD_INIT, CMD_SWITCHRES: a mode change is not a fault).
// Pacing makes the writer and the raster run at the same speed, so an error at the top of
// the frame lasts for the whole frame: this is why one late line can black out a picture.
`default_nettype none

module groovy_ring_stats #(
    parameter integer NLINES = 32,
    parameter integer SETTLE = 64           // clk cycles for good_lines to cross domains
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               frame_start,  // host frame starts (pulse)
    input  wire [15:0]        raster_line,  // raster source line, synchronised to clk
    input  wire [9:0]         good_lines,   // good output lines of the last video frame
    input  wire [9:0]         want_lines,   // output lines of a complete picture
    input  wire               window_clear, // pulse: restart lead_min / lead_max

    output reg  signed [15:0] lead_min,
    output reg  signed [15:0] lead_max,
    output reg  [15:0]        bad_frames,
    output reg  [15:0]        late_frames,
    output reg  [15:0]        early_frames,
    output reg  [15:0]        other_frames
);
    localparam signed [15:0] MIN_INIT = 16'sh7FFF, MAX_INIT = -16'sh8000;

    reg  [15:0] line_q;
    wire        top = (raster_line == 16'd0) && (line_q != 16'd0);   // raster wrapped
    reg  [15:0] v_last;                                              // last raster line
    wire        upper = (raster_line >= {1'b0, v_last[15:1]});
    wire signed [15:0] lead_now = upper ? $signed(v_last + 16'd1 - raster_line)
                                        : -$signed(raster_line);

    // the frame scanned now, and the one announced for the next top
    reg signed [15:0] lead_cur, lead_next, lead_eval;
    reg               have_cur, have_next, have_eval, seen_prev, seen_eval;
    reg  [7:0]        settle;
    wire              bad = (good_lines != want_lines);

    always @(posedge clk) begin
        line_q <= raster_line;
        if (rst) begin
            v_last <= 16'd0;  settle <= 8'd0;
            lead_cur <= 16'sd0;  lead_next <= 16'sd0;  lead_eval <= 16'sd0;
            have_cur <= 1'b0;  have_next <= 1'b0;  have_eval <= 1'b0;
            seen_prev <= 1'b0;  seen_eval <= 1'b0;
            lead_min <= MIN_INIT;  lead_max <= MAX_INIT;
            bad_frames <= 16'd0;  late_frames <= 16'd0;
            early_frames <= 16'd0;  other_frames <= 16'd0;
        end else begin
            if (window_clear) begin lead_min <= MIN_INIT;  lead_max <= MAX_INIT; end

            if (top) begin
                v_last <= line_q;
                // the video frame that just ended, judged once good_lines has arrived
                lead_eval <= lead_cur;  have_eval <= have_cur;  seen_eval <= seen_prev;
                settle    <= SETTLE[7:0];
                seen_prev <= have_cur;
                lead_cur  <= lead_next;  have_cur <= have_next;  have_next <= 1'b0;
            end

            if (frame_start && v_last != 16'd0) begin
                if (lead_now > 16'sd0) begin
                    lead_next <= lead_now;  have_next <= 1'b1;
                end else begin
                    lead_cur  <= lead_now;  have_cur  <= 1'b1;
                end
                if (lead_now < (window_clear ? MIN_INIT : lead_min)) lead_min <= lead_now;
                if (lead_now > (window_clear ? MAX_INIT : lead_max)) lead_max <= lead_now;
            end

            if (settle != 8'd0) begin
                settle <= settle - 8'd1;
                // no frame in this video frame nor the last one = no stream, not a fault
                if (settle == 8'd1 && bad && (have_eval || seen_eval)) begin
                    bad_frames <= bad_frames + 16'd1;
                    if (!have_eval || lead_eval <= 16'sd0)
                        late_frames  <= late_frames + 16'd1;
                    else if (lead_eval >= NLINES - 1)
                        early_frames <= early_frames + 16'd1;
                    else
                        other_frames <= other_frames + 16'd1;
                end
            end
        end
    end
endmodule

`default_nettype wire
