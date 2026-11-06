// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - network -> BRAM line ring -> 720p HDMI (beam-race, NO DDR3).
//
// The beam-race architecture (docs/beamrace_design.md). Replaces the DDR3 framebuffer
// with a small dual-port BRAM LINE RING: beam-race only needs the write->read working
// set (a few lines), which fits BRAM, and a true dual-port BRAM serves writer + reader
// SIMULTANEOUSLY with NO arbitration - so the DDR3-era writer/reader bus contention
// (the ~1 s crawl) and all the DQS/byte-lane grief simply disappear.
//
// Path:  PHY -> udp -> parser -> blit_rx (RGB565, clk50m)
//            -> groovy_linering (writer -> NLINES-slot dual-port BRAM ring + slot tags
//                                -> raster-driven scanout, pix_clk)
//            -> DVI_TX -> HDMI
//
// Beam-race contract (all of it lives in rtl/core/groovy_linering.v):
//   - the 720p raster FREE-RUNS from reset and is never frozen or re-phased;
//   - the writer stores every pixel the moment it arrives (no FIFO, no guard);
//   - a per-slot line tag decides, per pixel, whether the ring really holds the line
//     the raster is on; if not that pixel is blanked.
//   The HOST keeps the two apart: it leads the raster by ~NLINES/2 source lines, using
//   the raster line reported in every ACK (vCount). UART GL=/LT= show the result.
//
// This first cut fixes the geometry to 320x240 -> 4x3 -> 1280x720 (like gwddr3net) to
// isolate the ring from the dynamic-geometry work. RGB565. DVI_TX is encrypted Gowin
// IP (not committed).
`include "rmii.svh"
`default_nettype none

module gwline_top #(
    // see "geometry" below; a parameter so the benches can pick it (Gowin builds use
    // the default: edit it here, as before)
    parameter integer VIDEO_MODE = 0,
    // 1: decode QOI-per-line blits (CMD_INIT compression 2, docs/qoi_line_format.md,
    // rtl/core/groovy_qoi_rx.v) and advertise it in CMD_GET_FEATURES
    parameter integer QOI = 1,
    // no CMD_BLIT for this long (clk50m cycles, 0.5 s): purge the ring (black screen)
    parameter integer IDLE_PURGE = 25_000_000
) (
    input  wire        clk,          // 27 MHz, H11
    input  wire        rst,          // active-low button, T10
    rmii               netrmii,
    output wire        phyrst,
    output wire        O_tmds_clk_p,
    output wire        O_tmds_clk_n,
    output wire [2:0]  O_tmds_data_p,
    output wire [2:0]  O_tmds_data_n,
    output wire [5:0]  led,
    output wire        uart_txp,     // M11 -> /dev/ttyUSB1 @115200 (debug)
    // Dock audio: PT8211 DAC -> amplifier -> 3.5 mm jack
    output wire        HP_BCK,       // N15
    output wire        HP_WS,        // P16
    output wire        HP_DIN,       // P15
    output wire        PA_EN         // R16, amplifier enable (active high)
);
    localparam [15:0] OUR_PORT = 16'd32100;

    // ====================== geometry ===================================
    // VIDEO_MODE 0: 1280x720@60 (CEA, 74.25 MHz, 4x3 scaling) - the default, HDMI screens.
    // VIDEO_MODE 1: 640x480@60 (VESA, 25.2 MHz, exact 2x2 scaling, negative syncs) - the
    //   mode every VGA monitor accepts, for HDMI->VGA converters (720p is a TV mode that
    //   many VGA monitors reject as "mode not supported"). Host: blitrace --vtotal 525
    //   --vactive 480.
    // VIDEO_MODE 2: 320x240 native 15 kHz "240p" (6.75 MHz = 27*5/4/5, 429x262 = 15.734 kHz /
    //   60.05 Hz, 1x1, hsync 32 px = 4.7 us, vsync 3 lines, negative syncs) - for 15 kHz CRTs
    //   and to find whether an HDMI->VGA converter accepts a pixel clock far below 25 MHz.
    //   Host: blitrace --vtotal 262 --vactive 240 --refresh 60.0547.
    // VIDEO_MODE 3: the SAME 15 kHz 240p raster (15.734 kHz / 60.05 Hz) with each pixel
    //   repeated 4x horizontally (1280 x 240 at 27 MHz = 27*5/1/5, above the ~25 MHz HDMI
    //   floor): "super-resolution" for converters that refuse a low pixel clock. Same host
    //   options as mode 2.
    // INTERLACE (CMD_SWITCHRES interlace != 0): a blit carries ONE FIELD (GroovyMAME's
    //   default -mister_interlaced_fb 1: vactive/2 lines, the field picked from ACK bit 5),
    //   shown like a progressive frame of vactive/2 lines. In VIDEO_MODE 2/3 the raster
    //   itself becomes 2:1 interlaced (fields of 263/262 lines, half-line VSYNC, see
    //   video_timing_gen_il.v); the 720p/480p modes stay progressive (each field bobbed).
    // VIDEO_MODE 4: the raster FOLLOWS THE CMD_SWITCHRES MODELINE (porches, syncs, totals,
    //   interlace) at pclk x N through the dynamic rPLL (groovy_modeline_ctl.v), so the
    //   picture position comes from the host's switchres.ini like on MiSTer. Boots with the
    //   mode-3 raster until the first modeline.
    localparam DYN = (VIDEO_MODE == 4);
    localparam [15:0] SRC_W = 16'd320, SRC_H = 16'd240;
    localparam [15:0] OUT_W = (VIDEO_MODE >= 3) ? 16'd1280 : (VIDEO_MODE == 2) ? 16'd320 : (VIDEO_MODE == 1) ? 16'd640 : 16'd1280;
    localparam [15:0] OUT_H = (VIDEO_MODE >= 2) ? 16'd240 : (VIDEO_MODE == 1) ? 16'd480 : 16'd720;
    localparam integer HREP = (VIDEO_MODE >= 3) ? 4 : (VIDEO_MODE == 2) ? 1 : (VIDEO_MODE == 1) ? 2 : 4;
    localparam integer VREP = (VIDEO_MODE >= 2) ? 1 : (VIDEO_MODE == 1) ? 2 : 3;
    localparam integer HSH  = (VIDEO_MODE >= 3) ? 2 : (VIDEO_MODE == 2) ? 0 : (VIDEO_MODE == 1) ? 1 : 2;
    localparam [15:0] H_TOTAL = (VIDEO_MODE >= 3) ? 16'd1716 : (VIDEO_MODE == 2) ? 16'd429 : (VIDEO_MODE == 1) ? 16'd800 : 16'd1650;
    localparam [15:0] H_SYNC0 = (VIDEO_MODE >= 3) ? 16'd1360 : (VIDEO_MODE == 2) ? 16'd340 : (VIDEO_MODE == 1) ? 16'd656 : 16'd1390;
    localparam [15:0] H_SYNC1 = (VIDEO_MODE >= 3) ? 16'd1488 : (VIDEO_MODE == 2) ? 16'd372 : (VIDEO_MODE == 1) ? 16'd752 : 16'd1430;
    localparam [15:0] V_TOTAL = (VIDEO_MODE >= 2) ? 16'd262 : (VIDEO_MODE == 1) ? 16'd525 : 16'd750;
    localparam [15:0] V_SYNC0 = (VIDEO_MODE >= 2) ? 16'd243 : (VIDEO_MODE == 1) ? 16'd490 : 16'd725;
    localparam [15:0] V_SYNC1 = (VIDEO_MODE >= 2) ? 16'd246 : (VIDEO_MODE == 1) ? 16'd492 : 16'd730;
    localparam        SYNC_POS = (VIDEO_MODE == 0) ? 1'b1 : 1'b0;
    localparam integer FB_ADDR_W  = 17;

    // ---- line ring sizing ----
    // 32 lines = the drift/jitter budget the PoC (tools/beamrace_poc.py) validated for
    // paced beam-race up to 500ppm PC<->Tang clock skew. NLINES must be a power of two
    // (slot = line mod NLINES via low bits).
    localparam integer NLINES  = 32;     // ring depth (drift/jitter tolerance)
    localparam integer LINE_W  = 512;    // columns stored per slot (>= widest native line)

    // =========================================================================
    // NETWORK SIDE (clk50m) - identical to gwddr3net (proven eth RX)
    // =========================================================================
    logic [23:0] ckdiv;
    always_ff @(posedge clk or negedge rst)
        if (!rst) ckdiv <= 24'd0; else ckdiv <= ckdiv + 24'd1;
    wire heartbeat = ckdiv[23];

    logic clk6m, clk1m;
    PLL_6M PLL6m (.clkout(clk6m), .clkoutd(clk1m), .clkin(clk));

    logic        clk50m, ready;
    logic        rx_head_av;  logic [31:0] rx_head;
    logic        rx_data_av;  logic [7:0]  rx_data;
    wire         rx_head_rdy;
    logic [31:0] tx_ip;   logic [15:0] tx_src_port, tx_dst_port;
    logic [7:0]  tx_data; logic        tx_data_av, tx_req;
    logic        tx_req_rdy, tx_data_rdy;
    logic        rx_reject;   // pulses when udp.sv's OWN internal FIFO was full (2026-07-19)

    udp #(
        .ip_adr ({8'd192, 8'd168, 8'd15, 8'd14}),
        .mac_adr({8'h06, 8'h00, 8'hAA, 8'hBB, 8'h0C, 8'hDD}),
        .arp_refresh_interval(50000000*15),
        .arp_max_life_time   (50000000*30)
    ) udp_inst (
        .clk1m(clk1m), .rst(rst),
        .clk50m(clk50m), .ready(ready),
        .netrmii(netrmii), .phyrst(phyrst),
        .rx_head_rdy_i(rx_head_rdy), .rx_head_av_o(rx_head_av), .rx_head_o(rx_head),
        .rx_data_rdy_i(rx_data_rdy),        .rx_data_av_o(rx_data_av), .rx_data_o(rx_data),
        .tx_ip_i(tx_ip), .tx_src_port_i(tx_src_port), .tx_dst_port_i(tx_dst_port),
        .tx_req_i(tx_req), .tx_data_i(tx_data), .tx_data_av_i(tx_data_av),
        .tx_req_rdy_o(tx_req_rdy), .tx_data_rdy_o(tx_data_rdy),
        .rx_reject_o(rx_reject)
    );

    wire core_rst = ~ready;
    logic [22:0] ck50;  logic rx_seen;
    always_ff @(posedge clk50m or negedge rst)
        if (!rst) begin ck50 <= 0; rx_seen <= 0; end
        else begin ck50 <= ck50 + 23'd1; if (rx_data_av) rx_seen <= 1'b1; end

    // Datagram boundaries come from udp.sv's header FIFO (payload length), not from gaps
    // in the byte stream - see groovy_udp_rx_framer.v for why the gap heuristic lost the
    // CMD_BLIT header of every frame after the first.
    wire        p_valid, p_sop, p_eop, rx_data_rdy;
    wire [7:0]  p_data;
    wire [31:0] req_ip;  wire [15:0] req_port;  wire foreign;
    groovy_udp_rx_framer #(.PORT(OUR_PORT)) u_framer (
        .clk(clk50m), .rst(core_rst),
        .rx_head_av(rx_head_av), .rx_head(rx_head), .rx_head_rdy(rx_head_rdy),
        .rx_data_av(rx_data_av), .rx_data(rx_data), .rx_data_rdy(rx_data_rdy),
        .p_valid(p_valid), .p_data(p_data), .p_sop(p_sop), .p_eop(p_eop),
        .src_ip(req_ip), .src_port(req_port), .foreign(foreign));

    wire        init_valid, close_valid, get_status_valid, blit_valid;
    wire        get_features_valid, get_switchres_valid, switchres_valid, session_active;
    wire        beacon_valid, beacon_en;
    wire        audio_valid, a_receiving;  wire [15:0] audio_size;
    wire        a_playing;  wire [15:0] a_underruns;  wire [12:0] a_level;
    wire [1:0]  cfg_sound_rate, cfg_sound_chan;
    wire [7:0]  i_lz4, i_sr, i_sc, i_rgb;
    wire [31:0] blit_frame;  wire [15:0] blit_vsync;
    wire [63:0] sr_pclk;
    wire [15:0] sr_ha, sr_hb, sr_he, sr_ht, sr_va, sr_vb, sr_ve, sr_vt;
    wire [7:0]  sr_il;
    wire        blitting;  wire [2:0] cfg_bpp;  wire [31:0] blit_csize;

    groovy_packet_parser u_parser (
        .clk(clk50m), .rst(core_rst),
        .in_valid(p_valid & ~blitting & ~a_receiving), .in_data(p_data),
        .in_sop(p_sop & ~blitting & ~a_receiving), .in_eop(p_eop & ~blitting & ~a_receiving),
        .cmd_valid(), .cmd(), .bad_packet(),
        .close_valid(close_valid), .init_valid(init_valid),
        .switchres_valid(switchres_valid), .audio_valid(audio_valid), .get_status_valid(get_status_valid),
        .blit_valid(blit_valid), .get_version_valid(),
        .get_features_valid(get_features_valid), .get_switchres_valid(get_switchres_valid),
        .beacon_valid(beacon_valid), .beacon_en(beacon_en),
        .init_lz4(i_lz4), .init_sound_rate(i_sr), .init_sound_chan(i_sc), .init_rgb_mode(i_rgb),
        .sr_pclk(sr_pclk), .sr_h_active(sr_ha), .sr_h_begin(sr_hb), .sr_h_end(sr_he), .sr_h_total(sr_ht),
        .sr_v_active(sr_va), .sr_v_begin(sr_vb), .sr_v_end(sr_ve), .sr_v_total(sr_vt), .sr_interlace(sr_il),
        .audio_size(audio_size),
        .blit_frame(blit_frame), .blit_field(), .blit_vsync(blit_vsync),
        .blit_lz4(), .blit_csize(blit_csize), .blit_flag()
    );

    groovy_session u_session (
        .clk(clk50m), .rst(core_rst),
        .init_valid(init_valid), .init_lz4(i_lz4),
        .init_sound_rate(i_sr), .init_sound_chan(i_sc), .init_rgb_mode(i_rgb),
        .close_valid(close_valid), .session_active(session_active),
        .cfg_lz4(), .cfg_sound_rate(cfg_sound_rate), .cfg_sound_chan(cfg_sound_chan), .cfg_rgb_mode(),
        .new_session(), .end_session(), .cfg_bytes_per_pixel(cfg_bpp)
    );

    // ---- ACK + FEATURES + SWITCHRES (keep the host handshake happy) ----
    wire        ack_start, ack_busy, ack_valid, ack_last, ack_ready;
    wire [7:0]  ack_data;  wire [31:0] ack_frame_echo, ack_fpga_frame;
    wire [15:0] ack_vsync_echo, ack_fpga_vcount;  wire [7:0] ack_status;
    logic [15:0] vcount_50;               // real scanout raster line, CDC'd to clk50m
    logic [15:0] ack_vcount_50;           // the same in Groovy_MiSTer vCount units (see below)
    wire [7:0]  beamrace_status, ack_status_bits;
    logic [31:0] gpu_frame;               // Groovy_MiSTer vga_frame (see below)

    groovy_ack_policy u_policy (
        .clk(clk50m), .rst(core_rst),
        .init_valid(init_valid), .get_status_valid(get_status_valid),
        .blit_valid(blit_valid), .blit_frame(blit_frame), .blit_vsync(blit_vsync),
        .fpga_frame(gpu_frame), .fpga_vcount(ack_vcount_50), .status_bits(ack_status_bits),
        .ack_busy(ack_busy), .ack_start(ack_start),
        .ack_frame_echo(ack_frame_echo), .ack_vsync_echo(ack_vsync_echo),
        .ack_fpga_frame(ack_fpga_frame), .ack_fpga_vcount(ack_fpga_vcount),
        .ack_status(ack_status)
    );
    groovy_ack_sender u_ack (
        .clk(clk50m), .rst(core_rst), .start(ack_start),
        .frame_echo(ack_frame_echo), .vsync_echo(ack_vsync_echo),
        .fpga_vga_frame(ack_fpga_frame), .fpga_vga_vcount(ack_fpga_vcount),
        .status_bits(ack_status),
        .out_valid(ack_valid), .out_data(ack_data), .out_last(ack_last),
        .out_ready(ack_ready), .busy(ack_busy)
    );
    wire ft_valid, ft_last, ft_ready, ft_busy;  wire [7:0] ft_data;
    groovy_features #(
        .PROTO_MAJOR(8'd2), .PROTO_MINOR(8'd0), .PROTO_PATCH(8'd0),
        .COMPRESSION(QOI ? 8'b0000_1001 : 8'b0000_0001), .RGB_MODES(8'b0000_0101)
    ) u_feat (
        .clk(clk50m), .rst(core_rst), .start(get_features_valid),
        .out_valid(ft_valid), .out_data(ft_data), .out_last(ft_last),
        .out_ready(ft_ready), .busy(ft_busy)
    );
    wire        sr_v, sr_l, sr_rdy;  wire [7:0] sr_d;
    wire        sr_res_valid, sr_res_ok;  wire [6:0] sr_res_idiv, sr_res_fbdiv;
    wire [7:0]  sr_res_odiv;  wire [3:0] sr_res_n;  wire [31:0] sr_res_ach, sr_res_tgt;
    groovy_switchres u_switchres (
        .clk(clk50m), .clk_slow(clk1m), .rst(core_rst),
        .switchres_valid(switchres_valid), .sr_pclk(sr_pclk),
        .sr_h_total(sr_ht), .sr_v_total(sr_vt),
        .send(get_switchres_valid),
        .out_valid(sr_v), .out_data(sr_d), .out_last(sr_l), .out_ready(sr_rdy), .busy(),
        .result_valid(sr_res_valid), .idiv(sr_res_idiv), .fbdiv(sr_res_fbdiv),
        .odiv(sr_res_odiv), .superres_n(sr_res_n), .achieved_khz(sr_res_ach),
        .target_khz(sr_res_tgt), .ok(sr_res_ok)
    );
    localparam DEBUG_FIXED_DEST = 1'b0;
    wire [31:0] dst_ip   = DEBUG_FIXED_DEST ? {8'd192,8'd168,8'd15,8'd15} : req_ip;
    wire [15:0] dst_port = DEBUG_FIXED_DEST ? 16'd32101                    : req_port;
    wire        dst_valid = (dst_ip != 32'd0);
    wire        bc_valid, bc_last, bc_ready;  wire [7:0] bc_data;   // raster beacon (below)
    groovy_tx_arbiter u_arb (
        .clk(clk50m), .rst(core_rst),
        .req_ip(dst_ip), .req_port(dst_port), .our_port(OUR_PORT), .req_valid(dst_valid),
        .ack_valid(ack_valid), .ack_data(ack_data), .ack_last(ack_last), .ack_ready(ack_ready),
        .ft_valid(ft_valid), .ft_data(ft_data), .ft_last(ft_last), .ft_ready(ft_ready),
        .sr_valid(sr_v), .sr_data(sr_d), .sr_last(sr_l), .sr_ready(sr_rdy),
        .bc_valid(bc_valid), .bc_data(bc_data), .bc_last(bc_last), .bc_ready(bc_ready),
        .tx_ip(tx_ip), .tx_src_port(tx_src_port), .tx_dst_port(tx_dst_port),
        .tx_data(tx_data), .tx_data_av(tx_data_av), .tx_req(tx_req),
        .tx_req_rdy(tx_req_rdy), .tx_data_rdy(tx_data_rdy)
    );

    // VIDEO RESET (2026-07-19): CMD_INIT (init_valid, already sent at the start of every
    // test session) now also resets the ring writer + upstream FIFO + slot_line ground
    // truth. Without this, groovy_lineram's actual BRAM content (and slot_line) persisted
    // across tests - a new test could inherit stale pixels from a PREVIOUS test, making it
    // impossible to tell "this test's send is broken" from "this is leftover content from
    // before" (exactly the ambiguity hit while debugging sf2.png/hbars this session). This
    // does NOT clear the ring's actual BRAM cells (no bulk-write path for that yet) but
    // DOES reset slot_line to the FFFF sentinel, so SL=FFFF unambiguously means "not
    // rewritten since the last CMD_INIT" even if the physical BRAM cell still has old data.
    // also on CMD_SWITCHRES: the ring's lines belong to the old geometry (another width
    // leaves stale columns at the right edge, seen in sim/tb/gwline_modeline_tb.sv);
    // GroovyMAME sends the modeline right before the next blit, so nothing is lost
    // also when the stream ENDS: the slot tags only hold a line number, so the last lines
    // received stayed valid and were shown on every frame after the session (HW: a band
    // of lines left at the bottom of the screen for ever). CMD_CLOSE purges the ring
    // (black screen), and so does a stream that stops without one (host killed or
    // crashed): IDLE_PURGE clk50m cycles without a CMD_BLIT or a pixel (a frame's lines
    // keep coming for a whole frame time after its CMD_BLIT).
    wire ring_we;                          // pixel into the ring (assigned below)
    logic [25:0] idle_cnt;
    always_ff @(posedge clk50m)
        if (core_rst || blit_valid || ring_we) idle_cnt <= 26'd0;
        else if (idle_cnt <= IDLE_PURGE[25:0]) idle_cnt <= idle_cnt + 26'd1;
    wire idle_purge = (idle_cnt == IDLE_PURGE[25:0]);
    wire video_rst = core_rst | init_valid | switchres_valid | close_valid | idle_purge;

    // ---- BLIT pixel accumulator (clk50m) ----
    wire                  fb_we, frame_done;
    wire [FB_ADDR_W-1:0]  fb_waddr;   // (unused: the ring keeps its own line/col)
    wire [15:0]           fb_wdata;
    // SOURCE GEOMETRY from CMD_SWITCHRES (h_active x v_active), 320x240 until the host
    // sends one. Every game has its own size (GroovyMAME sends the switchres modeline
    // before its first blit), and a blit carries exactly width * height * bytes-per-pixel
    // bytes: with a fixed 320x240 a 320x224 or 384x240 game made blit_rx wait for bytes
    // that never come and swallow the next frame. The raster is still fixed (VIDEO_MODE):
    // a shorter picture leaves black lines at the bottom, a wider one is cut at the right
    // (and beyond LINE_W columns per slot, see groovy_linewr).
    //
    // INTERLACED modelines (Groovy_MiSTer interlace field: 0 progressive, 1 = one field
    // per blit, 2 = the whole frame per blit): src_h is the height of ONE FIELD
    // (vactive/2), which is what the ring and the raster show. With interlace 1
    // (GroovyMAME's default -mister_interlaced_fb 1) a blit is exactly one field. With
    // interlace 2 the blit carries both fields (MiSTer drops every other line); it is
    // consumed whole so the stream stays in step, but NOT displayed correctly here (the
    // ring would show the frame's top half): it needs twice the bandwidth, which 100 Mbit
    // does not have for any useful mode (docs/groovymame_client.md, interlace).
    logic [15:0] src_w = SRC_W, src_h = SRC_H;
    logic        src_il = 1'b0, src_il_whole = 1'b0;
    always_ff @(posedge clk50m)
        if (core_rst || init_valid) begin
            src_w <= SRC_W;  src_h <= SRC_H;  src_il <= 1'b0;  src_il_whole <= 1'b0;
        end else if (switchres_valid && sr_ha != 16'd0 && sr_va != 16'd0) begin
            src_w <= sr_ha;
            src_h <= (sr_il != 8'd0) ? {1'b0, sr_va[15:1]} : sr_va;
            src_il <= (sr_il != 8'd0);  src_il_whole <= (sr_il == 8'd2);
        end
    // registered: blit_rx latches it at each CMD_BLIT header
    logic [31:0]          bytes_len;
    always_ff @(posedge clk50m)
        bytes_len <= src_w * (src_il_whole ? {src_h[14:0], 1'b0} : src_h) * cfg_bpp;
    // QOI session (CMD_INIT compression 2, provisional value: docs/qoi_line_format.md).
    // A blit with cSize = 0 is still raw; one with cSize != 0 carries cSize coded bytes,
    // counted by blit_rx and decoded by groovy_qoi_rx.
    logic cfg_qoi = 1'b0, blit_qoi = 1'b0;
    always_ff @(posedge clk50m)
        if (core_rst) cfg_qoi <= 1'b0;
        else if (init_valid) cfg_qoi <= (QOI != 0) && (i_lz4 == 8'd2);
    wire blit_is_qoi = cfg_qoi && (blit_csize != 32'd0);
    always_ff @(posedge clk50m)
        if (core_rst) blit_qoi <= 1'b0; else if (blit_valid) blit_qoi <= blit_is_qoi;
    wire [31:0] blit_len = blit_is_qoi ? blit_csize : bytes_len;
    wire blit_timed_out;
    // TIMEOUT_CYCLES = 8ms @ 50MHz. The default (1ms) was too tight: a plain sleep()-paced
    // test sender's OWN scheduler jitter occasionally exceeded 1ms between lines, which
    // made the FPGA's OWN watchdog fire on jitter, not a real loss. 8ms stays well under
    // one video frame (16.7ms - a real stall should resolve within a frame) while giving
    // generous headroom over normal OS/network gaps.
    groovy_blit_rx #(.ADDR_W(FB_ADDR_W), .TIMEOUT_CYCLES(400_000)) u_blit (
        .clk(clk50m), .rst(core_rst),
        .start(blit_valid), .bytes_len(blit_len), .bytespp(cfg_bpp),
        .in_valid(p_valid & blitting), .in_data(p_data),
        .blitting(blitting), .frame_done(frame_done), .bytes_recv(),
        .timed_out(blit_timed_out),
        .wr_en(fb_we), .wr_addr(fb_waddr), .wr_data(fb_wdata));

    // ---- QOI blit decoder (clk50m): same pixel stream as blit_rx's, for the ring
    wire        q_we, q_bad, q_ovf;  wire [15:0] q_data;
    generate if (QOI) begin : g_qoi
        groovy_qoi_rx u_qoi (
            .clk(clk50m), .rst(video_rst), .start(blit_valid),
            .fmt565(cfg_bpp == 3'd2), .width(src_w),
            .in_valid(p_valid & blitting & blit_qoi), .in_data(p_data),
            .px_we(q_we), .px_data(q_data), .line_bad(q_bad), .ovf(q_ovf));
    end else begin : g_noqoi
        assign {q_we, q_bad, q_ovf} = 3'b0;  assign q_data = 16'd0;
    end endgenerate
    assign      ring_we   = blit_qoi ? q_we   : fb_we;
    wire [15:0] ring_data = blit_qoi ? q_data : fb_wdata;

    // =========================================================================
    // PIXEL CLOCK (720p) - the only PLL now (no DDR3 clocks)
    // =========================================================================
    wire serial_clk, tmds_lock, pix_clk;
    // VIDEO_MODE 4: the modeline raster (rtl/core/groovy_modeline_ctl.v) and its rPLL
    wire        ml_apply_tgl, ml_pll_hold, ml_il, ml_err;
    wire [15:0] ml_htot, ml_hact, ml_hsb, ml_hse, ml_vtot, ml_vact, ml_vsb, ml_vse;
    wire [3:0]  ml_rep;  wire [6:0] ml_idiv, ml_fbdiv;  wire [7:0] ml_odiv, ml_napplied, ml_npll;
    logic       px_applied_tgl;
    wire hdmi_rst_n;
    generate if (DYN) begin : g_dynpll
        // the controller runs on the button reset (synchronised), not on the network's
        // ready: the raster must come up with or without a host, as in the other modes
        logic [1:0] rst_s;
        always_ff @(posedge clk50m or negedge rst)
            if (!rst) rst_s <= 2'b00; else rst_s <= {rst_s[0], 1'b1};
        groovy_modeline_ctl u_mlctl (
            .clk(clk50m), .rst(~rst_s[1]),
            .switchres_valid(switchres_valid),
            .sr_ha(sr_ha), .sr_hb(sr_hb), .sr_he(sr_he), .sr_ht(sr_ht),
            .sr_va(sr_va), .sr_vb(sr_vb), .sr_ve(sr_ve), .sr_vt(sr_vt), .sr_il(sr_il),
            .clk_slow(clk1m), .sol_valid(sr_res_valid), .sol_ok(sr_res_ok),
            .sol_idiv(sr_res_idiv), .sol_fbdiv(sr_res_fbdiv), .sol_odiv(sr_res_odiv),
            .sol_n(sr_res_n), .sol_ach_khz(sr_res_ach), .sol_tgt_khz(sr_res_tgt),
            .apply_tgl(ml_apply_tgl), .applied_tgl(px_applied_tgl), .pll_hold(ml_pll_hold),
            .m_htot(ml_htot), .m_hact(ml_hact), .m_hsb(ml_hsb), .m_hse(ml_hse),
            .m_vtot(ml_vtot), .m_vact(ml_vact), .m_vsb(ml_vsb), .m_vse(ml_vse),
            .m_il(ml_il), .m_rep(ml_rep),
            .m_idiv(ml_idiv), .m_fbdiv(ml_fbdiv), .m_odiv(ml_odiv),
            .err(ml_err), .n_applied(ml_napplied), .n_pll(ml_npll));
        wire [5:0] idsel, fbdsel, odsel;
        rpll_sel_encode u_enc (.idiv(ml_idiv), .fbdiv(ml_fbdiv), .odiv(ml_odiv),
                               .idsel(idsel), .fbdsel(fbdsel), .odsel(odsel));
        // dynamic rPLL: its LOCK never asserts (video/README.md), so the pixel domain is
        // released by the controller's fixed settle delay instead
        rpll_tmds_dyn u_tmdspll (.clkin(clk), .reset(~rst), .idsel(idsel), .fbdsel(fbdsel),
                                 .odsel(odsel), .clkout(serial_clk), .lock(tmds_lock));
        assign hdmi_rst_n = rst & ~ml_pll_hold;
        CLKDIV u_div (.RESETN(rst), .HCLKIN(serial_clk), .CLKOUT(pix_clk), .CALIB(1'b1));
        defparam u_div.DIV_MODE = "5";
        defparam u_div.GSREN    = "false";
    end else begin : g_fixpll
        assign {ml_apply_tgl, ml_pll_hold, ml_il, ml_err} = 4'b0;
        assign {ml_htot, ml_hact, ml_hsb, ml_hse, ml_vtot, ml_vact, ml_vsb, ml_vse} = '0;
        assign {ml_rep, ml_idiv, ml_fbdiv, ml_odiv, ml_napplied, ml_npll} = '0;
    rpll_tmds #(.IDIV_SEL ((VIDEO_MODE >= 3) ? 0 : (VIDEO_MODE == 2) ? 3  : (VIDEO_MODE == 1) ? 2  : 3),
                .FBDIV_SEL((VIDEO_MODE >= 3) ? 4 : (VIDEO_MODE == 2) ? 4  : (VIDEO_MODE == 1) ? 13 : 54),
                .ODIV_SEL ((VIDEO_MODE >= 3) ? 4 : (VIDEO_MODE == 2) ? 16 : (VIDEO_MODE == 1) ? 8  : 2))
        u_tmdspll (.clkin(clk), .clkout(serial_clk), .lock(tmds_lock));
    assign hdmi_rst_n = rst & tmds_lock;
    CLKDIV u_div (.RESETN(hdmi_rst_n), .HCLKIN(serial_clk), .CLKOUT(pix_clk), .CALIB(1'b1));
    defparam u_div.DIV_MODE = "5";
    defparam u_div.GSREN    = "false";
    end endgenerate

    // =========================================================================
    // 720p timing - FREE-RUNNING. The raster is the system's master clock: it never
    // waits for the network (HDMI sync is valid from reset, host or no host).
    // =========================================================================
    // Interlace is only generated on the 15 kHz rasters (modes 2/3); src_il is static
    // between modelines, so a plain two-flop synchroniser is enough (the generator
    // samples it once per field).
    wire        de, hsync, vsync, line_start, frame_start, field;
    wire [15:0] hcount, vcount;
    logic [1:0] il_pix;
    always_ff @(posedge pix_clk) il_pix <= {il_pix[0], src_il && (VIDEO_MODE >= 2)};

    // VIDEO_MODE 4: the raster registers, in the pixel domain. Loaded from the
    // controller's shadows while the domain is held in reset (PLL change) and at a
    // frame_start once the controller has toggled ml_apply_tgl (seamless change).
    logic [15:0] r_htot = H_TOTAL, r_hact = OUT_W, r_hsb = H_SYNC0, r_hse = H_SYNC1;
    logic [15:0] r_vtot = V_TOTAL, r_vact = OUT_H, r_vsb = V_SYNC0, r_vse = V_SYNC1;
    logic        r_il = 1'b0;  logic [3:0] r_rep = HREP;
    logic [1:0]  apl_s;
    always_ff @(posedge pix_clk) apl_s <= {apl_s[0], ml_apply_tgl};
    always_ff @(posedge pix_clk)
        if (DYN && (!hdmi_rst_n || (frame_start && apl_s[1] != px_applied_tgl))) begin
            r_htot <= ml_htot;  r_hact <= ml_hact;  r_hsb <= ml_hsb;  r_hse <= ml_hse;
            r_vtot <= ml_vtot;  r_vact <= ml_vact;  r_vsb <= ml_vsb;  r_vse <= ml_vse;
            r_il   <= ml_il;    r_rep  <= ml_rep;
            px_applied_tgl <= apl_s[1];
        end
    video_timing_gen_il u_timing (
        .clk(pix_clk), .rst(~hdmi_rst_n), .en(1'b1), .interlace(DYN ? r_il : il_pix[1]),
        .h_total(DYN ? r_htot : H_TOTAL), .h_active(DYN ? r_hact : OUT_W),
        .h_sync_begin(DYN ? r_hsb : H_SYNC0), .h_sync_end(DYN ? r_hse : H_SYNC1),
        .v_total(DYN ? r_vtot : V_TOTAL), .v_active(DYN ? r_vact : OUT_H),
        .v_sync_begin(DYN ? r_vsb : V_SYNC0), .v_sync_end(DYN ? r_vse : V_SYNC1),
        .h_sync_pos(SYNC_POS), .v_sync_pos(SYNC_POS),
        .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de),
        .line_start(line_start), .frame_start(frame_start), .field(field));

    // =========================================================================
    // LINE RING: blit_rx pixels in (clk50m), raster pixels out (pix_clk).
    // video_rst (reset, CMD_INIT or CMD_SWITCHRES) restarts the writer and re-clears every slot tag,
    // so a new session can never show a previous session's lines.
    // =========================================================================
    wire [15:0] write_line, src_line_wr, lead_top;
    wire [9:0]  good_lines;
    wire [9:0]  bad_first, bad_last, bad_early, bad_late, bad_wr;
    wire [15:0] pix565;  wire de_o, hs_o, vs_o;
    groovy_linering #(.NLINES(NLINES), .LINE_W(LINE_W), .DATA_W(16),
                      .H_SH(HSH), .V_REPL(VREP), .DYN_H(DYN ? 1 : 0),
                      .BAD_COLOR(16'h0000)) u_linering (
        .wr_clk(clk50m), .wr_rst(video_rst), .frame_start(blit_valid),
        .px_we(ring_we), .px_data(ring_data), .native_w(src_w),
        .write_line(write_line), .src_line_wr(src_line_wr), .lead_top(lead_top),
        .pix_clk(pix_clk), .pix_rst(~hdmi_rst_n),
        .hcount(hcount), .h_rep(r_rep), .vcount(vcount), .de(de), .hsync(hsync), .vsync(vsync),
        .vframe_start(frame_start),
        .pix(pix565), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o),
        .good_lines(good_lines),
        .bad_first(bad_first), .bad_last(bad_last),
        .bad_early(bad_early), .bad_late(bad_late), .bad_wr(bad_wr));

    // raster source line for the ACK vCount (host phase-lock feedback); already Gray-
    // synchronised into clk50m inside the ring.
    always_ff @(posedge clk50m) vcount_50 <= src_line_wr;
    // Field being scanned (Groovy_MiSTer VGA_F1, ACK status bit 5): 0 = even source
    // lines, 1 = odd. Synchronised like vframe_tgl (same depth), so it changes together
    // with gpu_frame. With an interlaced source, the ACK vCount is in FRAME lines like
    // MiSTer's v_cnt (2 * field line + field): GroovyMAME computes
    // ((frame_req - frame_gpu) * vtotal + vcount_req - vcount_gpu) / 2 with vtotal = 525.
    logic [2:0] field_50;
    always_ff @(posedge clk50m) field_50 <= {field_50[1:0], field};
    always_ff @(posedge clk50m)
        ack_vcount_50 <= src_il ? {src_line_wr[14:0], field_50[1]} : src_line_wr;

    // good_lines changes once per video frame in pix_clk; take it into clk50m only when
    // two consecutive samples agree, so the update instant can never be seen torn.
    logic [9:0] gl_s1, gl_s2, gl_50;
    always_ff @(posedge clk50m) begin
        gl_s1 <= good_lines;  gl_s2 <= gl_s1;
        if (gl_s1 == gl_s2) gl_50 <= gl_s2;
    end
    // the last bad frame's report, crossed the same way (all five change together)
    logic [49:0] bd_s1, bd_s2, bd_50;
    always_ff @(posedge clk50m) begin
        bd_s1 <= {bad_first, bad_last, bad_early, bad_late, bad_wr};  bd_s2 <= bd_s1;
        if (bd_s1 == bd_s2) bd_50 <= bd_s2;
    end
    // every output line the source covers was valid in the last video frame
    wire [15:0] src_out_h = DYN ? src_h : (src_h * VREP > OUT_H) ? OUT_H : src_h * VREP;
    wire picture_ok = (gl_50 == src_out_h[9:0]);
    // Beacon status bit0: picture NOT complete; bit6: audio playing.
    assign beamrace_status = {1'b0, a_playing, 5'd0, ~picture_ok};
    // ACK status bit5 is VGA_F1 (the field being scanned, see field_50).
    // ACK status bit6 is Groovy_MiSTer's FPGA_AUDIO = "this receiver has an audio output
    // enabled" (MiSTer: the core's OSD audio option), NOT "playing": GroovyMAME and the
    // groovymister API send CMD_AUDIO only once an ACK has shown it, so tying it to
    // playback would deadlock (playback needs audio first). The Dock's jack is always there.
    assign ack_status_bits = {1'b0, 1'b1, field_50[1], 4'd0, ~picture_ok};

    // ---- AUDIO (CMD_AUDIO -> buffer -> PT8211 on the Dock jack), see groovy_audio.v.
    // Its payload bytes are taken here while a_receiving, like the pixels while blitting.
    groovy_audio u_audio (
        .clk(clk50m), .rst(core_rst), .cfg_rate(cfg_sound_rate), .cfg_chan(cfg_sound_chan),
        .start(audio_valid), .size_bytes(audio_size),
        .in_valid(p_valid & a_receiving), .in_data(p_data), .receiving(a_receiving),
        .hp_bck(HP_BCK), .hp_ws(HP_WS), .hp_din(HP_DIN), .pa_en(PA_EN),
        .playing(a_playing), .underruns(a_underruns), .overflows(), .rx_timeouts(),
        .level(a_level));

    // video raster loops (60 Hz, independent of the network), counted in clk50m
    logic vframe_tgl;
    always_ff @(posedge pix_clk or negedge hdmi_rst_n)
        if (!hdmi_rst_n) vframe_tgl <= 1'b0;
        else if (frame_start) vframe_tgl <= ~vframe_tgl;
    logic [2:0] vframe_tgl_50;
    always_ff @(posedge clk50m) vframe_tgl_50 <= {vframe_tgl_50[1:0], vframe_tgl};
    wire vframe_pulse_50 = vframe_tgl_50[2] ^ vframe_tgl_50[1];
    logic [15:0] vframe_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) vframe_cnt <= 16'd0;
        else if (vframe_pulse_50 && vframe_cnt != 16'hFFFF) vframe_cnt <= vframe_cnt + 16'd1;

    // GPU FRAME COUNTER for the ACK, with Groovy_MiSTer's semantics (rtl/vga.v
    // vga_frame): cleared by CMD_INIT / CMD_CLOSE, it starts with the first blit and then
    // steps once per video frame at the raster's top of frame, so frame N is the one
    // being scanned while it reads N. Clients pace themselves on it: GroovyMAME waits
    // (frame_req - frame_gpu) * vtotal + vcount_req - vcount_gpu lines before emulating
    // the next frame (drawnogpu.cpp nogpu_wait_status), so a constant 0 here made it wait
    // seconds per frame. The first blit F is shown from the next top of frame, so the
    // counter is preset to F-1 (GroovyMAME's first blit is frame 1, like MiSTer's count
    // from 0). After that it free-runs; a client that falls behind re-aligns itself
    // (m_frame = frame_gpu + 1), as with MiSTer.
    logic gpu_started;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) begin
            gpu_frame <= 32'd0;  gpu_started <= 1'b0;
        end else if (init_valid || close_valid) begin
            gpu_frame <= 32'd0;  gpu_started <= 1'b0;
        end else if (blit_valid && !gpu_started) begin
            gpu_frame <= blit_frame - 32'd1;  gpu_started <= 1'b1;
        end else if (vframe_pulse_50 && gpu_started)
            gpu_frame <= gpu_frame + 32'd1;

    // RASTER BEACON (CMD_SET_BEACON, opt-in): one datagram per video frame, pushed when
    // the raster enters vertical blanking (source line SRC_H), so the host phase-locks on
    // arrival times instead of polling - see groovy_beacon_sender.v. Off after reset and
    // after CMD_CLOSE; stock GroovyMAME never enables it, so it never sees one.
    logic beacon_on;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst)          beacon_on <= 1'b0;
        else if (close_valid)  beacon_on <= 1'b0;
        else if (beacon_valid) beacon_on <= beacon_en;
    logic [15:0] vcount_50_q;
    always_ff @(posedge clk50m) vcount_50_q <= vcount_50;
    wire beacon_fire = beacon_on && (vcount_50 == SRC_H) && (vcount_50_q != SRC_H);
    // free-running video frame counter for the beacon (vframe_cnt saturates for the UART)
    logic [31:0] vframe_32;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) vframe_32 <= 32'd0; else if (vframe_pulse_50) vframe_32 <= vframe_32 + 32'd1;
    groovy_beacon_sender u_beacon (
        .clk(clk50m), .rst(core_rst), .trigger(beacon_fire),
        .video_frame(vframe_32), .raster_line(vcount_50),
        .good_lines({6'd0, gl_50}), .lead_top(lead_top), .status_bits(beamrace_status),
        .out_valid(bc_valid), .out_data(bc_data), .out_last(bc_last),
        .out_ready(bc_ready), .busy());

    // udp.sv's own RX-FIFO admission rejects (clk50m, same domain)
    logic [15:0] rj_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) rj_cnt <= 16'd0;
        else if (rx_reject && rj_cnt != 16'hFFFF) rj_cnt <= rj_cnt + 16'd1;

    // =========================================================================
    // RGB565 -> RGB888 + DVI_TX
    // =========================================================================
    wire [4:0] r5 = pix565[15:11];  wire [5:0] g6 = pix565[10:5];  wire [4:0] b5 = pix565[4:0];
    wire [7:0] r8 = {r5, r5[4:2]};  wire [7:0] g8 = {g6, g6[5:4]};  wire [7:0] b8 = {b5, b5[4:2]};
    DVI_TX_Top u_dvi (
        .I_rst_n(hdmi_rst_n), .I_serial_clk(serial_clk), .I_rgb_clk(pix_clk),
        .I_rgb_vs(vs_o), .I_rgb_hs(hs_o), .I_rgb_de(de_o),
        .I_rgb_r(r8), .I_rgb_g(g8), .I_rgb_b(b8),
        .O_tmds_clk_p(O_tmds_clk_p),   .O_tmds_clk_n(O_tmds_clk_n),
        .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n));

    // =========================================================================
    // UART debug (M11 -> /dev/ttyUSB1 @115200), one line every ~0.1 s:
    //   RD=network frames fully received (blit_rx frame_done), cumulative
    //   WL=writer's completed-line count in the current network frame (live)
    //   RL=raster source line (live, 0..249 incl. vertical blanking)
    //   LT=WL sampled when the raster started line 0 = the HOST'S LEAD in lines.
    //      ~0x14 (20) is the target; valid window ~0x0A..0x1E. Near 0 = host late,
    //      near/over 0x20 = host too early. Large (e.g. 0xEB) = host a frame behind.
    //   GL=output lines of the LAST video frame whose every pixel had a valid slot tag.
    //      0x02D0 (720) = perfect picture. This is THE health number.
    //   TO=blit_rx timeouts (a frame that never completed: lost datagram), cumulative
    //   RJ=udp.sv RX-FIFO admission rejects, cumulative
    //   VF=video frames since reset   SE=any UDP payload seen   TL=HDMI PLL locked
    //   LN,LX=min, max SIGNED lead (two's complement) of every frame since the last line
    //   BF=frames shown incomplete, of which LF=late EF=early OF=other, cumulative
    //   (see groovy_ring_stats.v)
    //   QE=QOI lines received corrupted, QO=QOI bytes dropped (decoder FIFO full),
    //   since the last CMD_INIT, kept after CMD_CLOSE (groovy_qoi_rx.v; 0 in raw sessions)
//   FX=datagrams for another UDP port (LAN broadcasts) dropped, cumulative
//   B0,B1=first and last bad source line of the LAST BAD video frame (kept until the
//   next bad one); BE,BL,BW=its bad output lines that were early (overwritten by a later
//   line), late (not arrived yet), mid-rewrite or never written (groovy_linescan.v)
    // =========================================================================
    // Ring health over every frame. The min/max window restarts with each UART line (the
    // request crosses from the 27 MHz UART domain as a toggle).
    wire        dbg_line_start;
    reg         dbg_line_tgl = 1'b0;
    always @(posedge clk) if (dbg_line_start) dbg_line_tgl <= ~dbg_line_tgl;
    logic [2:0] dbg_line_50;
    always_ff @(posedge clk50m) dbg_line_50 <= {dbg_line_50[1:0], dbg_line_tgl};
    wire signed [15:0] st_lmin, st_lmax;
    wire [15:0] st_bad, st_late, st_early, st_other;
    groovy_ring_stats #(.NLINES(NLINES)) u_ring_stats (
        .clk(clk50m), .rst(video_rst), .frame_start(blit_valid), .raster_line(src_line_wr),
        .good_lines(gl_50), .want_lines(src_out_h[9:0]),
        .window_clear(dbg_line_50[2] ^ dbg_line_50[1]),
        .lead_min(st_lmin), .lead_max(st_lmax), .bad_frames(st_bad), .late_frames(st_late),
        .early_frames(st_early), .other_frames(st_other));

    logic [15:0] frame_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) frame_cnt <= 16'd0; else if (frame_done) frame_cnt <= frame_cnt + 16'd1;

    // datagrams for another UDP port (LAN broadcasts), dropped by the framer; cumulative
    logic [15:0] fx_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) fx_cnt <= 16'd0;
        else if (foreign && fx_cnt != 16'hFFFF) fx_cnt <= fx_cnt + 16'd1;

    logic [15:0] qe_cnt, qo_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) begin qe_cnt <= 16'd0;  qo_cnt <= 16'd0; end
        else if (init_valid) begin qe_cnt <= 16'd0;  qo_cnt <= 16'd0; end   // per session
        else begin
            if (q_bad && qe_cnt != 16'hFFFF) qe_cnt <= qe_cnt + 16'd1;
            if (q_ovf && qo_cnt != 16'hFFFF) qo_cnt <= qo_cnt + 16'd1;
        end

    logic [15:0] to_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) to_cnt <= 16'd0;
        else if (blit_timed_out && to_cnt != 16'hFFFF) to_cnt <= to_cnt + 16'd1;

    reg [1:0] tmds_lock_sync;
    always @(posedge clk) tmds_lock_sync <= {tmds_lock_sync[0], tmds_lock};

    // snapshot into the 27 MHz UART domain (debug only: a value caught mid-change shows
    // up as one odd line in the log, nothing more)
    reg [15:0] q_fc, q_wl, q_rl, q_lt, q_gl, q_to, q_rj, q_vf, q_al, q_au;  reg q_se, q_tl;
    reg [15:0] q_ln, q_lx, q_bf, q_lf, q_ef, q_of, q_qe, q_qo, q_fx;
    reg [15:0] q_b0, q_b1, q_be, q_bl, q_bw;
    always @(posedge clk) begin
        q_fc <= frame_cnt;  q_wl <= write_line;  q_rl <= src_line_wr;  q_lt <= lead_top;
        q_gl <= {6'd0, gl_50};  q_to <= to_cnt;  q_rj <= rj_cnt;  q_vf <= vframe_cnt;
        q_se <= rx_seen;  q_tl <= tmds_lock_sync[1];
        q_al <= {3'd0, a_level};  q_au <= a_underruns;
        q_bf <= st_bad;  q_lf <= st_late;  q_ef <= st_early;  q_of <= st_other;
        q_qe <= qe_cnt;  q_qo <= qo_cnt;  q_fx <= fx_cnt;
        q_b0 <= {6'd0, bd_50[49:40]};  q_b1 <= {6'd0, bd_50[39:30]};
        q_be <= {6'd0, bd_50[29:20]};  q_bl <= {6'd0, bd_50[19:10]};  q_bw <= {6'd0, bd_50[9:0]};
        if (dbg_line_start) begin q_ln <= st_lmin;  q_lx <= st_lmax; end
    end

    wire [7:0] tx_din; wire tx_wr, tx_busy;
    uart_tx_V2 #(.clk_freq(27_000_000), .uart_freq(115200)) u_dbgtx (
        .clk(clk), .din(tx_din), .wr_en(tx_wr), .tx_busy(tx_busy), .tx_p(uart_txp));
    function [7:0]  hxd; input [3:0]  n; hxd = (n<4'd10)?(8'h30+n):(8'h41+n-4'd10); endfunction
    function [31:0] hx4; input [15:0] v;
        hx4 = {hxd(v[15:12]), hxd(v[11:8]), hxd(v[7:4]), hxd(v[3:0])};
    endfunction
    localparam integer DBGLEN = 203;
    wire [8*DBGLEN-1:0] dmsg = {
        "RD=", hx4(q_fc), " WL=", hx4(q_wl), " RL=", hx4(q_rl), " LT=", hx4(q_lt),
        " GL=", hx4(q_gl), " TO=", hx4(q_to), " RJ=", hx4(q_rj), " VF=", hx4(q_vf),
        " SE=", hxd({3'b0, q_se}), " TL=", hxd({3'b0, q_tl}),
        " AL=", hx4(q_al), " AU=", hx4(q_au),
        " LN=", hx4(q_ln), " LX=", hx4(q_lx), " BF=", hx4(q_bf), " LF=", hx4(q_lf),
        " EF=", hx4(q_ef), " OF=", hx4(q_of), " QE=", hx4(q_qe), " QO=", hx4(q_qo), " FX=", hx4(q_fx),
        " B0=", hx4(q_b0), " B1=", hx4(q_b1), " BE=", hx4(q_be), " BL=", hx4(q_bl), " BW=", hx4(q_bw),
        8'h0D, 8'h0A };
    reg [7:0] di=0, dtx=0; reg dwr=0; reg [2:0] dst=0; reg [23:0] dhold=0;
    wire [7:0] dlb = dmsg[8*(DBGLEN-1-di) +: 8];
    assign dbg_line_start = (dst == 3'd0);
    always @(posedge clk) begin
        dwr<=1'b0;
        case (dst)
            3'd0: begin di<=0; dst<=3'd1; end
            3'd1: begin dtx<=dlb; dwr<=1'b1; dst<=3'd2; end
            3'd2: if (tx_busy) dst<=3'd3;
            3'd3: if (!tx_busy) begin
                if (di==DBGLEN-1) begin dst<=3'd4; dhold<=24'd2_700_000; end
                else begin di<=di+1'b1; dst<=3'd1; end
            end
            3'd4: if (dhold==0) dst<=3'd0; else dhold<=dhold-1'b1;
            default: dst<=3'd0;
        endcase
    end
    assign tx_din=dtx; assign tx_wr=dwr;

    // =========================================================================
    // LEDs (board-number convention)
    //   0=ready 1=tmds_lock 2=picture complete (GL=720) 3=rx_seen
    //   4=receiving but picture NOT complete 5=heartbeat
    // =========================================================================
    wire [5:0] board;
    assign board[0] = ready;
    assign board[1] = tmds_lock;
    assign board[2] = picture_ok;
    assign board[3] = rx_seen;
    assign board[4] = rx_seen & ~picture_ok;
    assign board[5] = heartbeat;
    assign led = ~{ board[0], board[2], board[4], board[3], board[5], board[1] };

endmodule

`default_nettype wire
