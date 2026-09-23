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
    localparam integer MARGIN  = 16;     // writer overwrite-guard window width (steady state)
    // START_THRESHOLD: lines the writer must have queued before the video raster is
    // allowed to start counting AT ALL (see raster_en below) - deliberately separate
    // from MARGIN (the steady-state guard window) so shrinking the startup wait does
    // NOT also shrink the ring's runtime overwrite protection. Kept equal to MARGIN
    // for now (same "half-ring" comfort margin); can be tuned independently later.
    localparam integer START_THRESHOLD = 16;

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
        .rx_data_rdy_i(1'b1),        .rx_data_av_o(rx_data_av), .rx_data_o(rx_data),
        .tx_ip_i(tx_ip), .tx_src_port_i(tx_src_port), .tx_dst_port_i(tx_dst_port),
        .tx_req_i(tx_req), .tx_data_i(tx_data), .tx_data_av_i(tx_data_av),
        .tx_req_rdy_o(tx_req_rdy), .tx_data_rdy_o(tx_data_rdy),
        .rx_reject_o(rx_reject)
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

    // VIDEO RESET (2026-07-19): CMD_INIT (init_valid, already sent at the start of every
    // test session) now also resets the ring writer + upstream FIFO + slot_line ground
    // truth. Without this, groovy_lineram's actual BRAM content (and slot_line) persisted
    // across tests - a new test could inherit stale pixels from a PREVIOUS test, making it
    // impossible to tell "this test's send is broken" from "this is leftover content from
    // before" (exactly the ambiguity hit while debugging sf2.png/hbars this session). This
    // does NOT clear the ring's actual BRAM cells (no bulk-write path for that yet) but
    // DOES reset slot_line to the FFFF sentinel, so SL=FFFF unambiguously means "not
    // rewritten since the last CMD_INIT" even if the physical BRAM cell still has old data.
    wire video_rst = core_rst | init_valid;

    // ---- BLIT pixel accumulator (clk50m) ----
    wire                  fb_we, frame_done;
    wire [FB_ADDR_W-1:0]  fb_waddr;   // (unused for the ring; kept for the port)
    wire [15:0]           fb_wdata;
    // register bytes_len (a NATIVE_PIX*cfg_bpp product) so it presents a STABLE value
    // to blit_rx's byte-count compare instead of a fresh multiply on the clk50m path.
    logic [31:0]          bytes_len;
    always_ff @(posedge clk50m) bytes_len <= NATIVE_PIX * cfg_bpp;
    wire blit_timed_out;
    // TIMEOUT_CYCLES = 8ms @ 50MHz. The default (1ms) was too tight: a plain sleep()-paced
    // test sender's OWN scheduler jitter occasionally exceeded 1ms between lines, which
    // made the FPGA's OWN watchdog fire on jitter, not a real loss. 8ms stays well under
    // one video frame (16.7ms - a real stall should resolve within a frame) while giving
    // generous headroom over normal OS/network gaps.
    groovy_blit_rx #(.ADDR_W(FB_ADDR_W), .TIMEOUT_CYCLES(400_000)) u_blit (
        .clk(clk50m), .rst(core_rst),
        .start(blit_valid), .bytes_len(bytes_len), .bytespp(cfg_bpp),
        .in_valid(p_valid & blitting), .in_data(p_data),
        .blitting(blitting), .frame_done(frame_done), .bytes_recv(),
        .timed_out(blit_timed_out),
        .wr_en(fb_we), .wr_addr(fb_waddr), .wr_data(fb_wdata));

    // ---- ELASTIC FIFO: blit_rx (net speed, no back-pressure) -> ring mapper --------
    // blit_rx emits pixels as fast as UDP delivers them; the ring mapper can only place
    // a pixel when the lap-guard allows (paced by the raster). This FIFO absorbs the
    // burst so a lap-stall HOLDS pixels instead of dropping them. Both sides are clk50m
    // -> synchronous FIFO (no CDC). Depth 2^12 = 4096 pixels (~12.8 native lines):
    // ADDR_W=9 (512 px, ~1.6 line) was FAR too shallow - a real lap-guard stall (writer
    // waiting for the reader to advance) drained it in a fraction of a line, so nearly
    // EVERY line overflowed (HW: OV saturated immediately on hbars). groovy_lineram_wr's
    // fifo_overflow port (2026-07-18 fix) stops a dropped pixel from wedging write_line
    // forever, but a pixel that's dropped still isn't the RIGHT pixel in the ring - if
    // most lines drop pixels, most of the ring is stale/wrong data, not really fixed.
    // 4096 gives enough margin to absorb a realistic stall without dropping at all in
    // the tested send rates, so overflow (and the recovery path) becomes the rare
    // fallback it was meant to be, not the common case.
    wire        fifo_full, fifo_empty, fifo_overflow, mapper_pop;
    wire [15:0] fifo_head;
    wire [12:0] fifo_level;   // ADDR_W+1 = 13 bits (0..4096)
    groovy_sync_fifo #(.DATA_W(16), .ADDR_W(12)) u_wr_fifo (
        .clk(clk50m), .rst(video_rst),
        .wr_en(fb_we), .wr_data(fb_wdata), .full(fifo_full),
        .rd_en(mapper_pop), .rd_data(fifo_head), .empty(fifo_empty),
        .overflow(fifo_overflow), .fifo_level(fifo_level));

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
    wire [15:0] scan_srcline;                 // pix_clk: TRUE raster line (for the ACK)
    wire [15:0] scan_readguard;               // pix_clk: CLAMPED read line (for the guard)
    logic       have_frame;                   // pix_clk (defined below); CDC'd here

    // STARTUP FIX (2026-08-02 stabilization pass): the video raster used to run FREELY
    // from power-up, completely decoupled from the network - so by the time the writer
    // had queued enough lines to prime, the raster could be ANYWHERE in its own 60Hz
    // cycle, and (write_line's own guard was OFF until have_frame) the writer kept
    // filling unguarded for however long remained until the raster's next frame_start -
    // up to a full 16.7ms video frame. Measured on a real udp.sv-driven testbench
    // (sim/tb/gwline_ring_e2e_tb.v): the writer accumulated ~80 lines of lead (2.5x
    // NLINES) before the guard ever engaged, saturating the upstream elastic FIFO and
    // corrupting the START of the next network frame once guard_en finally kicked in.
    // FIX: HOLD the raster itself at (hcount=0,vcount=0) - video_timing_gen's `en` port
    // already supports this cleanly - until the writer has queued START_THRESHOLD
    // lines, AND activate the writer's guard from that same moment (not only once
    // have_frame later goes high). Two effects: (1) the writer can never accumulate
    // more than the guard's own MARGIN before being throttled, even during startup;
    // (2) the raster's first-ever frame_start, once released, is guaranteed to be a
    // clean (0,0) start - no risk of the old "arbitrary raster phase" bug (see the
    // ALTERNATIVE note below have_frame's assignment for the remaining, deliberately
    // NOT taken, wrinkle this leaves).
    logic [15:0] wline_px;
    always_ff @(posedge pix_clk) wline_px <= write_line;

    logic raster_en;
    always_ff @(posedge pix_clk or negedge hdmi_rst_n)
        if (!hdmi_rst_n) raster_en <= 1'b0;
        else if (video_reset_px) raster_en <= 1'b0;
        else if (wline_px >= START_THRESHOLD[15:0]) raster_en <= 1'b1;

    logic [1:0] hf_50;  logic [15:0] read_line_50;
    // The writer's overwrite guard uses the CLAMPED read line (read<=write) - NOT the free
    // raster, which sprints ahead and makes the guard stall by fits (FIFO overflow). Held
    // at 0 until raster_en (not have_frame - see the startup-fix comment above: the guard
    // must engage the moment the raster is allowed to start counting at all, not only
    // once display has actually been released) so read_line=0 is used as an implicit
    // "reader hasn't really moved yet" reference, capping the writer's lead at MARGIN.
    logic [1:0] rasteren_50;
    always_ff @(posedge clk50m) begin
        rasteren_50 <= {rasteren_50[0], raster_en};
        hf_50 <= {hf_50[0], have_frame};
        read_line_50 <= rasteren_50[1] ? scan_readguard : 16'd0;
    end

    wire        rw_we;  wire [LNSEL_W-1:0] rw_slot;  wire [COL_W-1:0] rw_col;
    wire [15:0] rw_data;  wire [15:0] write_line;  wire rw_stall;
    wire        sl_we;  wire [LNSEL_W-1:0] sl_slot;  wire [15:0] sl_line;
    wire [LNSEL_W-1:0] target_slot_at_write;  wire [12:0] fifo_level_at_write;
    wire [15:0] cur_line;
    wire [23:0] guard_stuck_cycles;
    groovy_lineram_wr #(.NLINES(NLINES), .LNSEL_W(LNSEL_W), .COL_W(COL_W), .DATA_W(16),
                        .MARGIN(MARGIN), .ADDR_W_FIFO(12)) u_lrw (
        .clk(clk50m), .rst(video_rst), .frame_start(blit_valid),
        .in_valid(~fifo_empty), .in_data(fifo_head), .pop(mapper_pop), .native_w(SRC_W),
        .fifo_overflow(fifo_overflow), .fifo_level(fifo_level),
        .read_line(read_line_50), .guard_en(rasteren_50[1]),
        .we(rw_we), .w_slot(rw_slot), .w_col(rw_col), .w_data(rw_data),
        .write_line(write_line), .stall(rw_stall),
        .sl_we(sl_we), .sl_slot(sl_slot), .sl_line(sl_line),
        .target_slot_at_write(target_slot_at_write),
        .fifo_level_at_write(fifo_level_at_write),
        .cur_line(cur_line), .guard_stuck_cycles(guard_stuck_cycles));

    // ---- the line ring (dual-port BRAM) ----
    wire [LNSEL_W-1:0] r_slot;  wire [COL_W-1:0] r_col;  wire [15:0] r_data;
    groovy_lineram #(.NLINES(NLINES), .LINE_W(LINE_W), .DATA_W(16),
                     .LNSEL_W(LNSEL_W), .COL_W(COL_W)) u_ring (
        .wr_clk(clk50m), .we(rw_we), .w_slot(rw_slot), .w_col(rw_col), .w_data(rw_data),
        .rd_clk(pix_clk), .r_slot(r_slot), .r_col(r_col), .r_data(r_data));

    // DIAGNOSTIC + CORRECTNESS (2026-07-19): per-slot ground truth ring, same dual-port
    // shape as u_ring above (write clk50m, read pix_clk, no CDC synchronizer needed).
    // groovy_lineram_wr's fifo_overflow recovery advances write_line even for a DROPPED
    // pixel, so write_line reaching SRC_H no longer proves the ring's physical content
    // is fresh - a slot that missed its rewrite this lap still holds an OLDER source
    // line (line - k*NLINES). This lets groovy_lineram_scan compare what a slot ACTUALLY
    // holds against what it's about to display and reject (freeze) a stale slot instead
    // of showing it as if it were correct - reproduced on HW: sf2.png showed a mid-frame
    // block of lines repeating from the very START of display (SL != RL, off by an exact
    // multiple of NLINES - confirmed via the UART SL= field before this fix existed).
    wire [15:0] slot_actual_line;
    groovy_slotline_ram #(.NLINES(NLINES), .LNSEL_W(LNSEL_W)) u_slotline (
        .wr_clk(clk50m), .we(sl_we), .w_slot(sl_slot), .w_line(sl_line),
        .rd_clk(pix_clk), .r_slot(r_slot), .r_line(slot_actual_line));

    // =========================================================================
    // 720p timing
    // =========================================================================
    wire        de, hsync, vsync, line_start, frame_start;
    wire [15:0] hcount, vcount;
    video_timing_gen u_timing (
        .clk(pix_clk), .rst(~hdmi_rst_n), .en(raster_en),
        .h_total(16'd1650), .h_active(OUT_W), .h_sync_begin(16'd1390), .h_sync_end(16'd1430),
        .v_total(16'd750),  .v_active(OUT_H), .v_sync_begin(16'd725),  .v_sync_end(16'd730),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),
        .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de),
        .line_start(line_start), .frame_start(frame_start));

    // DIAGNOSTIC (2026-07-19): the VIDEO raster loops at a fixed 60Hz (frame_start,
    // vcount==0) totally independent of the network - count these loops (toggle+CDC to
    // clk50m, same pattern as blit_valid/init_valid above) and compare to RD (network
    // frame_done count). If VF climbs much faster than RD, the video raster is looping
    // (and re-arming disp_line via net_frame_start/its own frame_start) many times per
    // SINGLE network frame's write - exactly the mismatch that would explain the ring
    // lap-guard staying saturated (ST=FFFF) even though the nominal send rate matches
    // the raster's nominal per-line consumption rate on paper.
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

    // rx_reject is already clk50m (same domain as udp_inst) - no CDC needed.
    logic [15:0] rj_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) rj_cnt <= 16'd0;
        else if (rx_reject && rj_cnt != 16'hFFFF) rj_cnt <= rj_cnt + 16'd1;

    // CDC blit_valid (clk50m, a new NETWORK frame) into pix_clk as a 1-cycle pulse.
    // The writer's frame_start IS blit_valid - it resets line/write_line to 0 the
    // instant a new BLIT header arrives, with NO regard for where the video raster
    // currently is. Without this, groovy_lineram_scan only reset disp_line on ITS OWN
    // frame_start (vcount==0, a free-running ~60Hz event with no phase relationship to
    // the network), so a new source frame could start writing at line 0 while disp_line
    // was still latched near the END of the previous frame - the writer then chases
    // read_line (CDC'd from the stale disp_line) up by NLINES and hits the lap-guard,
    // stalling write_line partway through EVERY frame after the first (reproduced on HW
    // with hbars: WL froze at the same ~159/240 on frame 2+, RD stuck at 1, independent
    // of the sender's pacing - see next-session-beamrace.md). Fix: let a new network
    // frame also kick the reader's frame_start, so both sides realign to 0 together.
    // blit_valid is a SINGLE-CYCLE clk50m strobe (~20ns); pix_clk (74.25MHz, ~13.5ns, no
    // phase relationship to clk50m) risks sampling right past a plain pulse - toggle it
    // instead (a LEVEL change, not an edge) so any pix_clk sample is guaranteed to catch
    // it eventually, then edge-detect the synchronized toggle for a clean 1-cycle pulse.
    logic blit_valid_tgl;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) blit_valid_tgl <= 1'b0;
        else if (blit_valid) blit_valid_tgl <= ~blit_valid_tgl;
    logic [2:0] blit_valid_tgl_px;
    always_ff @(posedge pix_clk) blit_valid_tgl_px <= {blit_valid_tgl_px[1:0], blit_valid_tgl};
    wire net_frame_start = blit_valid_tgl_px[2] ^ blit_valid_tgl_px[1];

    // CDC init_valid (clk50m, CMD_INIT = "new test session") into pix_clk, same
    // toggle+sync technique as blit_valid above (single-cycle strobe, no phase relation
    // to pix_clk). Drives have_frame back to 0 so a new test can't inherit "sticky"
    // scanout release from a PREVIOUS test's fill level (2026-07-19: without this,
    // have_frame stayed 1 across tests, masking whether a fresh test really re-filled
    // the ring or was showing leftover content from before).
    logic init_valid_tgl;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) init_valid_tgl <= 1'b0;
        else if (init_valid) init_valid_tgl <= ~init_valid_tgl;
    logic [2:0] init_valid_tgl_px;
    always_ff @(posedge pix_clk) init_valid_tgl_px <= {init_valid_tgl_px[1:0], init_valid_tgl};
    wire video_reset_px = init_valid_tgl_px[2] ^ init_valid_tgl_px[1];

    // SYNC/FILL gate, REWORKED 2026-08-02 (see the startup-fix comment above raster_en's
    // declaration for the full history/measurement). Previously this stage alone had to
    // defend against the raster being at an ARBITRARY phase when priming completed
    // (2026-07-19 fix: wait for primed AND the next real frame_start). That defense is
    // now free: the raster itself does not even START counting until raster_en (which
    // gates video_timing_gen's `en`), so its counter is GUARANTEED to be sitting at
    // (hcount=0,vcount=0) - having never advanced - the instant raster_en goes high.
    // The first frame_start after that is therefore always a clean, on-time (0,0) start;
    // no arbitrary-phase risk remains, so have_frame can simply follow raster_en's own
    // first frame_start with no separate priming logic.
    //
    // ALTERNATIVE NOT TAKEN (flagged per discussion): have_frame <= raster_en directly
    // (skip waiting for frame_start entirely) would release scanout up to one full video
    // frame (~16.7ms) EARLIER, but risks showing/losing the first real image if any
    // downstream stage (DVI_TX, the CDC'd read_line_50 pipeline) still assumes at least
    // one raster cycle has elapsed before de/hsync/vsync are trustworthy. Worth trying if
    // that startup latency ever matters, but not validated - keep the frame_start wait
    // as the safe default for now.
    always_ff @(posedge pix_clk or negedge hdmi_rst_n)
        if (!hdmi_rst_n) have_frame <= 1'b0;
        else if (video_reset_px) have_frame <= 1'b0;
        else if (raster_en && frame_start) have_frame <= 1'b1;

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
        .frame_start(frame_start | net_frame_start), // raster top-of-frame OR new net frame
        .max_line(wline_px),                       // clamp read <= write (underrun guard)
        .r_slot(r_slot), .r_col(r_col), .r_data(r_data),
        .slot_actual_line(slot_actual_line),
        .pix_rgb565(pix565), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o),
        .src_line(scan_srcline), .read_guard(scan_readguard));

    // real vCount ACK: the scanout source line into clk50m (beam-race feedback).
    always_ff @(posedge clk50m) vcount_50 <= scan_srcline;

    // CDC slot_actual_line -> clk50m for the UART SL= field (status only, no timing
    // pressure - a plain register sync is enough for a slow-changing display value,
    // same style as wline_px/vcount_50 above).
    logic [15:0] slot_actual_line_50;
    always_ff @(posedge clk50m) slot_actual_line_50 <= slot_actual_line;

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

    // DIAGNOSTIC (2026-07-19): how often is the writer actually held off by the ring
    // lap-guard (rw_stall) vs how often is the FIFO full/empty? sf2.png on real HW showed
    // slot_actual_line wildly diverging from read_line (e.g. RL=5 SL=229) even though the
    // exact same nominal send rate produced ZERO overflow in RTL simulation - this narrows
    // down WHERE the real-vs-simulated gap is: if rw_stall is asserted a large fraction of
    // the time, the reader (raster) is genuinely running far ahead of a real writer that
    // can't keep up (a true throughput problem, not a logic bug); if it's rarely asserted,
    // the FIFO is instead absorbing bursts and still overflowing (a burstiness problem).
    // Gate on ~fifo_empty: stall only means something while the writer actually HAS a
    // pixel waiting to place. Without this gate, ST/FF kept counting through the idle
    // gap after write_line reached SRC_H (writer at rest, waiting for the next frame),
    // saturating both counters regardless of whether the frame's ACTIVE portion ever
    // really stalled - useless for telling a real throughput problem from a healthy one.
    logic [15:0] stall_cnt, fifo_full_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) begin stall_cnt <= 16'd0; fifo_full_cnt <= 16'd0; end
        else if (blit_valid) begin stall_cnt <= 16'd0; fifo_full_cnt <= 16'd0; end
        else begin
            if (rw_stall && ~fifo_empty && stall_cnt != 16'hFFFF) stall_cnt <= stall_cnt + 16'd1;
            if (fifo_full && fifo_full_cnt != 16'hFFFF) fifo_full_cnt <= fifo_full_cnt + 16'd1;
        end

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
    //   TO=blit_rx timeout count (cumulative, proves the UDP-loss watchdog is firing)
    //   TL=tmds_lock (1=HDMI PLL locked; if 0, no video will ever show regardless of RD/WL)
    //   WO=write_line at the FIRST fifo overflow this frame (FFFF=none yet this frame)
    //   SL=ground truth: source line the CURRENTLY-CLAMPED ring slot actually holds
    //     (compare to RL - if SL != RL, that slot is STALE, never really rewritten this
    //     frame; FFFF = never written since the last CMD_INIT video reset)
    //   ST=cycles/frame the writer was held by the RING LAP-GUARD while it had a pixel
    //     waiting (rw_stall && ~fifo_empty)
    //   FF=cycles/frame the upstream FIFO (blit_rx->mapper) was FULL - both cleared on
    //     each new blit_valid; distinguishes a real writer-can't-keep-up throughput
    //     problem (ST high) from FIFO absorbing bursts that still overflow (FF high,
    //     ST low) - added 2026-07-19 to explain why sf2.png showed SL wildly diverging
    //     from RL on real HW despite zero overflow at the same nominal rate in sim.
    //   VF=cumulative count of VIDEO raster loops (frame_start, 60Hz, independent of the
    //     network) - compare to RD (network frame_done count): if VF climbs much faster
    //     than RD, the reader is looping many times per single (slower) network frame,
    //     re-arming disp_line/read_line repeatedly while the writer is still mid-frame -
    //     a real rate mismatch between the fixed-60Hz reader and the variable-latency
    //     network writer, not a throughput/logic bug in the ring itself.
    //   RJ=cumulative count of udp.sv's OWN internal FIFO-full rejects (rx_reject_o, a
    //     Groovy_Tang diagnostic add to the vendored udp.sv core) - a frame silently
    //     dropped INSIDE the UDP stack because ITS internal 8KB data FIFO / 32-entry
    //     head FIFO was still full from a slow downstream consumer, indistinguishable
    //     from real wire packet loss via TO= alone. If RJ climbs, the bottleneck is our
    //     own consumption rate backing up into the vendor stack, not the network.
    //   FL=upstream FIFO fill level (words) AT THE MOMENT of the most recent write
    //     decision (real write or a dropped-pixel recovery) - from
    //     groovy_lineram_wr.v's 2026-07-20 rewrite; shows how close to full the
    //     4096-word elastic buffer was right when that decision happened, not just
    //     after the fact via full/empty edges.
    //   TS=ring slot that write decision targeted (line mod NLINES) - paired with FL
    //     to see WHICH slot was being written when the buffer was nearly full.
    // =========================================================================
    logic [15:0] frame_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) frame_cnt <= 16'd0; else if (frame_done) frame_cnt <= frame_cnt + 16'd1;

    // TO: cumulative count of blit_rx timeouts (a lost-datagram frame was aborted+re-armed
    // instead of wedging forever). Never cleared (except reset) - it's a lifetime counter,
    // the proof the watchdog is doing its job.
    logic [15:0] to_cnt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) to_cnt <= 16'd0;
        else if (blit_timed_out && to_cnt != 16'hFFFF) to_cnt <= to_cnt + 16'd1;

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

    // WO = write_line at the FIRST fifo_overflow this frame (0xFFFF = none yet this
    // frame). Diagnostic (2026-07-18): OV alone proves overflows happen, but not WHEN
    // in the frame - WO pinpoints whether they cluster at the very start (initial
    // ring-fill racing the lap-guard before the reader has really got going) or spread
    // evenly (a genuine sustained send-rate mismatch).
    logic [15:0] wo_line;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) wo_line <= 16'hFFFF;
        else if (blit_valid) wo_line <= 16'hFFFF;
        else if (fifo_overflow && wo_line == 16'hFFFF) wo_line <= write_line;

    // tmds_lock lives in the serial_clk domain; a 2-flop sync into `clk` is enough for a
    // slow status bit read by the UART. Exposed as TL= so we can tell "no HDMI lock"
    // apart from "locked but nothing displayed" without decoding the scrambled Dock LEDs.
    reg [1:0] tmds_lock_sync;
    always @(posedge clk) tmds_lock_sync <= {tmds_lock_sync[0], tmds_lock};

    reg [15:0] q_fc, q_wl, q_rl, q_gp, q_to, q_wo, q_sl, q_st, q_ff, q_vf, q_rj; reg q_hf, q_ur, q_se, q_tl; reg [3:0] q_ov;
    reg [15:0] q_fl; reg [15:0] q_ts;
    // DIAGNOSTIC (2026-08-09 HW investigation): CL=cur_line (in-progress writer line,
    // updates even mid-stall unlike WL) GS=guard_stuck_cycles (consecutive cycles the
    // guard has held THIS line, saturating - distinguishes a brief stall from a real
    // wedge that write_line/stall alone can't show).
    reg [15:0] q_cl; reg [23:0] q_gs;
    always @(posedge clk) begin
        q_fc<=frame_cnt; q_wl<=write_line; q_rl<=read_line_50; q_gp<=gp;
        q_hf<=have_frame; q_ur<=ur_s[1]; q_ov<=ov_cnt; q_se<=rx_seen; q_to<=to_cnt;
        q_tl<=tmds_lock_sync[1]; q_wo<=wo_line; q_sl<=slot_actual_line_50;
        q_st<=stall_cnt; q_ff<=fifo_full_cnt; q_vf<=vframe_cnt; q_rj<=rj_cnt;
        q_fl<={3'b0,fifo_level_at_write}; q_ts<={{(16-LNSEL_W){1'b0}},target_slot_at_write};
        q_cl<=cur_line; q_gs<=guard_stuck_cycles;
    end

    wire [7:0] tx_din; wire tx_wr, tx_busy;
    uart_tx_V2 #(.clk_freq(27_000_000), .uart_freq(115200)) u_dbgtx (
        .clk(clk), .din(tx_din), .wr_en(tx_wr), .tx_busy(tx_busy), .tx_p(uart_txp));
    function [7:0] hxd; input [3:0] n; hxd = (n<4'd10)?(8'h30+n):(8'h41+n-4'd10); endfunction
    localparam [7:0] DBGLEN = 8'd166;
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
            47:dlb="S";48:dlb="E";49:dlb="=";50:dlb=hxd({3'b0,q_se});51:dlb=" ";
            52:dlb="T";53:dlb="O";54:dlb="=";
            55:dlb=hxd(q_to[15:12]);56:dlb=hxd(q_to[11:8]);57:dlb=hxd(q_to[7:4]);58:dlb=hxd(q_to[3:0]);59:dlb=" ";
            60:dlb="T";61:dlb="L";62:dlb="=";63:dlb=hxd({3'b0,q_tl});64:dlb=" ";
            65:dlb="W";66:dlb="O";67:dlb="=";
            68:dlb=hxd(q_wo[15:12]);69:dlb=hxd(q_wo[11:8]);70:dlb=hxd(q_wo[7:4]);71:dlb=hxd(q_wo[3:0]);72:dlb=" ";
            73:dlb="S";74:dlb="L";75:dlb="=";
            76:dlb=hxd(q_sl[15:12]);77:dlb=hxd(q_sl[11:8]);78:dlb=hxd(q_sl[7:4]);79:dlb=hxd(q_sl[3:0]);80:dlb=" ";
            81:dlb="S";82:dlb="T";83:dlb="=";
            84:dlb=hxd(q_st[15:12]);85:dlb=hxd(q_st[11:8]);86:dlb=hxd(q_st[7:4]);87:dlb=hxd(q_st[3:0]);88:dlb=" ";
            89:dlb="F";90:dlb="F";91:dlb="=";
            92:dlb=hxd(q_ff[15:12]);93:dlb=hxd(q_ff[11:8]);94:dlb=hxd(q_ff[7:4]);95:dlb=hxd(q_ff[3:0]);96:dlb=" ";
            97:dlb="V";98:dlb="F";99:dlb="=";
            100:dlb=hxd(q_vf[15:12]);101:dlb=hxd(q_vf[11:8]);102:dlb=hxd(q_vf[7:4]);103:dlb=hxd(q_vf[3:0]);104:dlb=" ";
            105:dlb="R";106:dlb="J";107:dlb="=";
            108:dlb=hxd(q_rj[15:12]);109:dlb=hxd(q_rj[11:8]);110:dlb=hxd(q_rj[7:4]);111:dlb=hxd(q_rj[3:0]);112:dlb=" ";
            113:dlb="F";114:dlb="L";115:dlb="=";
            116:dlb=hxd(q_fl[15:12]);117:dlb=hxd(q_fl[11:8]);118:dlb=hxd(q_fl[7:4]);119:dlb=hxd(q_fl[3:0]);120:dlb=" ";
            121:dlb="T";122:dlb="S";123:dlb="=";
            124:dlb=hxd(q_ts[15:12]);125:dlb=hxd(q_ts[11:8]);126:dlb=hxd(q_ts[7:4]);127:dlb=hxd(q_ts[3:0]);128:dlb=" ";
            129:dlb="C";130:dlb="L";131:dlb="=";
            132:dlb=hxd(q_cl[15:12]);133:dlb=hxd(q_cl[11:8]);134:dlb=hxd(q_cl[7:4]);135:dlb=hxd(q_cl[3:0]);136:dlb=" ";
            137:dlb="G";138:dlb="S";139:dlb="=";
            140:dlb=hxd(q_gs[23:20]);141:dlb=hxd(q_gs[19:16]);142:dlb=hxd(q_gs[15:12]);143:dlb=hxd(q_gs[11:8]);144:dlb=hxd(q_gs[7:4]);145:dlb=hxd(q_gs[3:0]);
            164:dlb=8'h0D;165:dlb=8'h0A;default:dlb=" ";
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
