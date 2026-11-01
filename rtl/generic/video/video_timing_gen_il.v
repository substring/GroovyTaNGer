// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - video timing generator with optional INTERLACE (2:1).
//
// Same counters and outputs as video_timing_gen.v (which stays as it is for the older
// tops), plus `interlace` and `field`. With interlace = 0 it is cycle-for-cycle the
// same progressive raster.
//
// INTERLACE: each "frame" of this generator is one FIELD; vcount counts the field's own
// lines (0 = first active line), frame_start pulses at every field. A 2:1 frame of
// 2*v_total+1 lines (525 for v_total = 262) is split into:
//   field 0 = TOP field    (even source lines 0,2,4..): v_total+1 lines, VSYNC starts and
//             ends half a line late (at hcount = h_total/2)
//   field 1 = BOTTOM field (odd source lines 1,3,5..):  v_total lines, VSYNC line-aligned
// so consecutive VSYNC starts are exactly v_total+0.5 lines apart both ways (top: 263 -
// 243.5 + 243 = 262.5, bottom: 262 - 243 + 243.5 = 262.5 for v_sync_begin = 243). The
// field drawn after the half-line VSYNC starts half a line lower on the tube, which is
// the bottom field, as in CEA-861 480i (field 2 has the mid-line VSYNC and is the lower).
// `field` follows Groovy_MiSTer's VGA_F1 (rtl/vga.v): 0 while even source lines are
// scanned, 1 for odd lines; GroovyMAME picks which lines it sends from it.
//
// `interlace` is sampled at the end of each field, so the raster switches between
// progressive and interlaced only on a field boundary, always starting with the top field.
// The modeline inputs may change at run time; the caller should change them at a frame
// boundary (gwline loads them on frame_start).
`default_nettype none

module video_timing_gen_il (
    input  wire        clk,            // pixel clock (post super-res)
    input  wire        rst,            // sync, active high
    input  wire        en,             // pixel clock enable
    input  wire        interlace,      // 1 = 2:1 interlaced raster (quasi-static)

    // Modeline (latched by caller; treated as stable while running). Vertical values
    // are per FIELD when interlaced (v_total = the shorter field, e.g. 262 for 525).
    input  wire [15:0] h_total,
    input  wire [15:0] h_active,
    input  wire [15:0] h_sync_begin,
    input  wire [15:0] h_sync_end,
    input  wire [15:0] v_total,
    input  wire [15:0] v_active,
    input  wire [15:0] v_sync_begin,
    input  wire [15:0] v_sync_end,
    input  wire        h_sync_pos,     // 1 = active-high hsync
    input  wire        v_sync_pos,     // 1 = active-high vsync

    output reg  [15:0] hcount,
    output reg  [15:0] vcount,
    output wire        hsync,
    output wire        vsync,
    output wire        de,             // data enable (active video region)
    output reg         line_start,     // pulse at first pixel of every line
    output reg         frame_start,    // pulse at first pixel of every frame (= field)
    output reg         field           // 0 = top/even lines, 1 = bottom/odd (0 if progressive)
);
    reg        il;                     // interlace, as latched for the current field
    wire       half_v = il && !field;  // top field: one more line, half-line VSYNC
    wire [15:0] h_mid = {1'b0, h_total[15:1]};

    // The wrap thresholds are REGISTERED (they only change with the modeline or at a
    // field boundary, where vcount is 0 and far from them): computing field -> +1 -> -1
    // -> compare every cycle was the critical path at pix_clk (VIDEO_MODE 4 build).
    // >= rather than ==: the modeline may be reloaded at run time (gwline VIDEO_MODE 4),
    // and a counter already past a smaller new total must wrap, not run to 65535.
    reg  [15:0] h_lim, v_lim;
    always @(posedge clk) begin
        h_lim <= h_total - 16'd1;
        v_lim <= half_v ? v_total : (v_total - 16'd1);
    end
    wire last_h = (hcount >= h_lim);
    wire last_v = (vcount >= v_lim);

    always @(posedge clk) begin
        if (rst) begin
            hcount <= 16'd0;
            vcount <= 16'd0;
            il     <= 1'b0;
            field  <= 1'b0;
        end else if (en) begin
            if (last_h) begin
                hcount <= 16'd0;
                vcount <= last_v ? 16'd0 : (vcount + 16'd1);
                if (last_v) begin
                    il    <= interlace;
                    field <= interlace && il && !field;   // alternate; top first
                end
            end else begin
                hcount <= hcount + 16'd1;
            end
        end
    end

    wire hsync_raw = (hcount >= h_sync_begin) && (hcount < h_sync_end);
    // line-aligned: [v_sync_begin, v_sync_end) whole lines; top field: the same window
    // shifted by half a line, from (v_sync_begin, h_total/2) to (v_sync_end, h_total/2)
    wire vs_on_al  = (vcount >= v_sync_begin) && (vcount < v_sync_end);
    wire vs_on_hl  = ((vcount > v_sync_begin) || (vcount == v_sync_begin && hcount >= h_mid)) &&
                     ((vcount < v_sync_end)   || (vcount == v_sync_end   && hcount <  h_mid));
    wire vsync_raw = half_v ? vs_on_hl : vs_on_al;

    assign hsync = h_sync_pos ? hsync_raw : ~hsync_raw;
    assign vsync = v_sync_pos ? vsync_raw : ~vsync_raw;
    assign de    = (hcount < h_active) && (vcount < v_active);

    // registered pulses, as in video_timing_gen.v (glitch-free for other clock domains)
    always @(posedge clk) begin
        if (rst) begin
            line_start  <= 1'b0;
            frame_start <= 1'b0;
        end else if (en) begin
            line_start  <= last_h;
            frame_start <= last_h && last_v;
        end
    end
endmodule

`default_nettype wire
