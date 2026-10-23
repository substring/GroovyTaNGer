// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - HDMI-only signal probe (720p, no DDR3, no Ethernet).
//
// Shows, from pure logic, the picture that flickers on the monitor with gwddr3net:
//   top 2/3: a black-to-white grey ramp across the width
//   bottom 1/3: left = (148,0,140) purple, right = (156,60,156) grey-ish
// Colours go through the same RGB565 -> RGB888 expansion as gwddr3net_top, and the same
// clocks / DVI_TX / pins as groovy_video_top. If this picture is stable where gwddr3net's
// flickers, the HDMI link is disturbed by the rest of that design (DDR3, Ethernet);
// if it flickers too, the cause is in this common HDMI path (DVI_TX version, clocks).
`default_nettype none

module hdmi_probe_top (
    input  wire        I_clk,        // 27 MHz, H11
    input  wire        I_rst_n,      // active-low, T10
    output wire [3:0]  O_led,
    output wire        O_tmds_clk_p,
    output wire        O_tmds_clk_n,
    output wire [2:0]  O_tmds_data_p,
    output wire [2:0]  O_tmds_data_n
);
    wire serial_clk, pll_lock, pix_clk;
    rpll_tmds u_pll (.clkin(I_clk), .clkout(serial_clk), .lock(pll_lock));
    wire hdmi_rst_n = I_rst_n & pll_lock;
    CLKDIV u_div (.RESETN(hdmi_rst_n), .HCLKIN(serial_clk), .CLKOUT(pix_clk), .CALIB(1'b1));
    defparam u_div.DIV_MODE = "5";
    defparam u_div.GSREN    = "false";

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

    // RGB565 source pixel, one pipeline stage (registered like the reader's output)
    wire [8:0]  sx   = hcount[10:2];                       // 320-wide source column
    wire [16:0] prod = sx * 8'd205;                        // ~ sx * 255 / 319
    wire [7:0]  v    = prod[15:8];
    reg  [15:0] pix565;
    always @(posedge pix_clk)
        if (vcount < 16'd480) pix565 <= {v[7:3], v[7:2], v[7:3]};
        else if (hcount < 16'd640) pix565 <= 16'h9011;
        else                       pix565 <= 16'h99F3;
    reg de_q, hs_q, vs_q;
    always @(posedge pix_clk) begin de_q <= de; hs_q <= hsync; vs_q <= vsync; end

    wire [7:0] r8 = {pix565[15:11], pix565[15:13]};
    wire [7:0] g8 = {pix565[10:5],  pix565[10:9]};
    wire [7:0] b8 = {pix565[4:0],   pix565[4:2]};

    DVI_TX_Top u_dvi (
        .I_rst_n(hdmi_rst_n),
        .I_serial_clk(serial_clk),
        .I_rgb_clk(pix_clk),
        .I_rgb_vs(vs_q), .I_rgb_hs(hs_q), .I_rgb_de(de_q),
        .I_rgb_r(r8), .I_rgb_g(g8), .I_rgb_b(b8),
        .O_tmds_clk_p(O_tmds_clk_p),   .O_tmds_clk_n(O_tmds_clk_n),
        .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n));

    reg [24:0] hb;
    always @(posedge I_clk or negedge I_rst_n)
        if (!I_rst_n) hb <= 25'd0; else hb <= hb + 25'd1;
    assign O_led = ~{2'b00, hb[24], pll_lock};
endmodule

`default_nettype wire
