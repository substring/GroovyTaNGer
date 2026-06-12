// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - merged top (Phase 3a): network + dynamic HDMI in one design.
//
// The proven Ethernet stack (groovy_eth_top) RX->parser->switchres->TX, PLUS the
// dynamic video pipeline. A CMD_SWITCHRES over UDP now drives the live display:
//   parser -> groovy_switchres (idiv/fbdiv/odiv + N, on clk_slow)
//          -> rpll_sel_encode -> rpll_tmds_dyn -> CLKDIV/5 -> pix_clk
//          -> video_timing_gen (modeline scaled x N) -> test_pattern -> DVI_TX -> HDMI
//
// Power-up shows a DEFAULT 720p test pattern (so coexistence is provable even if
// the SWITCHRES path misbehaves). Send a switchres command -> the picture retunes.
// No real pixels yet (test pattern) and no x N replicator yet (Phase 3b); the
// modeline is scaled by N so even super-res low-res modes display the pattern at
// the right resolution.
//
// Lessons from Rung 4b baked in: never gate on the dynamic rPLL LOCK; use a fixed
// settle after a divider change; mode params are plain registers/combinational.
`include "rmii.svh"

module groovy_top (
    input  clk,        // 27 MHz, H11
    input  rst,        // active-low button, T10
    rmii   netrmii,
    output phyrst,
    output [5:0] led,
    output O_tmds_clk_p,
    output O_tmds_clk_n,
    output [2:0] O_tmds_data_p,
    output [2:0] O_tmds_data_n
);
    localparam [15:0] OUR_PORT = 16'd32100;

    // ================= NETWORK SIDE (mirrors groovy_eth_top) =================
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

    logic [31:0] req_ip;
    logic [15:0] req_port;
    logic [2:0]  hstate;
    always_ff @(posedge clk50m or negedge ready) begin
        if (!ready) begin hstate <= 3'd0; rx_head_rdy <= 1'b0; end
        else begin
            rx_head_rdy <= 1'b0;
            case (hstate)
                0: if (rx_head_av) begin rx_head_rdy <= 1'b1; hstate <= 1; end
                1: begin rx_head_rdy <= 1'b1; req_ip   <= rx_head;        hstate <= 2; end
                2: begin rx_head_rdy <= 1'b1;                             hstate <= 3; end
                3: begin rx_head_rdy <= 1'b1; req_port <= rx_head[31:16]; hstate <= 4; end
                4: if (!rx_head_av) hstate <= 0;   // re-arm after the head FIFO drains
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
    wire [31:0] blit_frame;
    wire [15:0] blit_vsync;
    wire [63:0] sr_pclk;
    wire [15:0] sr_ha, sr_hb, sr_he, sr_ht, sr_va, sr_vb, sr_ve, sr_vt;
    wire        blitting;          // from groovy_blit_rx (gates the parser)
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

    wire        ack_start, ack_busy, ack_valid, ack_last, ack_ready;
    wire [7:0]  ack_data;
    wire [31:0] ack_frame_echo, ack_fpga_frame;
    wire [15:0] ack_vsync_echo, ack_fpga_vcount;
    wire [7:0]  ack_status;
    logic [15:0] vcount_50;        // video raster line, sampled into clk50m (loose CDC)

    groovy_ack_policy u_policy (
        .clk(clk50m), .rst(core_rst),
        .init_valid(init_valid), .get_status_valid(get_status_valid),
        .blit_valid(blit_valid), .blit_frame(blit_frame), .blit_vsync(blit_vsync),
        .fpga_frame(32'd0), .fpga_vcount(vcount_50), .status_bits(8'd0),
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

    // SWITCHRES compute - now also exposes coefficients + N + result_valid to video
    wire        sr_v, sr_l, sr_rdy;  wire [7:0] sr_d;
    wire        sr_result_valid, sr_ok;
    wire [6:0]  sr_idiv, sr_fbdiv;
    wire [7:0]  sr_odiv;
    wire [3:0]  sr_n;
    groovy_switchres u_switchres (
        .clk(clk50m), .clk_slow(clk1m), .rst(core_rst),
        .switchres_valid(switchres_valid), .sr_pclk(sr_pclk),
        .sr_h_total(sr_ht), .sr_v_total(sr_vt),
        .send(get_switchres_valid),
        .out_valid(sr_v), .out_data(sr_d), .out_last(sr_l), .out_ready(sr_rdy), .busy(),
        .result_valid(sr_result_valid), .idiv(sr_idiv), .fbdiv(sr_fbdiv), .odiv(sr_odiv),
        .superres_n(sr_n), .achieved_khz(), .ok(sr_ok)
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

    // ================= VIDEO SIDE (new in 3a) =================
    // Latch the NATIVE modeline when a SWITCHRES is parsed (clk50m domain).
    logic [15:0] nm_ha, nm_hb, nm_he, nm_ht, nm_va, nm_vb, nm_ve, nm_vt;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) begin
            nm_ha<=1280; nm_hb<=1390; nm_he<=1430; nm_ht<=1650;
            nm_va<=720;  nm_vb<=725;  nm_ve<=730;  nm_vt<=750;
        end else if (switchres_valid) begin
            nm_ha<=sr_ha; nm_hb<=sr_hb; nm_he<=sr_he; nm_ht<=sr_ht;
            nm_va<=sr_va; nm_vb<=sr_vb; nm_ve<=sr_ve; nm_vt<=sr_vt;
        end

    // result_valid is a wide (clk1m) pulse -> sync to clk and edge-detect.
    logic [2:0] rv_s;
    always_ff @(posedge clk or negedge rst)
        if (!rst) rv_s <= 3'd0; else rv_s <= {rv_s[1:0], sr_result_valid};
    wire new_mode = rv_s[1] & ~rv_s[2];

    // Active (video-domain) mode regs - default 720p; updated on a new switch.
    logic [6:0]  v_idiv;  logic [6:0] v_fbdiv;  logic [7:0] v_odiv;
    logic [15:0] v_ha, v_hb, v_he, v_ht, v_va, v_vb, v_ve, v_vt;
    logic        video_rst;
    logic [16:0] settle;
    localparam [16:0] SETTLE_CYC = 17'd80000;   // ~3 ms after a divider change

    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            v_idiv<=7'd4; v_fbdiv<=7'd55; v_odiv<=8'd2;
            v_ha<=1280; v_hb<=1390; v_he<=1430; v_ht<=1650;
            v_va<=720;  v_vb<=725;  v_ve<=730;  v_vt<=750;
            video_rst<=1'b1; settle<=17'd0;
        end else begin
            if (new_mode) begin
                // latch coefficients + modeline scaled horizontally by N
                v_idiv<=sr_idiv; v_fbdiv<=sr_fbdiv; v_odiv<=sr_odiv;
                v_ha <= nm_ha * sr_n; v_hb <= nm_hb * sr_n;
                v_he <= nm_he * sr_n; v_ht <= nm_ht * sr_n;
                v_va <= nm_va; v_vb <= nm_vb; v_ve <= nm_ve; v_vt <= nm_vt;
                video_rst<=1'b1; settle<=17'd0;     // blank + restart settle
            end else if (settle < SETTLE_CYC) begin
                settle <= settle + 17'd1;
                video_rst <= 1'b1;
            end else begin
                video_rst <= 1'b0;                  // settled -> show
            end
        end
    end

    wire [5:0] idsel, fbdsel, odsel;
    rpll_sel_encode u_enc (.idiv(v_idiv), .fbdiv(v_fbdiv), .odiv(v_odiv),
                           .idsel(idsel), .fbdsel(fbdsel), .odsel(odsel));

    wire serial_clk, pix_clk, pll_lock;
    rpll_tmds_dyn u_pll (.clkin(clk), .reset(~rst),
                         .idsel(idsel), .fbdsel(fbdsel), .odsel(odsel),
                         .clkout(serial_clk), .lock(pll_lock));

    CLKDIV u_div (.RESETN(rst), .HCLKIN(serial_clk), .CLKOUT(pix_clk), .CALIB(1'b1));
    defparam u_div.DIV_MODE="5"; defparam u_div.GSREN="false";

    // ================= BLIT pixels -> VRAM -> scaler -> HDMI (Rung 5) =================
    // FIRST-PICTURE path: fixed native 160x90 stored in BRAM, scaled x8 (shift 3)
    // to the 720p output. (Output stays at the default 720p; do not send SWITCHRES
    // for this test.) bytes_len = native_pixels * bpp. TODO: drive native size +
    // scale from SWITCHRES (and use DDR3 for full-size frames).
    localparam integer NATIVE_W   = 160;
    localparam integer NATIVE_PIX = 14400;     // 160 * 90
    localparam [16:0]  RECIP_H = 17'd8192, RECIP_V = 17'd8192;  // ceil(65536/8) = x8
    localparam integer FB_ADDR_W = 14;         // 2^14 > 14400

    wire [31:0]          bytes_len = NATIVE_PIX * cfg_bpp;
    wire                 fb_we, frame_done;
    wire [FB_ADDR_W-1:0] fb_waddr, fb_raddr;
    wire [15:0]          fb_wdata, fb_rdata;

    groovy_blit_rx #(.ADDR_W(FB_ADDR_W)) u_blit (
        .clk(clk50m), .rst(core_rst),
        .start(blit_valid), .bytes_len(bytes_len), .bytespp(cfg_bpp),
        .in_valid(p_valid & blitting), .in_data(p_data),
        .blitting(blitting), .frame_done(frame_done), .bytes_recv(),
        .wr_en(fb_we), .wr_addr(fb_waddr), .wr_data(fb_wdata));

    groovy_vram #(.DEPTH(NATIVE_PIX), .ADDR_W(FB_ADDR_W)) u_vram (
        .clk_w(clk50m), .we(fb_we), .waddr(fb_waddr), .wdata(fb_wdata),
        .clk_r(pix_clk), .raddr(fb_raddr), .rdata(fb_rdata));

    wire        de, hsync, vsync;
    wire [15:0] hcount, vcount;
    video_timing_gen u_timing (
        .clk(pix_clk), .rst(video_rst), .en(1'b1),
        .h_total(v_ht), .h_active(v_ha), .h_sync_begin(v_hb), .h_sync_end(v_he),
        .v_total(v_vt), .v_active(v_va), .v_sync_begin(v_vb), .v_sync_end(v_ve),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),   // TODO: polarity from modeline
        .hcount(hcount), .vcount(vcount), .hsync(hsync), .vsync(vsync), .de(de),
        .line_start(), .frame_start());

    wire [7:0] r, g, b;
    wire       de_o, hs_o, vs_o;
    groovy_pixel_reader #(.ADDR_W(FB_ADDR_W)) u_reader (
        .clk(pix_clk), .hcount(hcount), .vcount(vcount),
        .de(de), .hsync(hsync), .vsync(vsync),
        .native_w(NATIVE_W[11:0]), .recip_h(RECIP_H), .recip_v(RECIP_V),
        .raddr(fb_raddr), .rdata(fb_rdata),
        .r(r), .g(g), .b(b), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o));

    // native raster line into clk50m for the ACK vCount (beam-race feedback).
    // /8 matches the x8 vertical scale (RECIP_V); generalize with the modeline later.
    always_ff @(posedge clk50m) vcount_50 <= vcount >> 3;

    DVI_TX_Top u_dvi (
        .I_rst_n(~video_rst), .I_serial_clk(serial_clk), .I_rgb_clk(pix_clk),
        .I_rgb_vs(vs_o), .I_rgb_hs(hs_o), .I_rgb_de(de_o),
        .I_rgb_r(r), .I_rgb_g(g), .I_rgb_b(b),
        .O_tmds_clk_p(O_tmds_clk_p),   .O_tmds_clk_n(O_tmds_clk_n),
        .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n));

    // pix_clk-alive indicator
    logic [24:0] pc;
    always_ff @(posedge pix_clk) pc <= pc + 25'd1;

    // latch "a full frame was received" (lights when a BLIT completes)
    logic have_frame;
    always_ff @(posedge clk50m or posedge core_rst)
        if (core_rst) have_frame <= 1'b0; else if (frame_done) have_frame <= 1'b1;

    // led[5]=heartbeat [4]=ready [3]=rx_seen [2]=session [1]=pix_alive [0]=have_frame
    assign led = ~{heartbeat, ready, rx_seen, session_active, pc[24], have_frame};
endmodule
