// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - dynamic (modeline-driven) video timing generator (spec section 6.2/Phase 3).
//
// All timing parameters are *input signals*, not synthesis parameters, so the
// same instance retimes to any modeline received over CMD_SWITCHRES. This is the
// key requirement from spec Phase 3 ("rendre les parametres de timing dynamiques")
// and addresses Limit 1 of the vendored HDMI module (spec section 6.5).
//
// Counter layout per Groovy_MiSTer modeline fields:
//   active     : hcount in [0, h_active)
//   front porch: [h_active, h_sync_begin)
//   sync       : [h_sync_begin, h_sync_end)
//   back porch : [h_sync_end, h_total)
// (same structure vertically).
`default_nettype none

module video_timing_gen (
    input  wire        clk,            // pixel clock (post super-res)
    input  wire        rst,            // sync, active high
    input  wire        en,             // pixel clock enable

    // Modeline (latched by caller; treated as stable while running)
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
    output wire        line_start,     // pulse at first pixel of every line
    output wire        frame_start     // pulse at first pixel of every frame
);
    wire last_h = (hcount == h_total - 16'd1);
    wire last_v = (vcount == v_total - 16'd1);

    always @(posedge clk) begin
        if (rst) begin
            hcount <= 16'd0;
            vcount <= 16'd0;
        end else if (en) begin
            if (last_h) begin
                hcount <= 16'd0;
                vcount <= last_v ? 16'd0 : (vcount + 16'd1);
            end else begin
                hcount <= hcount + 16'd1;
            end
        end
    end

    wire hsync_raw = (hcount >= h_sync_begin) && (hcount < h_sync_end);
    wire vsync_raw = (vcount >= v_sync_begin) && (vcount < v_sync_end);

    assign hsync = h_sync_pos ? hsync_raw : ~hsync_raw;
    assign vsync = v_sync_pos ? vsync_raw : ~vsync_raw;
    assign de    = (hcount < h_active) && (vcount < v_active);

    assign line_start  = (hcount == 16'd0);
    assign frame_start = (hcount == 16'd0) && (vcount == 16'd0);
endmodule

`default_nettype wire
