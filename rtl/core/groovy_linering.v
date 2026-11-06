// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - beam-race LINE RING, complete: network pixels in, raster pixels out.
//
// This replaces the FIFO + guarded writer + clamped reader + raster_en/have_frame glue
// that used to be spread across gwline_top.sv, groovy_lineram_wr.v and
// groovy_lineram_scan.v (audit 2026-10-11; measured 0% correct lines under a real
// 1.0x continuous stream in sim/tb/groovy_linering_beamrace_tb.sv, define LEGACY).
//
// THE WHOLE CONTRACT, in three rules:
//   1. THE WRITER NEVER WAITS. A pixel that arrives is stored at once, source line L in
//      slot L mod NLINES. The network cannot be paused and blit_rx has no back-pressure,
//      so any writer-side stall only turns "early" into "lost". No FIFO, no guard.
//   2. THE READER NEVER WAITS. It reads the slot of the line the free-running raster is
//      on. The raster is the master clock of the system and is never frozen or re-phased
//      (HDMI sync is present from reset, whether or not a host is streaming).
//   3. A SLOT TAG ARBITRATES. Each slot carries the number of the line it really holds
//      (0xFFFE while being rewritten, 0xFFFF if never written). The reader shows a pixel
//      only when the tag equals the line it wants; otherwise it shows BAD_COLOR. Every
//      way the two sides can disagree - host late (line not there yet), host early (line
//      already overwritten by L+NLINES), mid-rewrite, wrong lap - is the same test.
// Nothing here can deadlock: neither side's progress depends on the other.
//
// Keeping the two sides apart is the HOST's job (it leads the raster by ~NLINES/2 lines,
// see tools/gm_test_sender.py blitrace --lead), using the raster line this module
// reports back (src_line_wr -> ACK vCount). Valid window for 320x240 in 720p, 2 lines
// per datagram at 1.0x: lead-at-line-0 of roughly 10..30 lines (sim sweep in the tb).
//
// Slots run continuously across frames (see groovy_linewr.v), so the ring always holds
// the last NLINES lines written: the previous frame's tail stays readable while the next
// frame's head arrives, which is exactly what a writer leading the raster needs.
//
// STORAGE: COL_W is DERIVED from LINE_W. The old top passed LINE_W=512 with COL_W=10, so
// the {slot,col} address was 15 bits into a 16384-word memory: synthesis dropped every
// write with slot[4]=1 and aliased every such read onto slot-16 (visible in the
// gwsynthesis netlist: CEA gated by rw_slot[4], ADB = {r_slot[3:0], r_col}). The ring was
// physically 16 lines and half of all source lines were never stored.
`default_nettype none

module groovy_linering #(
    parameter integer NLINES    = 32,          // ring depth, source lines (power of two)
    parameter integer LINE_W    = 512,         // columns stored per slot (power of two)
    parameter integer DATA_W    = 16,
    parameter integer H_SH      = 2,           // log2(horizontal replicate)
    parameter integer V_REPL    = 3,           // vertical replicate
    parameter integer DYN_H     = 0,           // 1: horizontal replicate = h_rep input
    parameter [DATA_W-1:0] BAD_COLOR = {DATA_W{1'b0}}   // shown for a line not in the ring
) (
    // ---------------- write side (network clock) ----------------
    input  wire                wr_clk,
    input  wire                wr_rst,        // sync; also re-clears every slot tag
    input  wire                frame_start,   // pulse: next pixel is (line 0, col 0)
    input  wire                px_we,         // one assembled pixel
    input  wire [DATA_W-1:0]   px_data,
    input  wire [15:0]         native_w,      // source pixels per line (<= LINE_W)
    output wire [15:0]         write_line,    // lines completed in the current frame
    output wire [15:0]         src_line_wr,   // raster source line, synchronised here
    output reg  [15:0]         lead_top,      // write_line seen when the raster hit line 0

    // ---------------- read side (pixel clock) ----------------
    input  wire                pix_clk,
    input  wire                pix_rst,
    input  wire [15:0]         hcount,
    input  wire [3:0]          h_rep,         // DYN_H only (tie to 1 otherwise)
    input  wire [15:0]         vcount,
    input  wire                de,
    input  wire                hsync,
    input  wire                vsync,
    input  wire                vframe_start,  // raster top-of-frame pulse
    output wire [DATA_W-1:0]   pix,
    output wire                de_o,
    output wire                hs_o,
    output wire                vs_o,
    output wire [9:0]          good_lines,    // output lines fully valid, last video frame
    output wire [9:0]          bad_first,     // last bad video frame: see groovy_linescan.v
    output wire [9:0]          bad_last,
    output wire [9:0]          bad_early,
    output wire [9:0]          bad_late,
    output wire [9:0]          bad_wr
);
    localparam integer LNSEL_W = $clog2(NLINES);
    localparam integer COL_W   = $clog2(LINE_W);

    // ---- writer ----
    wire                 w_we;
    wire [LNSEL_W-1:0]   w_slot;
    wire [COL_W-1:0]     w_col;
    wire [DATA_W-1:0]    w_data;
    wire                 t_we;
    wire [LNSEL_W-1:0]   t_slot;
    wire [15:0]          t_line;
    wire [LNSEL_W-1:0]   base_wr;
    groovy_linewr #(.NLINES(NLINES), .LNSEL_W(LNSEL_W), .COL_W(COL_W), .DATA_W(DATA_W)) u_wr (
        .clk(wr_clk), .rst(wr_rst), .frame_start(frame_start),
        .px_we(px_we), .px_data(px_data), .native_w(native_w),
        .we(w_we), .w_slot(w_slot), .w_col(w_col), .w_data(w_data),
        .tag_we(t_we), .tag_slot(t_slot), .tag_line(t_line),
        .write_line(write_line), .frame_base(base_wr));

    // frame_base -> pixel clock. It changes once per network frame and is only LATCHED
    // at the raster's top-of-frame, a host-lead (>= several hundred microseconds) later,
    // so a plain two-flop bus synchroniser is sufficient: the value is long settled by
    // the time it is used. (If the host has no lead at all the picture is invalid for
    // that frame anyway, and the tags blank it.)
    (* ASYNC_REG = "TRUE" *) reg [LNSEL_W-1:0] base_p1, base_p2;
    always @(posedge pix_clk) begin base_p1 <= base_wr; base_p2 <= base_p1; end

    // ---- storage: pixels + per-slot tag (both: write wr_clk, registered read pix_clk) ----
    wire [LNSEL_W-1:0]   r_slot;
    wire [COL_W-1:0]     r_col;
    wire [DATA_W-1:0]    r_data;
    wire [15:0]          r_tag;
    groovy_lineram #(.NLINES(NLINES), .LINE_W(LINE_W), .DATA_W(DATA_W),
                     .LNSEL_W(LNSEL_W), .COL_W(COL_W)) u_ring (
        .wr_clk(wr_clk), .we(w_we), .w_slot(w_slot), .w_col(w_col), .w_data(w_data),
        .rd_clk(pix_clk), .r_slot(r_slot), .r_col(r_col), .r_data(r_data));
    groovy_slotline_ram #(.NLINES(NLINES), .LNSEL_W(LNSEL_W)) u_tags (
        .wr_clk(wr_clk), .we(t_we), .w_slot(t_slot), .w_line(t_line),
        .rd_clk(pix_clk), .r_slot(r_slot), .r_line(r_tag));

    // ---- reader ----
    wire [15:0] src_line;
    groovy_linescan #(.LNSEL_W(LNSEL_W), .COL_W(COL_W), .DATA_W(DATA_W),
                      .H_SH(H_SH), .V_REPL(V_REPL), .DYN_H(DYN_H), .BAD_COLOR(BAD_COLOR)) u_scan (
        .pix_clk(pix_clk), .pix_rst(pix_rst),
        .hcount(hcount), .h_rep(h_rep), .vcount(vcount), .de(de), .hsync(hsync), .vsync(vsync),
        .vframe_start(vframe_start), .frame_base(base_p2),
        .r_slot(r_slot), .r_col(r_col), .r_data(r_data), .r_tag(r_tag),
        .pix(pix), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o),
        .src_line(src_line), .good_lines(good_lines),
        .bad_first(bad_first), .bad_last(bad_last),
        .bad_early(bad_early), .bad_late(bad_late), .bad_wr(bad_wr));

    // ---- raster line -> write clock, Gray coded ----
    // src_line steps by one, so one Gray bit changes per step and a sample taken on the
    // edge resolves to the old or the new line, never to garbage. (The once-per-frame
    // wrap back to 0 is not a single-bit step; it is 30 lines into vertical blanking and
    // only feeds status, not the data path.)
    reg  [15:0] sl_gray;
    always @(posedge pix_clk) sl_gray <= src_line ^ (src_line >> 1);
    (* ASYNC_REG = "TRUE" *) reg [15:0] sl_g1, sl_g2;
    always @(posedge wr_clk) begin sl_g1 <= sl_gray; sl_g2 <= sl_g1; end
    reg [15:0] sl_bin;
    integer gi;
    always @(*) begin
        sl_bin[15] = sl_g2[15];
        for (gi = 14; gi >= 0; gi = gi - 1) sl_bin[gi] = sl_bin[gi+1] ^ sl_g2[gi];
    end
    reg [15:0] sl_wr, sl_wr_q;
    always @(posedge wr_clk) begin
        sl_wr   <= sl_bin;
        sl_wr_q <= sl_wr;
        // host-lead probe: where the writer is when the raster starts source line 0.
        // ~NLINES/2 = healthy; near 0 = host late; near NLINES = host too early.
        if (wr_rst) lead_top <= 16'd0;
        else if (sl_wr == 16'd0 && sl_wr_q != 16'd0) lead_top <= write_line;
    end
    assign src_line_wr = sl_wr;
endmodule

`default_nettype wire
