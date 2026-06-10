// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - core integration skeleton (spec section 6.2). Board-agnostic.
//
// Wires the pieces of the V1 datapath. The simulation-verified blocks
// (packet parser, ACK sender, PLL solver, mode-change FSM, video timing,
// super-res) are instantiated for real; the hardware/vendor-dependent blocks
// (Ethernet stack, DDR3 ring buffer, LZ4, HDMI) are shown as instantiation
// points with TODOs so the data flow is explicit. This is the assembly target
// of Phase 6/7 - not yet a complete elaboration.
`default_nettype none

module groovy_top (
    input  wire clk_sys,        // from refclk / system PLL
    input  wire rst,

    // ---- to/from board layer ----
    // Ethernet PHY octet stream (eth_phy_gowin), HDMI TMDS pairs, audio, etc.
    // (omitted here; board top connects these)
    input  wire        eth_rx_valid,
    input  wire [7:0]  eth_rx_data,
    input  wire        eth_rx_sop,
    input  wire        eth_rx_eop
);
    // =====================================================================
    // RX: PHY -> MAC -> IPv4/UDP -> {command parser | pixel/audio stream}
    //   TODO(Phase5): eth_mac_rx + eth_ipv4_parser feed the parser with the
    //   32100 data-port control packets, and route header-less pixel/audio
    //   bytes to ring_buffer / sound_buffer while isBlitting (spec 5.3).
    // =====================================================================
    wire        cmd_valid, switchres_valid, init_valid, blit_valid, get_status_valid;
    wire [7:0]  cmd;
    wire [63:0] sr_pclk;
    wire [15:0] sr_h_active, sr_h_begin, sr_h_end, sr_h_total;
    wire [15:0] sr_v_active, sr_v_begin, sr_v_end, sr_v_total;
    wire [7:0]  sr_interlace;
    /* verilator lint_off PINMISSING */
    groovy_packet_parser u_parser (
        .clk(clk_sys), .rst(rst),
        .in_valid(eth_rx_valid), .in_data(eth_rx_data),
        .in_sop(eth_rx_sop), .in_eop(eth_rx_eop),
        .cmd_valid(cmd_valid), .cmd(cmd),
        .switchres_valid(switchres_valid), .init_valid(init_valid),
        .blit_valid(blit_valid), .get_status_valid(get_status_valid),
        .sr_pclk(sr_pclk),
        .sr_h_active(sr_h_active), .sr_h_begin(sr_h_begin), .sr_h_end(sr_h_end),
        .sr_h_total(sr_h_total), .sr_v_active(sr_v_active), .sr_v_begin(sr_v_begin),
        .sr_v_end(sr_v_end), .sr_v_total(sr_v_total), .sr_interlace(sr_interlace)
    );

    // =====================================================================
    // Mode change: SWITCHRES -> solver -> rPLL reconfig -> reload timing
    //   sr_pclk is an IEEE-754 double; a small float->kHz converter feeds
    //   fout_khz (TODO Phase4). Super-res N multiplies it for the HDMI clock.
    // =====================================================================
    wire        solver_start, solver_done, solver_ok;
    wire [31:0] fout_khz;          // TODO(Phase4): from sr_pclk * superres N
    wire [6:0]  idiv, fbdiv;       wire [7:0] odiv;
    wire        pll_load, pll_lock, video_blank, timing_load, mc_ready, mc_error;

    assign fout_khz = 32'd25175;   // placeholder until float decode + super-res

    groovy_pll_solver u_solver (
        .clk(clk_sys), .rst(rst), .start(solver_start), .fout_khz(fout_khz),
        .done(solver_done), .busy(), .ok(solver_ok),
        .idiv(idiv), .fbdiv(fbdiv), .odiv(odiv),
        .achieved_khz(), .error_khz());

    groovy_mode_change_fsm u_mc (
        .clk(clk_sys), .rst(rst),
        .switchres_valid(switchres_valid), .in_vblank(1'b1 /*TODO timing*/),
        .solver_start(solver_start), .solver_done(solver_done), .solver_ok(solver_ok),
        .pll_load(pll_load), .pll_lock(pll_lock),
        .video_blank(video_blank), .timing_load(timing_load),
        .ready(mc_ready), .error(mc_error));

    //   TODO(Phase4): rpll_gowin u_pll (.load(pll_load), .idiv/.fbdiv/.odiv, .lock(pll_lock), .clkout(clk_pixel));
    assign pll_lock = 1'b1; // placeholder

    // =====================================================================
    // ACK path: status -> ack_sender -> eth_udp_tx -> eth_mac_tx -> PHY
    //   TODO(Phase6/11): build status_bits from ring_buffer / timing flags,
    //   echo blit frame/vsync, send on init/get_status/blit.
    // =====================================================================
    groovy_ack_sender u_ack (
        .clk(clk_sys), .rst(rst),
        .start(get_status_valid /*TODO: also init/blit*/),
        .frame_echo(32'd0), .vsync_echo(16'd0),
        .fpga_vga_frame(32'd0), .fpga_vga_vcount(16'd0), .status_bits(8'd0),
        .out_valid(), .out_data(), .out_last(), .out_ready(1'b1), .busy());
    /* verilator lint_on PINMISSING */

    // =====================================================================
    // Video out: ring_buffer (DDR3) -> super-res replicate -> video_timing_gen
    //   -> [vendored hdmi2 forked for dynamic timing] -> TMDS pairs.
    //   TODO(Phase2/3/7): vendor hdmi2, fork for dynamic modeline, connect.
    // =====================================================================
endmodule

`default_nettype wire
