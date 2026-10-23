// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - network -> DDR3 framebuffer -> 720p HDMI (first networked picture).
//
// THE MERGE. Two proven halves joined for the first time:
//   * The Ethernet front end from full/groovy_top.sv: Sipeed udp -> packet parser
//     -> session -> blit_rx (RGB565 pixel accumulator), all in the 50 MHz network
//     domain. A CMD_BLIT + its pixel datagrams produce one assembled frame.
//   * The DDR3 video path from gwddr3video_top.v: mem_pll -> Gowin DDR3 IP ->
//     adapter -> line-buffer reader -> DVI_TX, all on the DDR3 user clock (pclk).
//
// THE SEAM: blit_rx emits {wr_addr (= y*SRC_W+x), wr_data (RGB565)} on clk50m. We
// push each pixel into a Gray-pointer async FIFO and drain it on pclk via
// groovy_ddr3_writer, which issues single-word DDR3 writes through the same adapter
// the old boot pattern writer used. So the network fills the framebuffer instead of
// a test pattern. When the first whole frame has been received (frame_done), a
// have_frame flag (CDC'd to pclk) releases the line-buffer reader to scan it out.
//
// STATIC first picture: single buffer, no double-buffering, no beam-race. The frame
// is written once and displayed continuously; a second frame just overwrites it
// (tearing tolerated). Double-buffer / beam-race come later (see roadmap).
//
// Send it with:  tools/gm_test_sender.py --host 192.168.15.14 \
//                    init --lz4 0 --rate 0 --chan 2 --rgb 2
//                blitimg --width 320 --height 240 --rgb 2
// (PC must hold a static IP on the 192.168.15.0/24 subnet first.)
//
// DVI_TX_Top and the Gowin DDR3 IP (ddr3_mi.v) are encrypted Gowin IP - NOT
// committed; regenerate them with the Gowin IP wizard (see the respective READMEs).
`include "rmii.svh"
`default_nettype none

module gwddr3net_top (
    input  wire        clk,          // 27 MHz, H11
    input  wire        rst,          // active-low button, T10

    // Ethernet (RMII / RTL8201)
    rmii               netrmii,
    output wire        phyrst,

    // DDR3 - GOWIN DDR3 IP pins (SSTL15D diff DQS/CK via the hard PHY)
    inout  wire [15:0] ddr_dq,
    inout  wire [1:0]  ddr_dqs,
    inout  wire [1:0]  ddr_dqs_n,
    output wire [12:0] ddr_addr,
    output wire [2:0]  ddr_bank,
    output wire        ddr_cs,
    output wire        ddr_we,
    output wire        ddr_ras,
    output wire        ddr_cas,
    output wire        ddr_clk,
    output wire        ddr_clk_n,
    output wire        ddr_reset_n,
    output wire        ddr_cke,
    output wire        ddr_odt,
    output wire [1:0]  ddr_dm,

    // HDMI / DVI
    output wire        O_tmds_clk_p,
    output wire        O_tmds_clk_n,
    output wire [2:0]  O_tmds_data_p,
    output wire [2:0]  O_tmds_data_n,

    output wire [5:0]  led,
    output wire        uart_txp      // M11 -> FT2232 -> /dev/ttyUSB1 @115200 (debug)
);
    // DDR3/video blocks use sys_clk/sys_resetn names; the eth interface uses clk/rst.
    wire sys_clk    = clk;
    wire sys_resetn = rst;

    localparam [15:0] OUR_PORT = 16'd32100;

    // ====================== geometry ===================================
    localparam [15:0] SRC_W = 16'd320, SRC_H = 16'd240;   // framebuffer (source)
    localparam [15:0] OUT_W = 16'd1280, OUT_H = 16'd720;  // HDMI output (timing)
    localparam integer HREP = 4, VREP = 3, HSH = 2;       // 320*4=1280, 240*3=720
    localparam [25:0] BASE  = 26'd0;                      // frame base in DDR3 words
    localparam integer NATIVE_PIX = 320*240;              // 76800 source words
    localparam integer FB_ADDR_W  = 17;                   // 2^17 > 76800

    // =========================================================================
    // NETWORK SIDE (clk50m) - mirrors full/groovy_top.sv RX path
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
    wire         rx_head_rdy, rx_data_rdy;

    logic [31:0] tx_ip;   logic [15:0] tx_src_port, tx_dst_port;
    logic [7:0]  tx_data; logic        tx_data_av, tx_req;
    logic        tx_req_rdy, tx_data_rdy;

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
        .rx_data_rdy_i(rx_data_rdy), .rx_data_av_o(rx_data_av), .rx_data_o(rx_data),
        .tx_ip_i(tx_ip), .tx_src_port_i(tx_src_port), .tx_dst_port_i(tx_dst_port),
        .tx_req_i(tx_req), .tx_data_i(tx_data), .tx_data_av_i(tx_data_av),
        .tx_req_rdy_o(tx_req_rdy), .tx_data_rdy_o(tx_data_rdy)
    );

    wire core_rst = ~ready;

    logic [22:0] ck50;  logic rx_seen;
    always_ff @(posedge clk50m or negedge rst)
        if (!rst) begin ck50 <= 0; rx_seen <= 0; end
        else begin ck50 <= ck50 + 23'd1; if (rx_data_av) rx_seen <= 1'b1; end

    // Datagram framing from udp.sv's header FIFO (payload length), not from gaps in the
    // byte stream - see groovy_udp_rx_framer.v. It also captures the reply address.
    wire        p_valid, p_sop, p_eop;
    wire [7:0]  p_data;
    wire [31:0] req_ip;  wire [15:0] req_port;
    groovy_udp_rx_framer u_framer (
        .clk(clk50m), .rst(core_rst),
        .rx_head_av(rx_head_av), .rx_head(rx_head), .rx_head_rdy(rx_head_rdy),
        .rx_data_av(rx_data_av), .rx_data(rx_data), .rx_data_rdy(rx_data_rdy),
        .p_valid(p_valid), .p_data(p_data), .p_sop(p_sop), .p_eop(p_eop),
        .src_ip(req_ip), .src_port(req_port));

    wire        init_valid, close_valid, get_status_valid, blit_valid;
    wire        get_features_valid, get_switchres_valid, switchres_valid, session_active;
    wire [7:0]  i_lz4, i_sr, i_sc, i_rgb;
    wire [31:0] blit_frame;
    wire [15:0] blit_vsync;
    wire [63:0] sr_pclk;
    wire [15:0] sr_ha, sr_hb, sr_he, sr_ht, sr_va, sr_vb, sr_ve, sr_vt;
    wire        blitting;          // from blit_rx (gates the parser)
    wire [2:0]  cfg_bpp;           // bytes per pixel (from session/INIT)

    // While blitting, datagrams are PIXELS not commands - gate them from the parser.
    groovy_packet_parser u_parser (
        .clk(clk50m), .rst(core_rst),
        .in_valid(p_valid & ~blitting), .in_data(p_data),
        .in_sop(p_sop & ~blitting), .in_eop(p_eop & ~blitting),
        .cmd_valid(), .cmd(), .bad_packet(),
        .close_valid(close_valid), .init_valid(init_valid),
        .switchres_valid(switchres_valid), .audio_valid(), .get_status_valid(get_status_valid),
        .blit_valid(blit_valid), .get_version_valid(),
        .get_features_valid(get_features_valid), .get_switchres_valid(get_switchres_valid),
        .init_lz4(i_lz4), .init_sound_rate(i_sr),
        .init_sound_chan(i_sc), .init_rgb_mode(i_rgb),
        .sr_pclk(sr_pclk), .sr_h_active(sr_ha), .sr_h_begin(sr_hb), .sr_h_end(sr_he), .sr_h_total(sr_ht),
        .sr_v_active(sr_va), .sr_v_begin(sr_vb), .sr_v_end(sr_ve), .sr_v_total(sr_vt), .sr_interlace(),
        .audio_size(),
        .blit_frame(blit_frame), .blit_field(), .blit_vsync(blit_vsync),
        .blit_lz4(), .blit_csize(), .blit_flag()
    );

    groovy_session u_session (
        .clk(clk50m), .rst(core_rst),
        .init_valid(init_valid), .init_lz4(i_lz4),
        .init_sound_rate(i_sr), .init_sound_chan(i_sc), .init_rgb_mode(i_rgb),
        .close_valid(close_valid), .session_active(session_active),
        .cfg_lz4(), .cfg_sound_rate(), .cfg_sound_chan(), .cfg_rgb_mode(),
        .new_session(), .end_session(), .cfg_bytes_per_pixel(cfg_bpp)
    );

    // ---- ACK + FEATURES + SWITCHRES reply (keeps the host's handshake happy) ----
    wire        ack_start, ack_busy, ack_valid, ack_last, ack_ready;
    wire [7:0]  ack_data;
    wire [31:0] ack_frame_echo, ack_fpga_frame;
    wire [15:0] ack_vsync_echo, ack_fpga_vcount;
    wire [7:0]  ack_status;

    groovy_ack_policy u_policy (
        .clk(clk50m), .rst(core_rst),
        .init_valid(init_valid), .get_status_valid(get_status_valid),
        .blit_valid(blit_valid), .blit_frame(blit_frame), .blit_vsync(blit_vsync),
        .fpga_frame(32'd0), .fpga_vcount(ck50[15:0]), .status_bits(8'd0),
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
        .COMPRESSION(8'b0000_0001), .RGB_MODES(8'b0000_0101)
    ) u_feat (
        .clk(clk50m), .rst(core_rst), .start(get_features_valid),
        .out_valid(ft_valid), .out_data(ft_data), .out_last(ft_last),
        .out_ready(ft_ready), .busy(ft_busy)
    );

    wire        sr_v, sr_l, sr_rdy;  wire [7:0] sr_d;
    groovy_switchres u_switchres (
        .clk(clk50m), .clk_slow(clk1m), .rst(core_rst),
        .switchres_valid(switchres_valid), .sr_pclk(sr_pclk),
        .sr_h_total(sr_ht), .sr_v_total(sr_vt),
        .send(get_switchres_valid),
        .out_valid(sr_v), .out_data(sr_d), .out_last(sr_l), .out_ready(sr_rdy), .busy(),
        .result_valid(), .idiv(), .fbdiv(), .odiv(), .superres_n(), .achieved_khz(), .ok()
    );

    localparam        DEBUG_FIXED_DEST = 1'b0;
    wire [31:0] dst_ip   = DEBUG_FIXED_DEST ? {8'd192,8'd168,8'd15,8'd15} : req_ip;
    wire [15:0] dst_port = DEBUG_FIXED_DEST ? 16'd32101                    : req_port;
    wire        dst_valid = (dst_ip != 32'd0);

    groovy_tx_arbiter u_arb (
        .clk(clk50m), .rst(core_rst),
        .req_ip(dst_ip), .req_port(dst_port), .our_port(OUR_PORT), .req_valid(dst_valid),
        .ack_valid(ack_valid), .ack_data(ack_data), .ack_last(ack_last), .ack_ready(ack_ready),
        .ft_valid(ft_valid), .ft_data(ft_data), .ft_last(ft_last), .ft_ready(ft_ready),
        .sr_valid(sr_v), .sr_data(sr_d), .sr_last(sr_l), .sr_ready(sr_rdy),
        .tx_ip(tx_ip), .tx_src_port(tx_src_port), .tx_dst_port(tx_dst_port),
        .tx_data(tx_data), .tx_data_av(tx_data_av), .tx_req(tx_req),
        .tx_req_rdy(tx_req_rdy), .tx_data_rdy(tx_data_rdy)
    );

    // ---- BLIT pixel accumulator (clk50m). bytes_len = native_pixels * bpp. ----
    wire                  fb_we, frame_done;
    wire [FB_ADDR_W-1:0]  fb_waddr;     // pixel index = y*SRC_W + x = DDR3 word addr
    wire [15:0]           fb_wdata;     // RGB565
    wire [31:0]           bytes_len = NATIVE_PIX * cfg_bpp;

    groovy_blit_rx #(.ADDR_W(FB_ADDR_W)) u_blit (
        .clk(clk50m), .rst(core_rst),
        .start(blit_valid), .bytes_len(bytes_len), .bytespp(cfg_bpp),
        .in_valid(p_valid & blitting), .in_data(p_data),
        .blitting(blitting), .frame_done(frame_done), .bytes_recv(),
        .wr_en(fb_we), .wr_addr(fb_waddr), .wr_data(fb_wdata));

    // =========================================================================
    // DDR3 CLOCKS + IP + ADAPTER (pclk) - mirrors gwddr3video_top.v
    // =========================================================================
    wire memory_clk, ddr_pll_lock;
    mem_pll u_mempll (.clkout(memory_clk), .lock(ddr_pll_lock), .clkoutd3(), .reset(~sys_resetn), .clkin(sys_clk));

    wire serial_clk, tmds_lock, pix_clk;
    rpll_tmds u_tmdspll (.clkin(sys_clk), .clkout(serial_clk), .lock(tmds_lock));
    wire hdmi_rst_n = sys_resetn & tmds_lock;
    CLKDIV u_div (.RESETN(hdmi_rst_n), .HCLKIN(serial_clk), .CLKOUT(pix_clk), .CALIB(1'b1));
    defparam u_div.DIV_MODE = "5";
    defparam u_div.GSREN    = "false";

    wire clk_out, ddr_rst, init_calib_complete, ip_cmd_ready, ip_wr_data_rdy;
    wire [127:0] ip_rd_data; wire ip_rd_data_valid, ip_rd_data_end;
    wire [2:0]  ip_cmd; wire ip_cmd_en; wire [26:0] ip_addr;
    wire [127:0] ip_wr_data; wire ip_wr_data_en, ip_wr_data_end; wire [15:0] ip_wr_data_mask;

    wire pclk = clk_out;
    wire pclk_resetn = ~ddr_rst & init_calib_complete;

    DDR3_Memory_Interface_Top u_ddr3 (
        .clk(sys_clk), .memory_clk(memory_clk), .pll_lock(ddr_pll_lock), .rst_n(sys_resetn),
        .clk_out(clk_out), .ddr_rst(ddr_rst), .init_calib_complete(init_calib_complete),
        .cmd_ready(ip_cmd_ready), .cmd(ip_cmd), .cmd_en(ip_cmd_en), .addr(ip_addr),
        .wr_data_rdy(ip_wr_data_rdy), .wr_data(ip_wr_data), .wr_data_en(ip_wr_data_en),
        .wr_data_end(ip_wr_data_end), .wr_data_mask(ip_wr_data_mask),
        .rd_data(ip_rd_data), .rd_data_valid(ip_rd_data_valid), .rd_data_end(ip_rd_data_end),
        .sr_req(1'b0), .ref_req(1'b0), .sr_ack(), .ref_ack(), .burst(1'b1),
        .O_ddr_addr(ddr_addr), .O_ddr_ba(ddr_bank), .O_ddr_cs_n(ddr_cs),
        .O_ddr_ras_n(ddr_ras), .O_ddr_cas_n(ddr_cas), .O_ddr_we_n(ddr_we),
        .O_ddr_clk(ddr_clk), .O_ddr_clk_n(ddr_clk_n), .O_ddr_cke(ddr_cke),
        .O_ddr_odt(ddr_odt), .O_ddr_reset_n(ddr_reset_n), .O_ddr_dqm(ddr_dm),
        .IO_ddr_dq(ddr_dq), .IO_ddr_dqs(ddr_dqs), .IO_ddr_dqs_n(ddr_dqs_n)
    );

    // Two-client port onto the IP: the network WRITER (w_*) and the line-buffer READER
    // (r_*) each have their own request latch and busy; the port alternates between them
    // one BL8 transaction at a time. See groovy_gwddr3_port.v for what this replaced.
    wire         w_wr, w_wr_beat, w_busy;
    wire [25:0]  w_addr;
    wire [15:0]  w_din;
    wire [127:0] w_din_beat;
    wire         r_rd, r_busy, r_data_ready;
    wire [25:0]  r_addr;
    wire [127:0] r_dout128;
    wire [15:0]  port_rd_cnt, port_wr_cnt, port_wait_max;
    groovy_gwddr3_port u_port (
        .uclk(pclk), .urst(ddr_rst), .init_calib_complete(init_calib_complete),
        .r_rd(r_rd), .r_addr(r_addr), .r_busy(r_busy),
        .r_data_ready(r_data_ready), .r_dout128(r_dout128),
        .w_wr(w_wr), .w_wr_beat(w_wr_beat), .w_addr(w_addr),
        .w_din(w_din), .w_din_beat(w_din_beat), .w_busy(w_busy),
        .cmd(ip_cmd), .cmd_en(ip_cmd_en), .cmd_ready(ip_cmd_ready), .ip_addr(ip_addr),
        .wr_data(ip_wr_data), .wr_data_en(ip_wr_data_en), .wr_data_end(ip_wr_data_end),
        .wr_data_mask(ip_wr_data_mask), .wr_data_rdy(ip_wr_data_rdy),
        .rd_data(ip_rd_data), .rd_data_valid(ip_rd_data_valid),
        .stat_rd(port_rd_cnt), .stat_wr(port_wr_cnt), .stat_wait_max(port_wait_max)
    );

    // =========================================================================
    // CDC: blit pixels (clk50m) -> async FIFO -> DDR3 writer (pclk)
    // =========================================================================
    // FIFO entry = {word_addr[25:0], rgb565[15:0]}. With the 8-pixel burst-coalescing
    // writer the drain easily outruns RX; depth 1024 gives generous burst headroom.
    localparam integer FIFO_DW = 26 + 16;     // 42
    localparam integer FIFO_AW = 10;          // 1024 entries

    wire                fifo_full, fifo_empty, fifo_rd_en;
    wire [FIFO_DW-1:0]  fifo_rdata;
    // pixel index (FB_ADDR_W=17) zero-extended to the 26-bit DDR3 word address.
    wire [25:0] pix_word_addr = BASE + {{(26-FB_ADDR_W){1'b0}}, fb_waddr};

    groovy_async_fifo #(.DATA_W(FIFO_DW), .ADDR_W(FIFO_AW)) u_fifo (
        .wr_clk(clk50m), .wr_rst(core_rst),
        .wr_en(fb_we), .wr_data({pix_word_addr, fb_wdata}), .full(fifo_full),
        .rd_clk(pclk), .rd_rst(ddr_rst),
        .rd_en(fifo_rd_en), .rd_data(fifo_rdata), .empty(fifo_empty));

    // count dropped pixels if the FIFO ever backs up (diagnostic; should stay 0).
    logic [15:0] drop_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) drop_cnt <= 16'd0;
        else if (fb_we & fifo_full) drop_cnt <= drop_cnt + 16'd1;

    wire         wr_active;
    groovy_ddr3_writer #(.AW(26), .FIFO_AW(FIFO_AW)) u_ddrwr (
        .clk(pclk), .rst(ddr_rst),
        .fifo_empty(fifo_empty), .fifo_rdata(fifo_rdata), .fifo_rd_en(fifo_rd_en),
        .wr(w_wr), .wr_beat(w_wr_beat), .addr(w_addr), .din(w_din), .din_beat(w_din_beat),
        .busy(w_busy), .active(wr_active));

    // =========================================================================
    // have_frame: latch the first received frame (clk50m), CDC into pclk + pix_clk.
    // =========================================================================
    logic have_frame;            // clk50m: set on the first frame_done, then sticky
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) have_frame <= 1'b0; else if (frame_done) have_frame <= 1'b1;

    // CDC into pclk (gates the reader's fetch + the port mux) and pix_clk (LEDs).
    logic [2:0] hf_p, hf_v;
    always_ff @(posedge pclk)    hf_p <= {hf_p[1:0], have_frame};
    always_ff @(posedge pix_clk) hf_v <= {hf_v[1:0], have_frame};
    wire have_frame_p = hf_p[2];

    // =========================================================================
    // 720p timing
    // =========================================================================
    wire        de, hsync, vsync, line_start, frame_start;
    wire [15:0] hcount, vcount;
    video_timing_gen u_timing (
        .clk(pix_clk), .rst(~hdmi_rst_n), .en(1'b1),
        .h_total(16'd1650), .h_active(OUT_W), .h_sync_begin(16'd1390), .h_sync_end(16'd1430),
        .v_total(16'd750),  .v_active(OUT_H), .v_sync_begin(16'd725),  .v_sync_end(16'd730),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),
        .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de),
        .line_start(line_start), .frame_start(frame_start));

    // vblank-start prefill pulse (top-of-frame cold-start fix - HW-proven).
    reg fetch_fs;
    always @(posedge pix_clk)
        fetch_fs <= (vcount == OUT_H) && (hcount == 16'd0);

    // delay de/hs/vs to match the line-buffer reader's 2-pix_clk pipeline
    reg [1:0] de_p, hs_p, vs_p;
    always @(posedge pix_clk) begin
        de_p <= {de_p[0], de};
        hs_p <= {hs_p[0], hsync};
        vs_p <= {vs_p[0], vsync};
    end
    wire de_o = de_p[1], hs_o = hs_p[1], vs_o = vs_p[1];

    // =========================================================================
    // line-buffer reader (pclk fetch / pix_clk scanout)
    // =========================================================================
    wire [15:0] pix565;
    wire        fetch_active;
    wire        dbg_lbwe; wire [15:0] dbg_lbdata, dbg_fillline, dbg_col; wire [2:0] dbg_fstate;
    wire [15:0] dbg_fe, dbg_pr, dbg_dr;
    groovy_linebuf_reader #(.LINE_W(1024), .LW_ADDR(10), .DDR_AW(26),
                            .SINGLE_WORD(0), .BURST_PLAIN(1), .FWAIT_TIMEOUT(250),
                            .H_REPL(HREP), .V_REPL(VREP), .H_SH(HSH)) u_lbr (
        .pix_clk(pix_clk), .pix_rst(~hdmi_rst_n),
        .h_active(SRC_W), .v_active(SRC_H),
        .hcount(hcount), .vcount(vcount), .de(de),
        .line_start(line_start), .frame_start(frame_start),
        .fetch_fs(fetch_fs),
        .pix_rgb565(pix565),
        // hold the reader's fetch in reset until the first frame has landed in DDR3.
        .pclk(pclk), .pclk_rst(~pclk_resetn | ~have_frame_p), .base_addr(BASE),
        .rd(r_rd), .addr(r_addr),
        .busy(r_busy), .data_ready(r_data_ready),
        .dout128(r_dout128), .dout(16'd0),
        .fetch_active(fetch_active),
        .dbg_lbwe(dbg_lbwe), .dbg_lbdata(dbg_lbdata), .dbg_fillline(dbg_fillline),
        .dbg_col(dbg_col), .dbg_fstate(dbg_fstate),
        .dbg_fe(dbg_fe), .dbg_pr(dbg_pr), .dbg_dr(dbg_dr));

    // =========================================================================
    // RGB565 -> RGB888 + DVI_TX
    // =========================================================================
    // HDMI_SELFTEST=1 feeds the encoder a logic-generated picture (the hdmi_probe_top
    // grey ramp + two colour patches) instead of the reader, everything else running:
    // separates "the rest of the design disturbs HDMI" from "the reader's pixels do".
    localparam HDMI_SELFTEST = 1'b0;
    wire [8:0]  st_sx   = hcount[10:2];
    wire [16:0] st_prod = st_sx * 8'd205;
    wire [7:0]  st_v    = st_prod[15:8];
    reg  [15:0] st_p1, st_p2;
    always @(posedge pix_clk) begin                       // 2 stages = the reader's latency
        if (vcount < 16'd480)       st_p1 <= {st_v[7:3], st_v[7:2], st_v[7:3]};
        else if (hcount < 16'd640)  st_p1 <= 16'h9011;
        else                        st_p1 <= 16'h99F3;
        st_p2 <= st_p1;
    end
    wire [15:0] dvi565 = HDMI_SELFTEST ? st_p2 : pix565;
    wire [4:0] r5 = dvi565[15:11];
    wire [5:0] g6 = dvi565[10:5];
    wire [4:0] b5 = dvi565[4:0];
    wire [7:0] r8 = {r5, r5[4:2]};
    wire [7:0] g8 = {g6, g6[5:4]};
    wire [7:0] b8 = {b5, b5[4:2]};

    DVI_TX_Top u_dvi (
        .I_rst_n(hdmi_rst_n),
        .I_serial_clk(serial_clk),
        .I_rgb_clk(pix_clk),
        .I_rgb_vs(vs_o), .I_rgb_hs(hs_o), .I_rgb_de(de_o),
        .I_rgb_r(r8), .I_rgb_g(g8), .I_rgb_b(b8),
        .O_tmds_clk_p(O_tmds_clk_p),   .O_tmds_clk_n(O_tmds_clk_n),
        .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n));

    // =========================================================================
    // UART debug (sys_clk). Minimal but useful for the bring-up:
    //   RD=frames received  DP=dropped pixels (FIFO full)  HF=have_frame
    //   NL=max source line fetched last frame (~00F0=240 = fetch keeps up)
    //   RY=udp ready  SE=rx_seen  CO=max fetch column (~0140=320)
    //   FD/SD/FK/SK = frame-stability probes (below)  PW=longest DDR3 port wait, cycles
    // =========================================================================
    reg [15:0] nl_max=0, nl_hold=0; reg vs_e=0;
    always @(posedge pix_clk) begin
        vs_e <= vsync;
        if (vsync && !vs_e) begin nl_hold <= nl_max; nl_max <= 0; end
        else if (dbg_fillline > nl_max) nl_max <= dbg_fillline;
    end
    reg [15:0] co_max=0;
    always @(posedge pclk) if (dbg_col > co_max) co_max <= dbg_col;

    // Static-picture stability probes: an order-dependent checksum (ck*33 + word: an XOR sum cancels on
    // XOR-structured test patterns, and a rotate-by-1 repeats every 32 words) of every frame at two
    // points, and how many frames differed from the one before. With a static picture
    // both DIFF counters must stand still; whichever moves locates a flicker.
    //   FK/FD = the words the reader fetched from DDR3 into its line buffers (pclk)
    //   SK/SD = the pixels handed to the DVI encoder during active video (pix_clk)
    reg [31:0] fck=0, fck_prev=0; reg [15:0] fdiff=0, fe_q=0;
    always @(posedge pclk) begin
        fe_q <= dbg_fe;
        if (dbg_fe != fe_q) begin
            if (fck != fck_prev) fdiff <= fdiff + 16'd1;
            fck_prev <= fck;  fck <= 32'd0;
        end else if (dbg_lbwe) fck <= {fck[26:0], 5'd0} + fck + {16'd0, dbg_lbdata};
    end
    reg [31:0] sck=0, sck_prev=0; reg [15:0] sdiff=0;
    always @(posedge pix_clk) begin
        if (frame_start) begin
            if (sck != sck_prev) sdiff <= sdiff + 16'd1;
            sck_prev <= sck;  sck <= 32'd0;
        end else if (de_o) sck <= {sck[26:0], 5'd0} + sck + {16'd0, pix565};
    end

    // count received frames (clk50m) -> sys_clk
    logic [15:0] frame_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) frame_cnt <= 16'd0; else if (frame_done) frame_cnt <= frame_cnt + 16'd1;

    reg [15:0] q_fc, q_dp, q_nl, q_co; reg q_hf, q_ry, q_se;
    reg [15:0] q_fd, q_sd, q_fk, q_sk, q_pw;
    always @(posedge sys_clk) begin
        q_fc<=frame_cnt; q_dp<=drop_cnt; q_nl<=nl_hold; q_co<=co_max;
        q_hf<=have_frame; q_ry<=ready; q_se<=rx_seen;
        q_fd<=fdiff; q_sd<=sdiff; q_fk<=fck_prev[15:0]^fck_prev[31:16];
        q_sk<=sck_prev[15:0]^sck_prev[31:16]; q_pw<=port_wait_max;
    end

    wire [7:0] tx_din; wire tx_wr, tx_busy;
    uart_tx_V2 #(.clk_freq(27_000_000), .uart_freq(115200)) u_dbgtx (
        .clk(sys_clk), .din(tx_din), .wr_en(tx_wr), .tx_busy(tx_busy), .tx_p(uart_txp));
    function [7:0] hxd; input [3:0] n; hxd = (n<4'd10)?(8'h30+n):(8'h41+n-4'd10); endfunction
    localparam [7:0] DBGLEN = 8'd90;
    reg [7:0] di=0; reg [7:0] dtx=0; reg dwr=0; reg [2:0] dst=0; reg [23:0] dhold=0;
    reg [7:0] dlb;
    always @(*) begin
        case (di)
            0:dlb="R";1:dlb="D";2:dlb="=";
            3:dlb=hxd(q_fc[15:12]);4:dlb=hxd(q_fc[11:8]);5:dlb=hxd(q_fc[7:4]);6:dlb=hxd(q_fc[3:0]);7:dlb=" ";
            8:dlb="D";9:dlb="P";10:dlb="=";
            11:dlb=hxd(q_dp[15:12]);12:dlb=hxd(q_dp[11:8]);13:dlb=hxd(q_dp[7:4]);14:dlb=hxd(q_dp[3:0]);15:dlb=" ";
            16:dlb="H";17:dlb="F";18:dlb="=";19:dlb=hxd({3'b0,q_hf});20:dlb=" ";
            21:dlb="N";22:dlb="L";23:dlb="=";
            24:dlb=hxd(q_nl[15:12]);25:dlb=hxd(q_nl[11:8]);26:dlb=hxd(q_nl[7:4]);27:dlb=hxd(q_nl[3:0]);28:dlb=" ";
            29:dlb="C";30:dlb="O";31:dlb="=";
            32:dlb=hxd(q_co[15:12]);33:dlb=hxd(q_co[11:8]);34:dlb=hxd(q_co[7:4]);35:dlb=hxd(q_co[3:0]);36:dlb=" ";
            37:dlb="R";38:dlb="Y";39:dlb="=";40:dlb=hxd({3'b0,q_ry});41:dlb=" ";
            42:dlb="S";43:dlb="E";44:dlb="=";45:dlb=hxd({3'b0,q_se});46:dlb=" ";
            47:dlb="F";48:dlb="D";49:dlb="=";
            50:dlb=hxd(q_fd[15:12]);51:dlb=hxd(q_fd[11:8]);52:dlb=hxd(q_fd[7:4]);53:dlb=hxd(q_fd[3:0]);54:dlb=" ";
            55:dlb="S";56:dlb="D";57:dlb="=";
            58:dlb=hxd(q_sd[15:12]);59:dlb=hxd(q_sd[11:8]);60:dlb=hxd(q_sd[7:4]);61:dlb=hxd(q_sd[3:0]);62:dlb=" ";
            63:dlb="F";64:dlb="K";65:dlb="=";
            66:dlb=hxd(q_fk[15:12]);67:dlb=hxd(q_fk[11:8]);68:dlb=hxd(q_fk[7:4]);69:dlb=hxd(q_fk[3:0]);70:dlb=" ";
            71:dlb="S";72:dlb="K";73:dlb="=";
            74:dlb=hxd(q_sk[15:12]);75:dlb=hxd(q_sk[11:8]);76:dlb=hxd(q_sk[7:4]);77:dlb=hxd(q_sk[3:0]);78:dlb=" ";
            79:dlb="P";80:dlb="W";81:dlb="=";
            82:dlb=hxd(q_pw[15:12]);83:dlb=hxd(q_pw[11:8]);84:dlb=hxd(q_pw[7:4]);85:dlb=hxd(q_pw[3:0]);
            88:dlb=8'h0D;89:dlb=8'h0A;default:dlb=" ";
        endcase
    end
    always @(posedge sys_clk) begin
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
        endcase
    end
    assign tx_din=dtx; assign tx_wr=dwr;

    // =========================================================================
    // LEDs (board-number convention; see led_board_map / tang-led-mapping)
    //   board0 = init_calib_complete   board1 = ready (udp)   board2 = have_frame
    //   board3 = rx_seen               board4 = fetch_active  board5 = heartbeat
    // =========================================================================
    wire [5:0] board;
    assign board[0] = init_calib_complete;
    assign board[1] = ready;
    assign board[2] = hf_v[2];
    assign board[3] = rx_seen;
    assign board[4] = fetch_active;
    assign board[5] = heartbeat;
    assign led = ~{ board[0], board[2], board[4], board[3], board[5], board[1] };

endmodule

`default_nettype wire
