// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - DYNAMIC rPLL isolation test (Rung 4b debug).
//
// Strips away the FSM/encoder: drives rpll_tmds_dyn with HARDCODED 720p selects
// (idsel=60, fbdsel=9, odsel=63 = idiv4/fbdiv55/odiv2, the values the static PLL
// locked on). Goal: does the dynamic rPLL lock + produce a clock at all?
//
//   led[0] = PLL lock          (lit = locked)
//   led[1] = pix_clk alive     (blinks if CLKDIV/serial clock is running)
//   led[2] = serial vs no lock (lit = a clock exists but LOCK never asserted)
//   led[3] = heartbeat (I_clk) (blinks = design alive)
// CLKDIV is NOT gated by lock, so if the PLL emits ANY clock we still see video.
`default_nettype none

module groovy_pll_test_top (
    input  wire        I_clk,
    input  wire        I_rst_n,
    output wire [3:0]  O_led,
    output wire        O_tmds_clk_p,
    output wire        O_tmds_clk_n,
    output wire [2:0]  O_tmds_data_p,
    output wire [2:0]  O_tmds_data_n
);
    wire serial_clk, pix_clk, pll_lock;

    // Hardcoded 720p dynamic selects (= static IDIV_SEL3/FBDIV_SEL54/ODIV_SEL2).
    rpll_tmds_dyn u_pll (
        .clkin(I_clk), .reset(~I_rst_n),
        .idsel(6'd60), .fbdsel(6'd9), .odsel(6'd63),
        .clkout(serial_clk), .lock(pll_lock));

    // NOT gated by lock - run the divider on whatever the PLL emits.
    CLKDIV u_div (.RESETN(I_rst_n), .HCLKIN(serial_clk), .CLKOUT(pix_clk), .CALIB(1'b1));
    defparam u_div.DIV_MODE="5"; defparam u_div.GSREN="false";

    // 720p video on pix_clk (ignore lock so we can see if a clock exists)
    wire        de, hsync, vsync;
    wire [15:0] hcount, vcount;
    video_timing_gen u_timing (
        .clk(pix_clk), .rst(~I_rst_n), .en(1'b1),
        .h_total(16'd1650), .h_active(16'd1280), .h_sync_begin(16'd1390), .h_sync_end(16'd1430),
        .v_total(16'd750),  .v_active(16'd720),  .v_sync_begin(16'd725),  .v_sync_end(16'd730),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),
        .hcount(hcount), .vcount(vcount), .hsync(hsync), .vsync(vsync), .de(de),
        .line_start(), .frame_start());

    wire [7:0] r, g, b;
    test_pattern_gen u_pat (.h_act(12'd1280), .v_act(12'd720),
        .hcount(hcount), .vcount(vcount), .de(de), .r(r), .g(g), .b(b));

    DVI_TX_Top u_dvi (
        .I_rst_n(I_rst_n), .I_serial_clk(serial_clk), .I_rgb_clk(pix_clk),
        .I_rgb_vs(vsync), .I_rgb_hs(hsync), .I_rgb_de(de),
        .I_rgb_r(r), .I_rgb_g(g), .I_rgb_b(b),
        .O_tmds_clk_p(O_tmds_clk_p),   .O_tmds_clk_n(O_tmds_clk_n),
        .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n));

    // heartbeat on I_clk (always alive), and a "pix_clk alive" blinker
    reg [24:0] hb = 0;
    always @(posedge I_clk or negedge I_rst_n)
        if (!I_rst_n) hb <= 0; else hb <= hb + 25'd1;

    reg [24:0] pc = 0;
    always @(posedge pix_clk) pc <= pc + 25'd1;

    // led2 lit when a clock exists (pix toggling) but no lock -> "clock, no lock"
    assign O_led = ~{hb[24], (pc[24] & ~pll_lock), pc[24], pll_lock};
endmodule

`default_nettype wire
