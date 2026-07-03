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
//            -> groovy_lineram_wr (map to {slot,col}, ring lap-guard)
//            -> groovy_lineram (NLINES-slot dual-port BRAM ring)
//            -> groovy_lineram_scan (pix_clk, H/V replicate, read chases write)
//            -> DVI_TX -> HDMI
//
// Beam-race control reused conceptually from the HW-proven full/ BRAM path:
//   - write_line (groovy_lineram_wr) = producer progress.
//   - read src_line (groovy_lineram_scan) = consumer progress.
//   - reader is released per frame once write_line >= MARGIN (SYNC/FILL), then the
//     ring lap-guard + read-behind keep them a few lines apart (STREAM). Underrun
//     (read catches write) shows the stale ring line and flags status (never stall).
//
// This first cut fixes the geometry to 320x240 -> 4x3 -> 1280x720 (like gwddr3net) to
// isolate the ring from the dynamic-geometry work. RGB565. DVI_TX is encrypted Gowin
// IP (not committed).
`include "rmii.svh"
`default_nettype none

module gwline_top (
    input  wire        clk,          // 27 MHz, H11
    input  wire        rst,          // active-low button, T10
    rmii               netrmii,
    output wire        phyrst,
    output wire        O_tmds_clk_p,
    output wire        O_tmds_clk_n,
    output wire [2:0]  O_tmds_data_p,
    output wire [2:0]  O_tmds_data_n,
    output wire [5:0]  led,
    output wire        uart_txp      // M11 -> /dev/ttyUSB1 @115200 (debug)
);
    localparam [15:0] OUR_PORT = 16'd32100;

    // ====================== geometry ===================================
    localparam [15:0] SRC_W = 16'd320, SRC_H = 16'd240;
    localparam [15:0] OUT_W = 16'd1280, OUT_H = 16'd720;
    localparam integer HREP = 4, VREP = 3, HSH = 2;
    localparam integer NATIVE_PIX = 320*240;
    localparam integer FB_ADDR_W  = 17;

    // ---- line ring sizing ----
    // 32 lines = the drift/jitter budget the PoC (tools/beamrace_poc.py) validated for
    // paced beam-race up to 500ppm PC<->Tang clock skew. NLINES must be a power of two
    // (slot = line mod NLINES via low bits).
    localparam integer NLINES  = 32;     // ring depth (drift/jitter tolerance)
    localparam integer LNSEL_W = 5;      // clog2(NLINES)
    localparam integer LINE_W  = 512;    // >= widest native line (320 here); param
    localparam integer COL_W   = 10;     // clog2(LINE_W)
    localparam integer MARGIN  = 16;     // reader release: writer this many lines in (mid-ring)

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
    logic        rx_head_rdy;
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
        .rx_data_rdy_i(1'b1),        .rx_data_av_o(rx_data_av), .rx_data_o(rx_data),
        .tx_ip_i(tx_ip), .tx_src_port_i(tx_src_port), .tx_dst_port_i(tx_dst_port),
        .tx_req_i(tx_req), .tx_data_i(tx_data), .tx_data_av_i(tx_data_av),
        .tx_req_rdy_o(tx_req_rdy), .tx_data_rdy_o(tx_data_rdy)
    );

    logic [31:0] req_ip;  logic [15:0] req_port;  logic [2:0] hstate;
    always_ff @(posedge clk50m or negedge ready) begin
        if (!ready) begin hstate <= 3'd0; rx_head_rdy <= 1'b0; end
        else begin
            rx_head_rdy <= 1'b0;
            case (hstate)
                0: if (rx_head_av) begin rx_head_rdy <= 1'b1; hstate <= 1; end
                1: begin rx_head_rdy <= 1'b1; req_ip   <= rx_head;        hstate <= 2; end
                2: begin rx_head_rdy <= 1'b1;                             hstate <= 3; end
                3: begin rx_head_rdy <= 1'b1; req_port <= rx_head[31:16]; hstate <= 4; end
                4: if (!rx_head_av) hstate <= 0;
                default: hstate <= 0;
            endcase
        end
    end

    wire core_rst = ~ready;
    logic [22:0] ck50;  logic rx_seen;
    always_ff @(posedge clk50m or negedge rst)
        if (!rst) begin ck50 <= 0; rx_seen <= 0; end
        else begin ck50 <= ck50 + 23'd1; if (rx_data_av) rx_seen <= 1'b1; end

    logic [7:0] sdat;  logic sv, psv;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) begin sv <= 0; psv <= 0; sdat <= 0; end
        else begin sv <= rx_data_av; sdat <= rx_data; psv <= sv; end
    wire p_valid = sv, p_sop = sv & ~psv, p_eop = sv & ~rx_data_av;
    wire [7:0] p_data = sdat;

    wire        init_valid, close_valid, get_status_valid, blit_valid;
    wire        get_features_valid, get_switchres_valid, switchres_valid, session_active;
    wire [7:0]  i_lz4, i_sr, i_sc, i_rgb;
    wire [31:0] blit_frame;  wire [15:0] blit_vsync;
    wire [63:0] sr_pclk;
    wire [15:0] sr_ha, sr_hb, sr_he, sr_ht, sr_va, sr_vb, sr_ve, sr_vt;
    wire        blitting;  wire [2:0] cfg_bpp;

    groovy_packet_parser u_parser (
        .clk(clk50m), .rst(core_rst),
        .in_valid(p_valid & ~blitting), .in_data(p_data),
        .in_sop(p_sop & ~blitting), .in_eop(p_eop & ~blitting),
        .cmd_valid(), .cmd(), .bad_packet(),
        .close_valid(close_valid), .init_valid(init_valid),
        .switchres_valid(switchres_valid), .audio_valid(), .get_status_valid(get_status_valid),
        .blit_valid(blit_valid), .get_version_valid(),
        .get_features_valid(get_features_valid), .get_switchres_valid(get_switchres_valid),
        .init_lz4(i_lz4), .init_sound_rate(i_sr), .init_sound_chan(i_sc), .init_rgb_mode(i_rgb),
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

    // ---- ACK + FEATURES + SWITCHRES (keep the host handshake happy) ----
    wire        ack_start, ack_busy, ack_valid, ack_last, ack_ready;
    wire [7:0]  ack_data;  wire [31:0] ack_frame_echo, ack_fpga_frame;
    wire [15:0] ack_vsync_echo, ack_fpga_vcount;  wire [7:0] ack_status;
    logic [15:0] vcount_50;               // real scanout raster line, CDC'd to clk50m
    wire [7:0]  beamrace_status;

    groovy_ack_policy u_policy (
        .clk(clk50m), .rst(core_rst),
        .init_valid(init_valid), .get_status_valid(get_status_valid),
        .blit_valid(blit_valid), .blit_frame(blit_frame), .blit_vsync(blit_vsync),
        .fpga_frame(32'd0), .fpga_vcount(vcount_50), .status_bits(beamrace_status),
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
    localparam DEBUG_FIXED_DEST = 1'b0;
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

    // ---- BLIT pixel accumulator (clk50m) ----
    wire                  fb_we, frame_done;
    wire [FB_ADDR_W-1:0]  fb_waddr;   // (unused for the ring; kept for the port)
    wire [15:0]           fb_wdata;
    // register bytes_len (a NATIVE_PIX*cfg_bpp product) so it presents a STABLE value
    // to blit_rx's byte-count compare instead of a fresh multiply on the clk50m path.
    logic [31:0]          bytes_len;
    always_ff @(posedge clk50m) bytes_len <= NATIVE_PIX * cfg_bpp;
    groovy_blit_rx #(.ADDR_W(FB_ADDR_W)) u_blit (
        .clk(clk50m), .rst(core_rst),
        .start(blit_valid), .bytes_len(bytes_len), .bytespp(cfg_bpp),
        .in_valid(p_valid & blitting), .in_data(p_data),
        .blitting(blitting), .frame_done(frame_done), .bytes_recv(),
        .wr_en(fb_we), .wr_addr(fb_waddr), .wr_data(fb_wdata));

    // ---- ELASTIC FIFO: blit_rx (net speed, no back-pressure) -> ring mapper --------
    // blit_rx emits pixels as fast as UDP delivers them; the ring mapper can only place
    // a pixel when the lap-guard allows (paced by the raster). This FIFO absorbs the
    // burst so a lap-stall HOLDS pixels instead of dropping them. Both sides are clk50m
    // -> synchronous FIFO (no CDC). Depth 2^9 = 512 pixels (~1.6 native lines) of slack
    // to absorb open-loop send-rate jitter now that the reader can't lap the writer.
    wire        fifo_full, fifo_empty, fifo_overflow, mapper_pop;
    wire [15:0] fifo_head;
    groovy_sync_fifo #(.DATA_W(16), .ADDR_W(9)) u_wr_fifo (
        .clk(clk50m), .rst(core_rst),
        .wr_en(fb_we), .wr_data(fb_wdata), .full(fifo_full),
        .rd_en(mapper_pop), .rd_data(fifo_head), .empty(fifo_empty),
        .overflow(fifo_overflow));

    // =========================================================================
    // PIXEL CLOCK (720p) - the only PLL now (no DDR3 clocks)
    // =========================================================================
    wire serial_clk, tmds_lock, pix_clk;
    rpll_tmds u_tmdspll (.clkin(clk), .clkout(serial_clk), .lock(tmds_lock));
    wire hdmi_rst_n = rst & tmds_lock;
    CLKDIV u_div (.RESETN(hdmi_rst_n), .HCLKIN(serial_clk), .CLKOUT(pix_clk), .CALIB(1'b1));
    defparam u_div.DIV_MODE = "5";
    defparam u_div.GSREN    = "false";

    // =========================================================================
    // BEAM-RACE CONTROL: write_line (producer) vs read src_line (consumer).
    // CDC read_line into clk50m for the ring lap-guard; write_line into pix_clk for
    // the reader release. frame_start = blit_valid resets both progress counters.
    // =========================================================================
    wire [15:0] scan_srcline;                 // pix_clk: current source line scanned
    logic       have_frame;                   // pix_clk (defined below); CDC'd here
    logic [1:0] hf_50;  logic [15:0] read_line_50;
    // SYNC/FILL: until have_frame, the reader is NOT genuinely consuming lines (its
    // scan_srcline just tracks the free-running raster). Feeding that garbage to the
    // writer's lap-guard falsely stalls the fill. So HOLD read_line at 0 until
    // have_frame -> the writer primes the ring freely; once scanout is live it tracks
    // the real read line. (This is the SYNC/FILL -> STREAM handoff.)
    always_ff @(posedge clk50m) begin
        hf_50 <= {hf_50[0], have_frame};
        read_line_50 <= hf_50[1] ? scan_srcline : 16'd0;
    end

    wire        rw_we;  wire [LNSEL_W-1:0] rw_slot;  wire [COL_W-1:0] rw_col;
    wire [15:0] rw_data;  wire [15:0] write_line;  wire rw_stall;
    groovy_lineram_wr #(.NLINES(NLINES), .LNSEL_W(LNSEL_W), .COL_W(COL_W), .DATA_W(16)) u_lrw (
        .clk(clk50m), .rst(core_rst), .frame_start(blit_valid),
        .in_valid(~fifo_empty), .in_data(fifo_head), .pop(mapper_pop), .native_w(SRC_W),
        .read_line(read_line_50),
        .we(rw_we), .w_slot(rw_slot), .w_col(rw_col), .w_data(rw_data),
        .write_line(write_line), .stall(rw_stall));

    // ---- the line ring (dual-port BRAM) ----
    wire [LNSEL_W-1:0] r_slot;  wire [COL_W-1:0] r_col;  wire [15:0] r_data;
    groovy_lineram #(.NLINES(NLINES), .LINE_W(LINE_W), .DATA_W(16),
                     .LNSEL_W(LNSEL_W), .COL_W(COL_W)) u_ring (
        .wr_clk(clk50m), .we(rw_we), .w_slot(rw_slot), .w_col(rw_col), .w_data(rw_data),
        .rd_clk(pix_clk), .r_slot(r_slot), .r_col(r_col), .r_data(r_data));

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

    // have_frame: SYNC/FILL gate - release scanout once the writer is MARGIN lines in.
    // (write_line CDC'd to pix_clk.) Sticky per session; re-armed by the ring guards.
    logic [15:0] wline_px;
    always_ff @(posedge pix_clk) wline_px <= write_line;
    // have_frame declared up top (for the write-side lap-guard CDC). SYNC/FILL: set it
    // once the writer has primed MARGIN lines. Sticky per session.
    always_ff @(posedge pix_clk or negedge hdmi_rst_n)
        if (!hdmi_rst_n) have_frame <= 1'b0;
        else if (wline_px >= MARGIN[15:0]) have_frame <= 1'b1;

    // reader active only after fill; else output black (avoids showing empty ring)
    wire scan_en = have_frame;

    // =========================================================================
    // ring scanout reader (pix_clk): H/V replicate, read chases write
    // =========================================================================
    wire [15:0] pix565;  wire de_o, hs_o, vs_o;
    groovy_lineram_scan #(.NLINES(NLINES), .LINE_W(LINE_W), .DATA_W(16),
                          .LNSEL_W(LNSEL_W), .COL_W(COL_W), .H_REPL(HREP), .H_SH(HSH),
                          .V_REPL(VREP), .SRC_H(SRC_H)) u_scan (
        .pix_clk(pix_clk), .pix_rst(~hdmi_rst_n | ~scan_en),
        .hcount(hcount), .vcount(vcount), .de(de), .hsync(hsync), .vsync(vsync),
        .frame_start(frame_start),                 // raster top-of-frame -> monotonic index
        .max_line(wline_px),                       // clamp read <= write (underrun guard)
        .r_slot(r_slot), .r_col(r_col), .r_data(r_data),
        .pix_rgb565(pix565), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o),
        .src_line(scan_srcline));

    // real vCount ACK: the scanout source line into clk50m (beam-race feedback).
    always_ff @(posedge clk50m) vcount_50 <= scan_srcline;

    // underrun: read line reached the write line (host fell behind). STATUS ONLY, so
    // it does not need to be fast/combinational - PIPELINE the 16-bit compare (it was
    // a -2.8ns pix_clk critical path as a single-cycle compare feeding ur). Register
    // the operands, do the compare next cycle, then latch ur. A cycle of latency on a
    // status bit is irrelevant.
    logic [15:0] sl_q, wl_q;  logic de_o_q;  logic under_c;
    always_ff @(posedge pix_clk) begin
        sl_q <= scan_srcline; wl_q <= wline_px; de_o_q <= de_o;
        under_c <= (sl_q >= wl_q);          // registered compare
    end
    logic ur;
    always_ff @(posedge pix_clk or negedge hdmi_rst_n)
        if (!hdmi_rst_n) ur <= 1'b0;
        else if (frame_start) ur <= 1'b0;
        else if (de_o_q && have_frame && under_c) ur <= 1'b1;
    logic [1:0] ur_s;
    always_ff @(posedge clk50m) ur_s <= {ur_s[0], ur};
    assign beamrace_status = {7'd0, ur_s[1]};

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
    // UART debug (clk domain): RD=frames WL=write_line GP=write-read_gap RL=read_line
    //   HF=have_frame UR=underrun OV=fifo_overflow_count(/frame) SE=rx_seen
    // =========================================================================
    logic [15:0] frame_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) frame_cnt <= 16'd0; else if (frame_done) frame_cnt <= frame_cnt + 16'd1;

    // GP = the write-read GAP (write_line - read_line_50), the beam-race health metric:
    // under monotonic counters WL/RL climb+wrap so their raw values are useless, but the
    // GAP should stay small and bounded (~MARGIN). A huge/growing gap = reader stalled or
    // writer sprinting; the clamp keeps read<=write so the gap is small and positive.
    logic [15:0] gp;
    always_ff @(posedge clk50m) gp <= write_line - read_line_50;

    // OV as a per-frame saturating nibble counter (cleared on blit_valid): how many FIFO
    // overflow events this frame, not just a sticky "ever".
    logic [3:0] ov_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) ov_cnt <= 4'd0;
        else if (blit_valid) ov_cnt <= 4'd0;
        else if (fifo_overflow && ov_cnt != 4'hF) ov_cnt <= ov_cnt + 4'd1;

    reg [15:0] q_fc, q_wl, q_rl, q_gp; reg q_hf, q_ur, q_se; reg [3:0] q_ov;
    always @(posedge clk) begin
        q_fc<=frame_cnt; q_wl<=write_line; q_rl<=read_line_50; q_gp<=gp;
        q_hf<=have_frame; q_ur<=ur_s[1]; q_ov<=ov_cnt; q_se<=rx_seen;
    end

    wire [7:0] tx_din; wire tx_wr, tx_busy;
    uart_tx_V2 #(.clk_freq(27_000_000), .uart_freq(115200)) u_dbgtx (
        .clk(clk), .din(tx_din), .wr_en(tx_wr), .tx_busy(tx_busy), .tx_p(uart_txp));
    function [7:0] hxd; input [3:0] n; hxd = (n<4'd10)?(8'h30+n):(8'h41+n-4'd10); endfunction
    localparam [7:0] DBGLEN = 8'd60;
    reg [7:0] di=0, dtx=0; reg dwr=0; reg [2:0] dst=0; reg [23:0] dhold=0; reg [7:0] dlb;
    always @(*) begin
        case (di)
            0:dlb="R";1:dlb="D";2:dlb="=";
            3:dlb=hxd(q_fc[15:12]);4:dlb=hxd(q_fc[11:8]);5:dlb=hxd(q_fc[7:4]);6:dlb=hxd(q_fc[3:0]);7:dlb=" ";
            8:dlb="W";9:dlb="L";10:dlb="=";
            11:dlb=hxd(q_wl[15:12]);12:dlb=hxd(q_wl[11:8]);13:dlb=hxd(q_wl[7:4]);14:dlb=hxd(q_wl[3:0]);15:dlb=" ";
            16:dlb="G";17:dlb="P";18:dlb="=";
            19:dlb=hxd(q_gp[15:12]);20:dlb=hxd(q_gp[11:8]);21:dlb=hxd(q_gp[7:4]);22:dlb=hxd(q_gp[3:0]);23:dlb=" ";
            24:dlb="R";25:dlb="L";26:dlb="=";
            27:dlb=hxd(q_rl[15:12]);28:dlb=hxd(q_rl[11:8]);29:dlb=hxd(q_rl[7:4]);30:dlb=hxd(q_rl[3:0]);31:dlb=" ";
            32:dlb="H";33:dlb="F";34:dlb="=";35:dlb=hxd({3'b0,q_hf});36:dlb=" ";
            37:dlb="U";38:dlb="R";39:dlb="=";40:dlb=hxd({3'b0,q_ur});41:dlb=" ";
            42:dlb="O";43:dlb="V";44:dlb="=";45:dlb=hxd(q_ov);46:dlb=" ";
            47:dlb="S";48:dlb="E";49:dlb="=";50:dlb=hxd({3'b0,q_se});
            58:dlb=8'h0D;59:dlb=8'h0A;default:dlb=" ";
        endcase
    end
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
        endcase
    end
    assign tx_din=dtx; assign tx_wr=dwr;

    // =========================================================================
    // LEDs (board-number convention)
    //   0=ready 1=tmds_lock 2=have_frame 3=rx_seen 4=underrun 5=heartbeat
    // =========================================================================
    wire [5:0] board;
    assign board[0] = ready;
    assign board[1] = tmds_lock;
    assign board[2] = have_frame;
    assign board[3] = rx_seen;
    assign board[4] = ur_s[1];
    assign board[5] = heartbeat;
    assign led = ~{ board[0], board[2], board[4], board[3], board[5], board[1] };

endmodule

`default_nettype wire
