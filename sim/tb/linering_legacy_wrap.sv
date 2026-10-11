// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - LEGACY line-ring glue, lifted verbatim from gwline_top.sv as of commit
// 7d502d7 (elastic FIFO -> groovy_lineram_wr slot-modulo guard -> ring -> clamped
// groovy_lineram_scan, raster_en/have_frame start-up). Exists ONLY so
// groovy_linering_beamrace_tb.sv can measure the old design against the new
// groovy_linering under the identical stimulus and checker (define LEGACY). Not used by
// any board top.
`default_nettype none

module linering_legacy_wrap #(
    parameter integer COL_W = 10      // 10 = as shipped (ring storage bug), 9 = corrected
) (
    input  wire        clk50m,
    input  wire        rst50,
    input  wire        frame_start,     // blit_valid
    input  wire        px_we,
    input  wire [15:0] px_data,
    input  wire        pix_clk,
    input  wire        hdmi_rst_n,
    output wire [15:0] hcount,
    output wire [15:0] vcount,
    output wire        de,
    output wire        vframe_start,
    output wire [15:0] pix565,
    output wire        de_o,
    output wire [15:0] write_line,
    output reg  [31:0] ovf_count
);
    localparam integer NLINES = 32, LNSEL_W = 5, LINE_W = 512, MARGIN = 16;
    localparam integer START_THRESHOLD = 16;
    localparam [15:0] SRC_W = 16'd320;

    wire        fifo_full, fifo_empty, fifo_overflow, mapper_pop;
    wire [15:0] fifo_head;
    wire [12:0] fifo_level;
    groovy_sync_fifo #(.DATA_W(16), .ADDR_W(12)) u_wr_fifo (
        .clk(clk50m), .rst(rst50),
        .wr_en(px_we), .wr_data(px_data), .full(fifo_full),
        .rd_en(mapper_pop), .rd_data(fifo_head), .empty(fifo_empty),
        .overflow(fifo_overflow), .fifo_level(fifo_level));
    always @(posedge clk50m) if (rst50) ovf_count <= 0; else if (fifo_overflow) ovf_count <= ovf_count + 1;

    wire [15:0] scan_srcline, scan_readguard;
    logic       have_frame;
    logic [15:0] wline_px;
    always_ff @(posedge pix_clk) wline_px <= write_line;

    logic raster_en;
    always_ff @(posedge pix_clk or negedge hdmi_rst_n)
        if (!hdmi_rst_n) raster_en <= 1'b0;
        else if (wline_px >= START_THRESHOLD[15:0]) raster_en <= 1'b1;

    logic [1:0] rasteren_50;  logic [15:0] read_line_50;
    always_ff @(posedge clk50m) begin
        rasteren_50  <= {rasteren_50[0], raster_en};
        read_line_50 <= rasteren_50[1] ? scan_readguard : 16'd0;
    end

    wire        rw_we;  wire [LNSEL_W-1:0] rw_slot;  wire [COL_W-1:0] rw_col;
    wire [15:0] rw_data;  wire rw_stall;
    wire        sl_we;  wire [LNSEL_W-1:0] sl_slot;  wire [15:0] sl_line;
    groovy_lineram_wr #(.NLINES(NLINES), .LNSEL_W(LNSEL_W), .COL_W(COL_W), .DATA_W(16),
                        .MARGIN(MARGIN), .ADDR_W_FIFO(12)) u_lrw (
        .clk(clk50m), .rst(rst50), .frame_start(frame_start),
        .in_valid(~fifo_empty), .in_data(fifo_head), .pop(mapper_pop), .native_w(SRC_W),
        .fifo_overflow(fifo_overflow), .fifo_level(fifo_level),
        .read_line(read_line_50), .guard_en(rasteren_50[1]),
        .we(rw_we), .w_slot(rw_slot), .w_col(rw_col), .w_data(rw_data),
        .write_line(write_line), .stall(rw_stall),
        .sl_we(sl_we), .sl_slot(sl_slot), .sl_line(sl_line),
        .target_slot_at_write(), .fifo_level_at_write(),
        .cur_line(), .guard_stuck_cycles());

    wire [LNSEL_W-1:0] r_slot;  wire [COL_W-1:0] r_col;  wire [15:0] r_data;
    groovy_lineram #(.NLINES(NLINES), .LINE_W(LINE_W), .DATA_W(16),
                     .LNSEL_W(LNSEL_W), .COL_W(COL_W)) u_ring (
        .wr_clk(clk50m), .we(rw_we), .w_slot(rw_slot), .w_col(rw_col), .w_data(rw_data),
        .rd_clk(pix_clk), .r_slot(r_slot), .r_col(r_col), .r_data(r_data));

    wire [15:0] slot_actual_line;
    groovy_slotline_ram #(.NLINES(NLINES), .LNSEL_W(LNSEL_W)) u_slotline (
        .wr_clk(clk50m), .we(sl_we), .w_slot(sl_slot), .w_line(sl_line),
        .rd_clk(pix_clk), .r_slot(r_slot), .r_line(slot_actual_line));

    wire hsync, vsync, line_start;
    video_timing_gen u_timing (
        .clk(pix_clk), .rst(~hdmi_rst_n), .en(raster_en),
        .h_total(16'd1650), .h_active(16'd1280), .h_sync_begin(16'd1390), .h_sync_end(16'd1430),
        .v_total(16'd750),  .v_active(16'd720),  .v_sync_begin(16'd725),  .v_sync_end(16'd730),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),
        .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de),
        .line_start(line_start), .frame_start(vframe_start));

    logic blit_valid_tgl;
    always_ff @(posedge clk50m)
        if (rst50) blit_valid_tgl <= 1'b0;
        else if (frame_start) blit_valid_tgl <= ~blit_valid_tgl;
    logic [2:0] blit_valid_tgl_px;
    always_ff @(posedge pix_clk) blit_valid_tgl_px <= {blit_valid_tgl_px[1:0], blit_valid_tgl};
    wire net_frame_start = blit_valid_tgl_px[2] ^ blit_valid_tgl_px[1];

    always_ff @(posedge pix_clk or negedge hdmi_rst_n)
        if (!hdmi_rst_n) have_frame <= 1'b0;
        else if (raster_en && vframe_start) have_frame <= 1'b1;

    wire hs_o, vs_o;
    groovy_lineram_scan #(.NLINES(NLINES), .LINE_W(LINE_W), .DATA_W(16),
                          .LNSEL_W(LNSEL_W), .COL_W(COL_W), .H_REPL(4), .H_SH(2),
                          .V_REPL(3), .SRC_H(240)) u_scan (
        .pix_clk(pix_clk), .pix_rst(~hdmi_rst_n | ~have_frame),
        .hcount(hcount), .vcount(vcount), .de(de), .hsync(hsync), .vsync(vsync),
        .frame_start(vframe_start | net_frame_start),
        .max_line(wline_px),
        .r_slot(r_slot), .r_col(r_col), .r_data(r_data),
        .slot_actual_line(slot_actual_line),
        .pix_rgb565(pix565), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o),
        .src_line(scan_srcline), .read_guard(scan_readguard));
endmodule

`default_nettype wire
