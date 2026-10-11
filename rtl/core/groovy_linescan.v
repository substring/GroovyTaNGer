// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - line-ring scanout (see groovy_linering.v for the contract).
//
// Follows the raster and nothing else: source line = vcount / V_REPL, source column =
// hcount >> H_SH. There is no clamp against the writer and no re-phasing on network
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
    parameter [DATA_W-1:0] BAD_COLOR = {DATA_W{1'b0}}
) (
    input  wire                 pix_clk,
    input  wire                 pix_rst,
    input  wire [15:0]          hcount,
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
    output reg  [9:0]           good_lines    // output lines fully valid, last frame
);
    wire [15:0] sline = (V_REPL == 1) ? vcount :
                        (V_REPL == 2) ? (vcount >> 1) :
                        (V_REPL == 4) ? (vcount >> 2) :
                                        vcount / V_REPL[15:0];
    wire [15:0] scol  = hcount >> H_SH;
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
    always @(posedge pix_clk) begin
        if (pix_rst) begin
            line_bad <= 1'b0; good_cnt <= 10'd0; good_lines <= 10'd0;
        end else begin
            if (de2 && !tag_ok) line_bad <= 1'b1;
            if (de_o && !de2) begin                       // output line just ended
                if (!line_bad) good_cnt <= good_cnt + 10'd1;
                line_bad <= 1'b0;
            end
            if (vframe_start) begin
                good_lines <= good_cnt;
                good_cnt   <= 10'd0;
            end
        end
    end
endmodule

`default_nettype wire
