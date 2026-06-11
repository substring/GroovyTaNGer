// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - HDMI video bring-up top (Phase 2). Fixed 720p test pattern.
//
// Proves OUR video pipeline (video_timing_gen + test_pattern_gen) through the
// Gowin DVI_TX path on hardware, before adding dynamic timing / super-res /
// network pixels. Structure mirrors Sipeed's proven HDMI example:
//   rpll_tmds (27 MHz -> 371.25 MHz serial) -> CLKDIV/5 -> pix_clk (74.25 MHz)
//   video_timing_gen (720p) -> de/hs/vs/hcount/vcount
//   test_pattern_gen -> rgb
//   DVI_TX_Top (Gowin IP) -> TMDS pairs
//
// DVI_TX_Top is the encrypted Gowin DVI_TX IP - NOT committed; generate it with
// the Gowin IP wizard (or copy the example's), see this dir's README.
`default_nettype none

module groovy_video_top (
    input  wire        I_clk,        // 27 MHz, H11
    input  wire        I_rst_n,      // active-low, T10
    output wire [3:0]  O_led,
    output wire        O_tmds_clk_p,
    output wire        O_tmds_clk_n,
    output wire [2:0]  O_tmds_data_p,
    output wire [2:0]  O_tmds_data_n
);
    // ---- clocks ----
    wire serial_clk, pll_lock, pix_clk;
    rpll_tmds u_pll (.clkin(I_clk), .clkout(serial_clk), .lock(pll_lock));

    wire hdmi_rst_n = I_rst_n & pll_lock;

    CLKDIV u_div (.RESETN(hdmi_rst_n), .HCLKIN(serial_clk), .CLKOUT(pix_clk), .CALIB(1'b1));
    defparam u_div.DIV_MODE = "5";
    defparam u_div.GSREN    = "false";

    // ---- 720p timing (our generator) ----
    wire        de, hsync, vsync;
    wire [15:0] hcount, vcount;
    video_timing_gen u_timing (
        .clk(pix_clk), .rst(~hdmi_rst_n), .en(1'b1),
        .h_total(16'd1650), .h_active(16'd1280), .h_sync_begin(16'd1390), .h_sync_end(16'd1430),
        .v_total(16'd750),  .v_active(16'd720),  .v_sync_begin(16'd725),  .v_sync_end(16'd730),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),
        .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de),
        .line_start(), .frame_start());

    // ---- color bars (our generator) ----
    wire [7:0] r, g, b;
    test_pattern_gen u_pat (
        .h_act(12'd1280), .v_act(12'd720),
        .hcount(hcount), .vcount(vcount), .de(de), .r(r), .g(g), .b(b));

    // ---- Gowin DVI_TX IP (generated; see README) ----
    DVI_TX_Top u_dvi (
        .I_rst_n(hdmi_rst_n),
        .I_serial_clk(serial_clk),
        .I_rgb_clk(pix_clk),
        .I_rgb_vs(vsync), .I_rgb_hs(hsync), .I_rgb_de(de),
        .I_rgb_r(r), .I_rgb_g(g), .I_rgb_b(b),
        .O_tmds_clk_p(O_tmds_clk_p),   .O_tmds_clk_n(O_tmds_clk_n),
        .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n));

    // ---- LEDs: lock + heartbeat (active-low board) ----
    reg [24:0] hb;
    always @(posedge I_clk or negedge I_rst_n)
        if (!I_rst_n) hb <= 25'd0; else hb <= hb + 25'd1;
    assign O_led = ~{2'b00, hb[24], pll_lock};
endmodule

`default_nettype wire
