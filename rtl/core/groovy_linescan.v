// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - line-ring scanout (see groovy_linering.v for the contract).
//
// Follows the raster and nothing else: source line = vcount / V_REPL, source column =
// hcount >> H_SH, or with DYN_H = 1, hcount / h_rep for a replicate factor given at run
// time (any N, from the SWITCHRES modeline; counted, not divided). There is no clamp against the writer and no re-phasing on network
// events; whether the addressed slot really holds the wanted line is decided per pixel
// by the slot tag that comes back alongside the data.
//
// Pipeline (unchanged from the HW-proven scaler): address register -> BRAM output
// register -> pixel register, so de/hs/vs are delayed by the same three stages.
`default_nettype none

module groovy_linescan #(
    parameter integer LNSEL_W = 5,
    parameter integer COL_W   = 9,
    parameter integer DATA_W  = 16,
    parameter integer H_SH    = 2,
    parameter integer V_REPL  = 3,
    parameter integer DYN_H   = 0,        // 1: horizontal replicate from h_rep (run time)
    parameter [DATA_W-1:0] BAD_COLOR = {DATA_W{1'b0}}
) (
    input  wire                 pix_clk,
    input  wire                 pix_rst,
    input  wire [15:0]          hcount,
    input  wire [3:0]           h_rep,        // DYN_H: output pixels per source pixel (>= 1)
    input  wire [15:0]          vcount,
    input  wire                 de,
    input  wire                 hsync,
    input  wire                 vsync,
    input  wire                 vframe_start,
    input  wire [LNSEL_W-1:0]   frame_base,   // slot of line 0 of the frame the host is
                                              // sending (already in this clock domain)

    output reg  [LNSEL_W-1:0]   r_slot,
    output reg  [COL_W-1:0]     r_col,
    input  wire [DATA_W-1:0]    r_data,
    input  wire [15:0]          r_tag,

    output reg  [DATA_W-1:0]    pix,
    output reg                  de_o,
    output reg                  hs_o,
    output reg                  vs_o,

    output wire [15:0]          src_line,     // raster source line (host phase-lock)
    output reg  [9:0]           good_lines,   // output lines fully valid, last frame

    // Where and why the LAST BAD video frame was wrong (kept until the next bad frame):
    // first and last bad source line, and how many bad output lines of each kind, judged
    // by the tag found on the first bad pixel of the line (want = line N):
    //   early: tag in N+1..N+63, the slot already holds a later line (N+32 overwrote N)
    //   late:  any other line number (N-32, or the previous frame's line): N not there yet
    //   wr:    0xFFFE / 0xFFFF, slot being rewritten at that moment / never written
    output reg  [9:0]           bad_first,
    output reg  [9:0]           bad_last,
    output reg  [9:0]           bad_early,
    output reg  [9:0]           bad_late,
    output reg  [9:0]           bad_wr
);
    wire [15:0] sline = (V_REPL == 1) ? vcount :
                        (V_REPL == 2) ? (vcount >> 1) :
                        (V_REPL == 4) ? (vcount >> 2) :
                                        vcount / V_REPL[15:0];
    // DYN_H: a column counter that steps every h_rep output pixels and restarts with the
    // line (hcount == 0). It assumes hcount advances by one per pix_clk, which the free-
    // running raster guarantees; cur_* are the values FOR the current hcount.
    reg  [15:0] dc_q;  reg [3:0] dr_q;
    wire [15:0] dc_cur = (hcount == 16'd0) ? 16'd0 : dc_q;
    wire [3:0]  dr_cur = (hcount == 16'd0) ? 4'd0  : dr_q;
    always @(posedge pix_clk)
        if (dr_cur + 4'd1 >= h_rep) begin dc_q <= dc_cur + 16'd1; dr_q <= 4'd0; end
        else                        begin dc_q <= dc_cur;         dr_q <= dr_cur + 4'd1; end
    wire [15:0] scol  = DYN_H ? dc_cur : (hcount >> H_SH);
    assign src_line = sline;

    // The host starts each frame some lines BEFORE the raster wraps (it leads), so by
    // the raster's top-of-frame frame_base has long been stable and names the frame
    // about to be scanned. Latch it there and keep it for the whole video frame - the
    // host will move on to the next frame's base while this one's tail is still shown.
    reg [LNSEL_W-1:0] base;
    always @(posedge pix_clk)
        if (pix_rst) base <= {LNSEL_W{1'b0}};
        else if (vframe_start) base <= frame_base;
    wire [LNSEL_W-1:0] base_now = vframe_start ? frame_base : base;

    reg        de1, hs1, vs1, de2, hs2, vs2;
    reg [15:0] want1, want2;                 // the line each pipeline stage asked for
    wire       tag_ok = (r_tag == want2);

    always @(posedge pix_clk) begin
        if (pix_rst) begin
            r_slot <= {LNSEL_W{1'b0}}; r_col <= {COL_W{1'b0}};
            de1 <= 1'b0; hs1 <= 1'b0; vs1 <= 1'b0;
            de2 <= 1'b0; hs2 <= 1'b0; vs2 <= 1'b0;
            de_o <= 1'b0; hs_o <= 1'b0; vs_o <= 1'b0;
            pix <= {DATA_W{1'b0}}; want1 <= 16'd0; want2 <= 16'd0;
        end else begin
            r_slot <= base_now + sline[LNSEL_W-1:0];
            r_col  <= scol[COL_W-1:0];
            want1  <= sline;
            de1 <= de;   hs1 <= hsync; vs1 <= vsync;

            want2 <= want1;
            de2 <= de1;  hs2 <= hs1;   vs2 <= vs1;

            de_o <= de2; hs_o <= hs2;  vs_o <= vs2;
            pix  <= !de2 ? {DATA_W{1'b0}} : tag_ok ? r_data : BAD_COLOR;
        end
    end

    // Health probe: how many of the frame's output lines had a valid tag on every pixel.
    // v_active means the stream is healthy; this is the number to read over the UART
    // instead of judging the screen by eye.
    reg       line_bad;
    reg [9:0] good_cnt;
    // kind of the line's first bad pixel: 0 late, 1 early, 2 wr
    wire [15:0] tag_ahead = r_tag - want2;
    wire [1:0]  kind_now  = (r_tag[15:1] == 15'h7FFF)                     ? 2'd2 :
                            (tag_ahead != 16'd0 && tag_ahead < 16'd64)    ? 2'd1 : 2'd0;
    reg  [1:0]  line_kind;
    reg  [9:0]  line_src;
    reg         f_any;
    reg  [9:0]  f_first, f_last, f_early, f_late, f_wr;
    always @(posedge pix_clk) begin
        if (pix_rst) begin
            line_bad <= 1'b0; good_cnt <= 10'd0; good_lines <= 10'd0;
            line_kind <= 2'd0; line_src <= 10'd0;
            f_any <= 1'b0; f_first <= 10'd0; f_last <= 10'd0;
            f_early <= 10'd0; f_late <= 10'd0; f_wr <= 10'd0;
            bad_first <= 10'd0; bad_last <= 10'd0;
            bad_early <= 10'd0; bad_late <= 10'd0; bad_wr <= 10'd0;
        end else begin
            if (de2 && !tag_ok && !line_bad) begin        // first bad pixel of the line
                line_bad  <= 1'b1;
                line_kind <= kind_now;
                line_src  <= want2[9:0];
            end
            if (de_o && !de2) begin                       // output line just ended
                if (!line_bad) good_cnt <= good_cnt + 10'd1;
                else begin
                    if (!f_any) f_first <= line_src;
                    f_any  <= 1'b1;
                    f_last <= line_src;
                    case (line_kind)
                        2'd1:    f_early <= f_early + 10'd1;
                        2'd2:    f_wr    <= f_wr + 10'd1;
                        default: f_late  <= f_late + 10'd1;
                    endcase
                end
                line_bad <= 1'b0;
            end
            if (vframe_start) begin
                good_lines <= good_cnt;
                good_cnt   <= 10'd0;
                if (f_any) begin
                    bad_first <= f_first;  bad_last <= f_last;
                    bad_early <= f_early;  bad_late <= f_late;  bad_wr <= f_wr;
                end
                f_any <= 1'b0;  f_early <= 10'd0;  f_late <= 10'd0;  f_wr <= 10'd0;
            end
        end
    end
endmodule

`default_nettype wire
