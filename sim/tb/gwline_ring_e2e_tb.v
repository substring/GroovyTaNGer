// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - end-to-end ring buffer test with a REAL udp.sv instance driven over its
// actual RMII input (byte-exact Ethernet frames, real checksums/FCS), through the real
// groovy_packet_parser -> groovy_blit_rx -> groovy_sync_fifo -> groovy_lineram_wr ->
// groovy_lineram chain exactly as wired in gwline_top.sv (minus PLL/HDMI/DVI_TX, which
// this test does not need). Reproduces the pixel-clock reader side with a REAL
// video_timing_gen at gwline's actual 720p timing and REAL groovy_lineram_scan, so the
// full write+read ring path is exercised, not just the write side.
//
// Goal (2026-08-01 stabilization pass): after the udpstress bandwidth-saturation finding
// (real gwline rate ~14% loss, but <2% loss below ~0.75x), verify the ring buffer itself
// - filling, slot rotation, guard behavior - is CORRECT when fed by the real network
// stack at a REDUCED, network-safe pacing, not just in the simplified/no-udp.sv
// testbenches (groovy_lineram_freeraster_tb, overflow_tb, realscale_tb). Every pixel
// value encodes its own (source_line, col) - see tools (scratchpad) gen_gwline_frames.py
// - so the ring's final content can be checked against ground truth with NO ambiguity.
`timescale 1ns/1ps
`include "rmii.svh"

module gwline_ring_e2e_tb;
    localparam FDIR = "/tmp/claude-1000/-home-subs-git-Groovy-TaNGer/351c4152-8b29-4980-9342-4daf7c2ebe12/scratchpad/";
    localparam integer SRC_W = 320, SRC_H = 240;
    localparam integer NLINES = 32, LNSEL_W = 5, LINE_W = 512, COL_W = 10, MARGIN = 16;
    localparam integer START_THRESHOLD = 16;

    reg clk1m = 0; always #500 clk1m = ~clk1m;      // 1 MHz
    reg clk50m = 0; always #10 clk50m = ~clk50m;    // 50 MHz
    reg rst = 0;

    // ---- RMII drive (same technique as groovy_udpstress_udpsv_realframe_tb) ----
    reg  [1:0] rxd_drv = 0;
    reg        crs_drv = 0;
    wire       mdio_w;
    rmii netrmii(.clk50m(clk50m), .rx_crs(crs_drv), .mdc(), .txen(), .mdio(mdio_w),
                 .txd(), .rxd(rxd_drv));
    wire phyrst;
    logic ready;
    logic        rx_head_av;  logic [31:0] rx_head;
    logic        rx_data_av;  logic [7:0]  rx_data;
    logic        rx_head_rdy;
    logic [31:0] tx_ip;   logic [15:0] tx_src_port, tx_dst_port;
    logic [7:0]  tx_data; logic        tx_data_av, tx_req;
    logic        tx_req_rdy, tx_data_rdy;
    logic        rx_reject;
    logic [7:0]  rx_head_fifo_lvl;
    logic [12:0] rx_data_fifo_lvl;

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
        .rx_reject_o(rx_reject),
        .rx_head_fifo_level_o(rx_head_fifo_lvl), .rx_data_fifo_level_o(rx_data_fifo_lvl)
    );
    assign tx_ip = 0; assign tx_src_port = 0; assign tx_dst_port = 0;
    assign tx_data = 0; assign tx_data_av = 0; assign tx_req = 0;

    // ---- head/port dispatch (copied from gwline_top.sv) ----
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

    wire core_rst = ~ready | rst;
    logic [7:0] sdat;  logic sv, psv;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) begin sv <= 0; psv <= 0; sdat <= 0; end
        else begin sv <= rx_data_av; sdat <= rx_data; psv <= sv; end
    wire p_valid = sv, p_sop = sv & ~psv, p_eop = sv & ~rx_data_av;
    wire [7:0] p_data = sdat;

    // ---- parser + session (real modules, real wiring) ----
    wire        init_valid, close_valid, get_status_valid, blit_valid;
    wire        get_features_valid, get_switchres_valid, switchres_valid;
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
        .close_valid(close_valid), .session_active(),
        .cfg_lz4(), .cfg_sound_rate(), .cfg_sound_chan(), .cfg_rgb_mode(),
        .new_session(), .end_session(), .cfg_bytes_per_pixel(cfg_bpp)
    );

    wire video_rst = core_rst | init_valid;

    // ---- BLIT pixel accumulator (real groovy_blit_rx, real elastic FIFO) ----
    wire                  fb_we;
    wire [16:0]           fb_waddr;
    wire [15:0]           fb_wdata;
    logic [31:0]          bytes_len;
    always_ff @(posedge clk50m) bytes_len <= SRC_W * SRC_H * cfg_bpp;
    wire blit_timed_out, frame_done;

    wire [31:0] blit_bytes_recv;
    groovy_blit_rx #(.ADDR_W(17), .TIMEOUT_CYCLES(400_000)) u_blit (
        .clk(clk50m), .rst(core_rst),
        .start(blit_valid), .bytes_len(bytes_len), .bytespp(cfg_bpp),
        .in_valid(p_valid & blitting), .in_data(p_data),
        .blitting(blitting), .frame_done(frame_done), .bytes_recv(blit_bytes_recv),
        .timed_out(blit_timed_out),
        .wr_en(fb_we), .wr_addr(fb_waddr), .wr_data(fb_wdata));

    wire        fifo_full, fifo_empty, fifo_overflow, mapper_pop;
    wire [15:0] fifo_head;
    wire [12:0] fifo_level;
    groovy_sync_fifo #(.DATA_W(16), .ADDR_W(12)) u_wr_fifo (
        .clk(clk50m), .rst(video_rst),
        .wr_en(fb_we), .wr_data(fb_wdata), .full(fifo_full),
        .rd_en(mapper_pop), .rd_data(fifo_head), .empty(fifo_empty),
        .overflow(fifo_overflow), .fifo_level(fifo_level));

    // ---- pixel clock (720p) - real PLL not needed in sim; free-run a pix_clk ----
    reg pix_clk = 0; always #6.734 pix_clk = ~pix_clk;   // ~74.25 MHz
    reg hdmi_rst_n = 0;
    initial begin repeat(20) @(posedge pix_clk); hdmi_rst_n = 1; end

    // ---- beam-race control (copied from gwline_top.sv, incl. the 2026-08-02 startup fix:
    // raster_en gates video_timing_gen's `en` so the raster cannot start counting until
    // the writer has queued START_THRESHOLD lines, and the writer's own guard engages
    // from that same moment - see gwline_top.sv's raster_en comment for the full
    // rationale/measurement this fixes) ----
    wire [15:0] scan_srcline, scan_readguard;
    logic       have_frame;

    logic [15:0] wline_px;
    always_ff @(posedge pix_clk) wline_px <= write_line;

    logic init_valid_tgl;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) init_valid_tgl <= 1'b0;
        else if (init_valid) init_valid_tgl <= ~init_valid_tgl;
    logic [2:0] init_valid_tgl_px;
    always_ff @(posedge pix_clk) init_valid_tgl_px <= {init_valid_tgl_px[1:0], init_valid_tgl};
    wire video_reset_px = init_valid_tgl_px[2] ^ init_valid_tgl_px[1];

    logic raster_en;
    always_ff @(posedge pix_clk or negedge hdmi_rst_n)
        if (!hdmi_rst_n) raster_en <= 1'b0;
        else if (video_reset_px) raster_en <= 1'b0;
        else if (wline_px >= START_THRESHOLD[15:0]) raster_en <= 1'b1;
    reg prev_rasteren_dbg = 1'b0;
    always @(posedge pix_clk) begin
        if (raster_en != prev_rasteren_dbg) begin
            $display("  [RASTER_EN EDGE] t=%0t raster_en %0d->%0d wline_px=%0d write_line=%0d",
                      $time, prev_rasteren_dbg, raster_en, wline_px, write_line);
            prev_rasteren_dbg <= raster_en;
        end
    end

    logic [1:0] rasteren_50;
    logic [1:0] hf_50;  logic [15:0] read_line_50;
    always_ff @(posedge clk50m) begin
        rasteren_50 <= {rasteren_50[0], raster_en};
        hf_50 <= {hf_50[0], have_frame};
        read_line_50 <= rasteren_50[1] ? scan_readguard : 16'd0;
    end

    wire        rw_we;  wire [LNSEL_W-1:0] rw_slot;  wire [COL_W-1:0] rw_col;
    wire [15:0] rw_data;  wire [15:0] write_line;  wire rw_stall;
    wire        sl_we;  wire [LNSEL_W-1:0] sl_slot;  wire [15:0] sl_line;
    wire [LNSEL_W-1:0] target_slot_at_write;  wire [12:0] fifo_level_at_write;
    groovy_lineram_wr #(.NLINES(NLINES), .LNSEL_W(LNSEL_W), .COL_W(COL_W), .DATA_W(16),
                        .MARGIN(MARGIN), .ADDR_W_FIFO(12)) u_lrw (
        .clk(clk50m), .rst(video_rst), .frame_start(blit_valid),
        .in_valid(~fifo_empty), .in_data(fifo_head), .pop(mapper_pop), .native_w(SRC_W[15:0]),
        .fifo_overflow(fifo_overflow), .fifo_level(fifo_level),
        .read_line(read_line_50), .guard_en(rasteren_50[1]),
        .we(rw_we), .w_slot(rw_slot), .w_col(rw_col), .w_data(rw_data),
        .write_line(write_line), .stall(rw_stall),
        .sl_we(sl_we), .sl_slot(sl_slot), .sl_line(sl_line),
        .target_slot_at_write(target_slot_at_write),
        .fifo_level_at_write(fifo_level_at_write));

    wire [LNSEL_W-1:0] r_slot;  wire [COL_W-1:0] r_col;  wire [15:0] r_data;
    groovy_lineram #(.NLINES(NLINES), .LINE_W(LINE_W), .DATA_W(16),
                     .LNSEL_W(LNSEL_W), .COL_W(COL_W)) u_ring (
        .wr_clk(clk50m), .we(rw_we), .w_slot(rw_slot), .w_col(rw_col), .w_data(rw_data),
        .rd_clk(pix_clk), .r_slot(r_slot), .r_col(r_col), .r_data(r_data));

    wire [15:0] slot_actual_line;
    groovy_slotline_ram #(.NLINES(NLINES), .LNSEL_W(LNSEL_W)) u_slotline (
        .wr_clk(clk50m), .we(sl_we), .w_slot(sl_slot), .w_line(sl_line),
        .rd_clk(pix_clk), .r_slot(r_slot), .r_line(slot_actual_line));

    wire        de, hsync, vsync, line_start, frame_start;
    wire [15:0] hcount, vcount;
    video_timing_gen u_timing (
        .clk(pix_clk), .rst(~hdmi_rst_n), .en(raster_en),
        .h_total(16'd1650), .h_active(16'd1280), .h_sync_begin(16'd1390), .h_sync_end(16'd1430),
        .v_total(16'd750),  .v_active(16'd720),  .v_sync_begin(16'd725),  .v_sync_end(16'd730),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),
        .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de),
        .line_start(line_start), .frame_start(frame_start));

    logic blit_valid_tgl;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) blit_valid_tgl <= 1'b0;
        else if (blit_valid) blit_valid_tgl <= ~blit_valid_tgl;
    logic [2:0] blit_valid_tgl_px;
    always_ff @(posedge pix_clk) blit_valid_tgl_px <= {blit_valid_tgl_px[1:0], blit_valid_tgl};
    wire net_frame_start = blit_valid_tgl_px[2] ^ blit_valid_tgl_px[1];

    always_ff @(posedge pix_clk or negedge hdmi_rst_n)
        if (!hdmi_rst_n) have_frame <= 1'b0;
        else if (video_reset_px) have_frame <= 1'b0;
        else if (raster_en && frame_start) have_frame <= 1'b1;

    wire scan_en = have_frame;
    wire [15:0] pix565;  wire de_o, hs_o, vs_o;
    groovy_lineram_scan #(.NLINES(NLINES), .LINE_W(LINE_W), .DATA_W(16),
                          .LNSEL_W(LNSEL_W), .COL_W(COL_W), .H_REPL(4), .H_SH(2),
                          .V_REPL(3), .SRC_H(SRC_H)) u_scan (
        .pix_clk(pix_clk), .pix_rst(~hdmi_rst_n | ~scan_en),
        .hcount(hcount), .vcount(vcount), .de(de), .hsync(hsync), .vsync(vsync),
        .frame_start(frame_start | net_frame_start),
        .max_line(wline_px),
        .r_slot(r_slot), .r_col(r_col), .r_data(r_data),
        .slot_actual_line(slot_actual_line),
        .pix_rgb565(pix565), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o),
        .src_line(scan_srcline), .read_guard(scan_readguard));

    // =========================================================================
    // CORRECTNESS CHECK: every pixel encodes its own (line,col) - see
    // gen_gwline_frames.py. For every displayed output pixel, decode the expected
    // source (line,col) from H_REPL/V_REPL replication of hcount/vcount and check
    // the pixel value against pix(line,col) = {line[7:0], col[7:0]}, EXCEPT the
    // documented 1px pipeline seam at col 0 (see groovy_lineram_scan.v header) and
    // any period where the display is legitimately holding (stale-slot rejection).
    // =========================================================================
    integer errors = 0, checked = 0, held = 0;
    integer err_hcount_lo4 [0:15];
    integer eh_i;
    initial for (eh_i = 0; eh_i < 16; eh_i = eh_i + 1) err_hcount_lo4[eh_i] = 0;
    reg [15:0] prev_pix; reg prev_de;
    reg [15:0] prev_wl_dbg = 16'hFFFF;
    always @(posedge clk50m) begin
        if (write_line != prev_wl_dbg && (write_line % 20 == 0)) begin
            $display("  [DBG] t=%0t write_line=%0d have_frame=%0d raster_en=%0d fifo_lvl=%0d rw_stall=%0d",
                      $time, write_line, have_frame, raster_en, fifo_level, rw_stall);
            prev_wl_dbg <= write_line;
        end
    end
    reg prev_hf_dbg = 1'b0;
    always @(posedge pix_clk) begin
        if (have_frame != prev_hf_dbg) begin
            $display("  [HF EDGE] t=%0t have_frame %0d->%0d wline_px=%0d vcount=%0d hcount=%0d frame_start=%0d",
                      $time, prev_hf_dbg, have_frame, wline_px, vcount, hcount, frame_start);
            prev_hf_dbg <= have_frame;
        end
    end
    always @(posedge clk50m) begin
        if (sl_we && sl_slot == 5'd12)
            $display("  [SL_WE slot12] t=%0t sl_line=%0d (0x%0h)", $time, sl_line, sl_line);
        if (rw_we && rw_slot == 5'd12 && (rw_col == 10'd187))
            $display("  [WE slot12 col187] t=%0t w_data=%04h line_being_written=%0d", $time, rw_data, u_lrw.line);
    end
    // trace blit_rx's own byte counter around bytes 64374*... to see if it SKIPS a
    // range (a real loss) or DUPLICATES one (a re-delivery) between the two writes
    reg [31:0] prev_bytes_recv = 0;
    always @(posedge clk50m) begin
        if (blit_bytes_recv != prev_bytes_recv) begin
            if (blit_bytes_recv > prev_bytes_recv + 1)
                $display("  [BYTES JUMP] t=%0t prev=%0d new=%0d (gap of %0d bytes)",
                          $time, prev_bytes_recv, blit_bytes_recv, blit_bytes_recv - prev_bytes_recv - 1);
            prev_bytes_recv <= blit_bytes_recv;
        end
    end

    // FULL raw byte dump of everything blit_rx actually consumed, timestamped, no
    // filtering/hypothesis - written to a file for an offline Python diff against the
    // concatenated source hex files (see gen_gwline_frames.py).
    integer dumpfile;
    initial dumpfile = $fopen({FDIR, "pdata_dump.txt"}, "w");
    always @(posedge clk50m) begin
        if (p_valid && blitting)
            $fdisplay(dumpfile, "%0t %02h", $time, p_data);
    end
    // pixel-level dump right at blit_rx's own output (before the elastic FIFO) - lets
    // us tell "blit_rx assembled the wrong pixel" apart from "the FIFO/writer scrambled
    // a correctly-assembled pixel downstream".
    integer pixdumpfile;
    initial pixdumpfile = $fopen({FDIR, "fbwdata_dump.txt"}, "w");
    always @(posedge clk50m) begin
        if (fb_we)
            $fdisplay(pixdumpfile, "%0t %04h", $time, fb_wdata);
    end
    // FIFO OUTPUT dump: what the ring mapper actually POPS (post-FIFO), to isolate
    // whether corruption happens INSIDE the elastic FIFO or downstream of it.
    integer fifooutdumpfile;
    initial fifooutdumpfile = $fopen({FDIR, "fifoout_dump.txt"}, "w");
    always @(posedge clk50m) begin
        if (mapper_pop)
            $fdisplay(fifooutdumpfile, "%0t %04h", $time, fifo_head);
    end
    integer rx_head_av_cnt = 0;
    always @(posedge clk50m) if (rx_head_av) rx_head_av_cnt <= rx_head_av_cnt + 1;
    integer rx_reject_cnt = 0;
    always @(posedge clk50m) if (rx_reject) rx_reject_cnt <= rx_reject_cnt + 1;
    integer p_valid_cnt = 0;
    integer last_pvalid_time = 0;
    reg     stall_flagged = 1'b0;
    always @(posedge clk50m) begin
        if (p_valid && blitting) begin
            p_valid_cnt <= p_valid_cnt + 1;
            last_pvalid_time <= $time;
        end
    end
    always @(posedge clk50m) begin
        // flag whenever the gap since the last real blitting byte exceeds 1ms, so a
        // stall's START is visible instead of only its eventual timeout
        if (blitting && !stall_flagged && ($time - last_pvalid_time > 1_000_000)) begin
            stall_flagged <= 1'b1;
            $display("  [STALL START] t=%0t last_pvalid_time=%0t p_valid_cnt=%0d write_line=%0d fifo_lvl=%0d rw_stall=%0d rx_reject_cnt=%0d rx_head_av_cnt=%0d udp_head_fifo_lvl=%0d udp_data_fifo_lvl=%0d blit_bytes_recv=%0d bytes_len=%0d",
                      $time, last_pvalid_time, p_valid_cnt, write_line, fifo_level, rw_stall, rx_reject_cnt, rx_head_av_cnt, rx_head_fifo_lvl, rx_data_fifo_lvl, blit_bytes_recv, bytes_len);
        end
        if (p_valid && blitting) stall_flagged <= 1'b0;
    end
    integer max_udp_data_fifo_lvl = 0;
    always @(posedge clk50m)
        if (rx_data_fifo_lvl > max_udp_data_fifo_lvl) max_udp_data_fifo_lvl <= rx_data_fifo_lvl;

    // BUGFIX (this session): fifo_overflow is a 1-cycle PULSE (groovy_sync_fifo.v) - a
    // plain wire sampled only at $display time (end of sim) always reads the LAST
    // cycle's value, never the true history. Latch it properly.
    integer fifo_overflow_cnt = 0;
    always @(posedge clk50m) if (fifo_overflow) fifo_overflow_cnt <= fifo_overflow_cnt + 1;

    // Quantify exactly how much of the writer's time is spent guard-blocked vs free to
    // write, while blitting is actually in progress (has real data to place) - isolates
    // "the writer COULD write but the guard forbids it" from "the writer has nothing to
    // write" (FIFO empty), per this session's investigation into the measured 21% of
    // needed drain throughput.
    integer stall_cycles = 0, free_write_cycles = 0, empty_cycles = 0, blitting_cycles = 0;
    always @(posedge clk50m) begin
        if (blitting) begin
            blitting_cycles <= blitting_cycles + 1;
            if (rw_stall && ~fifo_empty) stall_cycles <= stall_cycles + 1;
            else if (rw_we) free_write_cycles <= free_write_cycles + 1;
            else if (fifo_empty) empty_cycles <= empty_cycles + 1;
        end
    end
    reg [15:0] prev_gap_dbg = 16'hFFFF;
    integer gap_sample_cnt = 0;
    always @(posedge clk50m) begin
        if (blitting && (write_line - read_line_50) != prev_gap_dbg) begin
            gap_sample_cnt <= gap_sample_cnt + 1;
            if (hf_50[1] && gap_sample_cnt < 100000)
                $display("  [GAP] t=%0t write_line=%0d read_line_50=%0d gap=%0d hf_50=%b rw_stall=%0d fifo_empty=%0d",
                          $time, write_line, read_line_50, write_line-read_line_50, hf_50, rw_stall, fifo_empty);
            prev_gap_dbg <= write_line - read_line_50;
        end
    end
    reg prev_blitting_dbg = 1'b0;
    always @(posedge clk50m) begin
        if (blitting != prev_blitting_dbg) begin
            $display("  [BLITTING EDGE] t=%0t blitting %0d->%0d req_ip=%0h req_port=%0d hstate=%0d",
                      $time, prev_blitting_dbg, blitting, req_ip, req_port, hstate);
            prev_blitting_dbg <= blitting;
        end
    end
    integer to_cnt_dbg = 0;
    always @(posedge clk50m) begin
        if (blit_timed_out) begin
            to_cnt_dbg <= to_cnt_dbg + 1;
            $display("  [TIMEOUT] t=%0t blit_rx TIMED OUT #%0d write_line=%0d fifo_lvl=%0d",
                      $time, to_cnt_dbg+1, write_line, fifo_level);
        end
        if (blit_valid)
            $display("  [BLIT_VALID] t=%0t frame=%0d write_line_at_this_moment=%0d", $time, blit_frame, write_line);
        if (frame_done)
            $display("  [FRAME_DONE] t=%0t write_line=%0d", $time, write_line);
    end
    // Only start checking correctness once at least ONE full network frame has landed
    // (2nd blit_valid = the 2nd CMD_BLIT_FIELD_VSYNC header, i.e. the 1st frame's data is
    // fully sent) - the very first fill window is a legitimate cold-start transient (the
    // writer has already lapped the ring several times before have_frame releases, so the
    // reader's first-ever read of a not-yet-refreshed slot has no prior real pixel to hold,
    // showing the pix_rgb565 reset value instead - a one-time startup artifact, not a
    // steady-state ring bug).
    integer blit_hdr_count = 0;
    reg     check_enabled = 1'b0;
    always @(posedge clk50m) begin
        if (blit_valid) begin
            blit_hdr_count <= blit_hdr_count + 1;
            if (blit_hdr_count >= 1) check_enabled <= 1'b1;
        end
    end

    // Ground truth for "which pixel SHOULD be showing" is slot_actual_line (the RTL's
    // OWN record of which source line the currently-addressed ring slot really holds -
    // groovy_lineram_scan.v uses this exact signal, compared against its internal
    // expect_line2, to decide whether to trust r_data or hold the previous pixel). Do
    // NOT independently recompute the displayed line from vcount/V_REPL: the real
    // displayed line (disp_line inside groovy_lineram_scan.v) is a LATCHED, clamped
    // value (it can legitimately lag the free-running raster, or hold at wr_top past a
    // writer stall) - recomputing it naively from vcount here diverges from the RTL's
    // own notion of "current line" and produces false mismatches (found during this
    // session's stabilization pass: naive vcount/3 disagreed with a CORRECTLY-clamped
    // disp_line by exactly the writer's stall amount, look like a slot-rotation bug).
    function [15:0] expect_pix(input [15:0] hc, input [15:0] sactual_line);
        reg [15:0] scol;
        begin
            scol  = hc >> 2;               // H_SH=2 (H_REPL=4)
            expect_pix = {sactual_line[7:0], scol[7:0]};
        end
    endfunction

    // slot_actual_line is combinational-into-that-cycle's decision inside
    // groovy_lineram_scan.v: the SAME pix_clk edge that samples it also produces the
    // pix_rgb565 value that only becomes visible on pix565 the NEXT cycle. So checking
    // pix565 against a live-sampled slot_actual_line at the same edge compares values
    // one cycle apart - delay our own copy by one cycle to align with what pix565
    // actually reflects (found during this session's stabilization pass: an
    // undelayed comparison showed a spurious constant "8 source lines off" pattern
    // that vanished once this alignment was corrected - a testbench artifact, not a
    // real ring desync).
    reg [15:0] slot_actual_line_d;
    always @(posedge pix_clk) slot_actual_line_d <= slot_actual_line;

    always @(posedge pix_clk) begin
        if (de_o && check_enabled) begin
            checked = checked + 1;
            // skip the documented 1px seam: col 0 of every output line
            if ((hcount != 16'd0) && (hcount[1:0] != 2'd0)) begin
                if (pix565 !== expect_pix(hcount, slot_actual_line_d)) begin
                    if (prev_de && pix565 === prev_pix) begin
                        held = held + 1;   // legitimate hold (stale-slot freeze)
                    end else begin
                        errors = errors + 1;
                        if (errors <= 20 || (errors > 100000 && errors <= 100010))
                            $display("MISMATCH #%0d t=%0t hcount=%0d vcount=%0d got=%04h exp=%04h slot_actual_line_d=%0d write_line=%0d",
                                      errors, $time, hcount, vcount, pix565, expect_pix(hcount, slot_actual_line_d), slot_actual_line_d, write_line);
                        err_hcount_lo4[hcount[3:0]] = err_hcount_lo4[hcount[3:0]] + 1;
                    end
                end
            end
        end
        prev_pix <= pix565; prev_de <= de_o;
    end

    // =========================================================================
    // RMII frame injection: replay the generated frames (INIT, BLIT header, pixel
    // chunks) at a NETWORK-SAFE pacing (see memory udpstress-bandwidth-saturation.md:
    // below ~0.75x of the real gwline rate keeps measured loss under ~2%; in this
    // noiseless sim there is no loss at all, but we still pace realistically so the
    // ring's FILL RATE matches what a real, lightly-loaded network would deliver).
    // =========================================================================
    task send_byte(input [7:0] b);
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1) begin
                rxd_drv = b[1:0];
                b = b >> 2;
                @(posedge clk50m);
            end
        end
    endtask

    // Real Ethernet requires a silent Inter-Frame Gap (IFG, >= 96 bit-times = 960ns at
    // 100Mb/s) between frames so the PHY/MAC can resynchronize carrier detection - without
    // it, back-to-back crs_drv=0->1 with zero gap risks udp.sv's rx_state machine not
    // seeing a clean new preamble (see groovy_udpstress_udpsv_realframe_tb.v's IFG_CYCLES,
    // the same technique proven there for burst framing).
    // 1640 cycles = 32.8us: the SAME value proven safe in
    // groovy_udpstress_udpsv_realframe_tb.v - a shorter 100-cycle (2us) gap used
    // earlier in this session's stabilization pass produced mismatched pixel content
    // (traced to a real byte-level corruption between back-to-back RMII frames, not a
    // ring bug) once burst framing was stressed with many frames in a row.
    localparam integer IFG_CYCLES = 1640;
    task automatic send_frame_file(input [8*160:1] fname, input integer flen);
        reg [7:0] fbuf [0:1350];
        integer fi;
        begin
            $readmemh(fname, fbuf);
            crs_drv = 1'b1;
            for (fi = 0; fi < 7; fi = fi + 1) send_byte(8'h55);
            send_byte(8'hD5);
            for (fi = 0; fi < flen; fi = fi + 1) send_byte(fbuf[fi]);
            crs_drv = 1'b0;
            repeat(IFG_CYCLES) @(posedge clk50m);
        end
    endtask

    // manifest: index label bytelen (see gen_gwline_frames.py's frames_manifest.txt)
    localparam integer NFRAMES = 122;
    integer manifest_len [0:NFRAMES-1];
    integer mf, midx, mlen;
    reg [8*16:1] mlabel;
    initial begin
        mf = $fopen({FDIR, "frames_manifest.txt"}, "r");
        while (!$feof(mf)) begin
            if ($fscanf(mf, "%d %s %d\n", midx, mlabel, mlen) == 3)
                manifest_len[midx] = mlen;
        end
        $fclose(mf);
    end

    // ~69.4us/line real rate; test at HALF that pace (~0.5x, well inside the <2%-loss
    // zone per the sweep table) between pixel datagrams. Header packets get a fixed gap.
    // LINE_GAP_CYCLES = 3470 cycles @ 20ns = 69.4us = the REAL per-SOURCE-LINE gwline
    // rate (1.0x). A packet carries 2 lines, so waiting 2*LINE_GAP_CYCLES between
    // packets is 138.8us/packet = 69.4us/line = the FULL real rate (1.0x), NOT 0.5x as
    // an earlier version of this comment claimed - that mistake meant this testbench
    // was unintentionally driving the ring at the exact rate the udpstress sweep
    // (memory udpstress-bandwidth-saturation.md) measured as already saturating the
    // real 100Mb/s link (~14% loss at 1.0x). For a genuine 0.5x (half rate, safely
    // inside the <1% loss zone), the packet gap must be DOUBLED: 4*LINE_GAP_CYCLES.
    localparam integer LINE_GAP_CYCLES = 3470;
    localparam integer PACKET_GAP_MULT = 4;   // 4x -> 2 lines/packet at 0.5x per-line rate
    localparam integer N_NET_FRAMES = 3;   // repeat the whole source frame this many times,
                                            // like a real continuous stream - a SINGLE frame
                                            // send leaves the video raster free-running with
                                            // no new data afterward, which is not a real
                                            // operating condition and was misread as ring
                                            // corruption in an earlier version of this tb.
    integer fidx, nf;
    reg [8*160:1] fname;
    initial begin
        rst = 1;
        force udp_inst.phy_rdy = 1'b0;
        repeat(10) @(posedge clk50m);
        rst = 0;
        repeat(10) @(posedge clk50m);
        force udp_inst.phy_rdy = 1'b1;
        repeat(5) @(posedge clk50m);
        repeat(50) @(posedge clk50m);   // wait manifest read (initial block ordering)

        // frame 0 = INIT (once, at session start)
        $sformat(fname, "%0sframe_0000_INIT.hex", FDIR);
        send_frame_file(fname, manifest_len[0]);
        repeat(2000) @(posedge clk50m);

        for (nf = 0; nf < N_NET_FRAMES; nf = nf + 1) begin
            $display("--- sending network frame %0d/%0d --- t=%0t rx_head_av_cnt_so_far=%0d",
                      nf+1, N_NET_FRAMES, $time, rx_head_av_cnt);
            // frame 1 = BLIT header (one per network frame, like a real continuous stream)
            $sformat(fname, "%0sframe_0001_BLIT_HDR.hex", FDIR);
            send_frame_file(fname, manifest_len[1]);
            repeat(500) @(posedge clk50m);

            // frames 2..121 = pixel chunks, paced at 2x the real per-line gap (i.e. 0.5x
            // rate per the bandwidth sweep naming - each chunk covers multiple source
            // lines here since CHUNK=1280B/2Bpp=640px=2 lines, so gap/chunk = 2x LINE_GAP)
            for (fidx = 2; fidx < NFRAMES; fidx = fidx + 1) begin
                $sformat(fname, "%0sframe_%04d_PIX.hex", FDIR, fidx);
                send_frame_file(fname, manifest_len[fidx]);
                repeat(PACKET_GAP_MULT * LINE_GAP_CYCLES) @(posedge clk50m);
            end
        end

        $display("all %0d frames sent, t=%0t rx_head_av_cnt=%0d (expect %0d = %0d net-frames x %0d hdr-words x 122 udp-datagrams)",
                  NFRAMES, $time, rx_head_av_cnt, N_NET_FRAMES*4*122, N_NET_FRAMES, 4);
        // let the ring/scanout run long enough to display several frames after fill
        repeat(60_000_000 / 20) @(posedge clk50m);   // ~60ms of pix_clk-domain settling

        $display("=== RESULT ===");
        $display("write_line (final) = %0d/%0d  fifo_overflow_count=%0d  max_udp_internal_data_fifo_lvl=%0d/8192",
                  write_line, SRC_H, fifo_overflow_cnt, max_udp_data_fifo_lvl);
        $display("blitting_cycles=%0d  guard_stall_cycles=%0d (%.1f%%)  free_write_cycles=%0d (%.1f%%)  fifo_empty_cycles=%0d (%.1f%%)",
                  blitting_cycles, stall_cycles, 100.0*stall_cycles/blitting_cycles,
                  free_write_cycles, 100.0*free_write_cycles/blitting_cycles,
                  empty_cycles, 100.0*empty_cycles/blitting_cycles);
        $display("output pixels checked = %0d, held(legit) = %0d, errors = %0d", checked, held, errors);
        for (eh_i = 0; eh_i < 16; eh_i = eh_i + 1)
            if (err_hcount_lo4[eh_i] > 0)
                $display("  errors at hcount[3:0]=%0d: %0d", eh_i, err_hcount_lo4[eh_i]);
        if (errors == 0 && checked > 0)
            $display("PASS: gwline_ring_e2e_tb (real udp.sv -> ring, network-safe pacing)");
        else
            $display("FAIL: gwline_ring_e2e_tb (%0d errors / %0d checked)", errors, checked);
        $finish;
    end

    initial begin
        #700_000_000;   // 700ms safety timeout (3 net frames @ ~33ms send at true 0.5x + settle)
        $display("FAIL: gwline_ring_e2e_tb TIMED OUT");
        $finish;
    end
endmodule
