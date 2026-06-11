// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - DYNAMIC HDMI video bring-up (Rung 4b step 2).
//
// A timer cycles 720p <-> 480p; the monitor should switch resolution every
// ~1.5 s, still showing our color bars.
//
//   rpll_sel_encode(idiv/fbdiv/odiv) -> IDSEL/FBDSEL/ODSEL
//   rpll_tmds_dyn -> serial_clk -> CLKDIV/5 -> pix_clk
//   video_timing_gen(modeline) -> de/hs/vs -> test_pattern_gen -> DVI_TX -> HDMI
//
// Hard-won notes:
//  * The rPLL's LOCK does NOT assert in dynamic mode (Gowin quirk) even though
//    the clock is correct (proven: groovy_pll_test_top shows 720p). So never gate
//    on LOCK - CLKDIV.RESETN=I_rst_n and the FSM uses a fixed settle.
//  * The mode parameters are COMBINATIONAL off mode_idx (no task / no reg-init to
//    depend on) - an earlier load_mode() task writing the selects didn't take, so
//    the selects were garbage -> VCO out of range -> no clock -> no picture.
`default_nettype none

module groovy_video_dyn_top (
    input  wire        I_clk,        // 27 MHz, H11
    input  wire        I_rst_n,      // active-low, T10
    output wire [3:0]  O_led,
    output wire        O_tmds_clk_p,
    output wire        O_tmds_clk_n,
    output wire [2:0]  O_tmds_data_p,
    output wire [2:0]  O_tmds_data_n
);
    localparam [27:0] DWELL  = 28'd162_000_000;  // ~6 s per mode (let the monitor
                                                 // fully sync each mode before switching)
    localparam [15:0] SETTLE0= 16'd60000;        // ~2.2 ms after a divider change
    localparam [15:0] SETTLE = 16'd4096;
    localparam [15:0] CHG    = 16'd512;

    // ---- mode select (COMBINATIONAL off mode_idx) ----
    reg mode_idx = 1'b0;
    wire m0 = (mode_idx == 1'b0);
    wire [6:0]  m_idiv  = m0 ? 7'd4    : 7'd3;
    wire [6:0]  m_fbdiv = m0 ? 7'd55   : 7'd14;
    wire [7:0]  m_odiv  = m0 ? 8'd2    : 8'd4;
    wire [15:0] m_htot  = m0 ? 16'd1650: 16'd800;
    wire [15:0] m_hact  = m0 ? 16'd1280: 16'd640;
    wire [15:0] m_hsb   = m0 ? 16'd1390: 16'd656;
    wire [15:0] m_hse   = m0 ? 16'd1430: 16'd752;
    wire [15:0] m_vtot  = m0 ? 16'd750 : 16'd525;
    wire [15:0] m_vact  = m0 ? 16'd720 : 16'd480;
    wire [15:0] m_vsb   = m0 ? 16'd725 : 16'd490;
    wire [15:0] m_vse   = m0 ? 16'd730 : 16'd492;
    wire        m_hpos  = m0 ? 1'b1    : 1'b0;
    wire        m_vpos  = m0 ? 1'b1    : 1'b0;
    wire [11:0] m_pacth = m0 ? 12'd1280: 12'd640;
    wire [11:0] m_pactv = m0 ? 12'd720 : 12'd480;

    // ---- reconfig FSM (27 MHz, fixed settle - no LOCK dependence) ----
    reg [27:0] dwell_cnt = 0;
    reg [15:0] cnt = 0;
    reg [1:0]  state = S_WAIT;
    reg        video_rst = 1'b1;
    localparam S_WAIT=0, S_SETTLE=1, S_RUN=2, S_CHANGE=3;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            state<=S_WAIT; mode_idx<=1'b0; dwell_cnt<=0; cnt<=0; video_rst<=1'b1;
        end else begin
            case (state)
                S_WAIT:   begin video_rst<=1'b1;
                    if (cnt>=SETTLE0) begin cnt<=0; state<=S_SETTLE; end
                    else cnt<=cnt+16'd1; end
                S_SETTLE: if (cnt>=SETTLE) begin cnt<=0; dwell_cnt<=0; state<=S_RUN; end
                          else cnt<=cnt+16'd1;
                S_RUN:    begin video_rst<=1'b0;
                    if (dwell_cnt>=DWELL) begin
                        mode_idx<=~mode_idx; video_rst<=1'b1; cnt<=0; state<=S_CHANGE;
                    end else dwell_cnt<=dwell_cnt+28'd1; end
                S_CHANGE: if (cnt>=CHG) begin cnt<=0; state<=S_WAIT; end
                          else cnt<=cnt+16'd1;
            endcase
        end
    end

    // ---- clocks ----
    wire [5:0] idsel, fbdsel, odsel;
    rpll_sel_encode u_enc (.idiv(m_idiv), .fbdiv(m_fbdiv), .odiv(m_odiv),
                           .idsel(idsel), .fbdsel(fbdsel), .odsel(odsel));

    wire serial_clk, pix_clk, pll_lock;
    rpll_tmds_dyn u_pll (.clkin(I_clk), .reset(~I_rst_n),
                         .idsel(idsel), .fbdsel(fbdsel), .odsel(odsel),
                         .clkout(serial_clk), .lock(pll_lock));

    CLKDIV u_div (.RESETN(I_rst_n), .HCLKIN(serial_clk), .CLKOUT(pix_clk), .CALIB(1'b1));
    defparam u_div.DIV_MODE="5"; defparam u_div.GSREN="false";

    // ---- video ----
    wire        de, hsync, vsync;
    wire [15:0] hcount, vcount;
    video_timing_gen u_timing (
        .clk(pix_clk), .rst(video_rst), .en(1'b1),
        .h_total(m_htot), .h_active(m_hact), .h_sync_begin(m_hsb), .h_sync_end(m_hse),
        .v_total(m_vtot), .v_active(m_vact), .v_sync_begin(m_vsb), .v_sync_end(m_vse),
        .h_sync_pos(m_hpos), .v_sync_pos(m_vpos),
        .hcount(hcount), .vcount(vcount), .hsync(hsync), .vsync(vsync), .de(de),
        .line_start(), .frame_start());

    wire [7:0] r, g, b;
    test_pattern_gen u_pat (.h_act(m_pacth), .v_act(m_pactv),
        .hcount(hcount), .vcount(vcount), .de(de), .r(r), .g(g), .b(b));

    DVI_TX_Top u_dvi (
        .I_rst_n(~video_rst), .I_serial_clk(serial_clk), .I_rgb_clk(pix_clk),
        .I_rgb_vs(vsync), .I_rgb_hs(hsync), .I_rgb_de(de),
        .I_rgb_r(r), .I_rgb_g(g), .I_rgb_b(b),
        .O_tmds_clk_p(O_tmds_clk_p),   .O_tmds_clk_n(O_tmds_clk_n),
        .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n));

    // led0 = pix_clk alive, led1 = mode, led2 = running, led3 = heartbeat
    reg [24:0] hb = 0;
    always @(posedge I_clk or negedge I_rst_n)
        if (!I_rst_n) hb<=0; else hb<=hb+25'd1;
    reg [24:0] pc = 0;
    always @(posedge pix_clk) pc <= pc + 25'd1;
    assign O_led = ~{hb[24], (state==S_RUN), mode_idx, pc[24]};
endmodule

`default_nettype wire
