// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - Ethernet top, Milestone B (RX + TX). Roadmap Phase 5.
//
// Built on the vendored Sipeed udp block. RX side (Milestone A, HW-confirmed):
// rx_data -> groovy_packet_parser -> groovy_session. TX side (this milestone):
// replies go back over UDP via groovy_tx_arbiter, which muxes:
//   * groovy_ack_sender   (13-byte ACK, on INIT/GET_STATUS/BLIT via ack_policy)
//   * groovy_features     (12-byte v2.0.0 descriptor, on CMD_GET_FEATURES)
// The reply destination (PC IP + source port) is captured from the request's
// IP header using the same header-pop sequence Sipeed's loopback proved.
//
// LED panel (active-low; lit = true):
//   [5]=heartbeat [4]=ready [3]=clk50m [2]=rx_seen [1]=tx_req_seen [0]=session_active
`include "rmii.svh"

module groovy_eth_top (
    input  clk,        // 27 MHz, H11
    input  rst,        // active-low button, T10
    rmii   netrmii,
    output phyrst,
    output [5:0] led
);
    localparam [15:0] OUR_PORT = 16'd32100;

    // heartbeat (liveness, raw 27 MHz)
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

    // arbiter -> udp TX
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

    // ---- capture reply destination from the request IP header ----
    // Same pop timing as Sipeed's proven loopback: word0=src_ip (read @state1),
    // word2=src_port|dst_port (read @state3). We keep src_port as-is (no +1).
    logic [31:0] req_ip;
    logic [15:0] req_port;
    logic [2:0]  hstate;
    always_ff @(posedge clk50m or negedge ready) begin
        if (!ready) begin hstate <= 3'd0; rx_head_rdy <= 1'b0; end
        else begin
            rx_head_rdy <= 1'b0;
            case (hstate)
                0: if (rx_head_av) begin rx_head_rdy <= 1'b1; hstate <= 1; end  // word0
                1: begin rx_head_rdy <= 1'b1; req_ip   <= rx_head;       hstate <= 2; end  // src_ip
                2: begin rx_head_rdy <= 1'b1;                            hstate <= 3; end  // dst_ip
                3: begin rx_head_rdy <= 1'b1; req_port <= rx_head[31:16]; hstate <= 4; end // src_port
                4: if (!rx_head_av) hstate <= 0;   // re-arm only after the head FIFO drains
                default: hstate <= 0;              // (prevents re-reading an empty FIFO -> req_ip=0)
            endcase
        end
    end

    wire core_rst = ~ready;

    // diagnostics
    logic [22:0] ck50;  logic rx_seen, tx_req_seen;
    always_ff @(posedge clk50m or negedge rst)
        if (!rst) begin ck50 <= 0; rx_seen <= 0; tx_req_seen <= 0; end
        else begin
            ck50 <= ck50 + 23'd1;
            if (rx_data_av) rx_seen <= 1'b1;
            if (tx_req)     tx_req_seen <= 1'b1;
        end
    wire clk50_hb = ck50[22];

    // ---- RX: stage bytes -> parser ----
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
    wire [15:0] sr_h_total, sr_v_total;

    groovy_packet_parser u_parser (
        .clk(clk50m), .rst(core_rst),
        .in_valid(p_valid), .in_data(p_data), .in_sop(p_sop), .in_eop(p_eop),
        .cmd_valid(), .cmd(), .bad_packet(),
        .close_valid(close_valid), .init_valid(init_valid),
        .switchres_valid(switchres_valid), .audio_valid(), .get_status_valid(get_status_valid),
        .blit_valid(blit_valid), .get_version_valid(),
        .get_features_valid(get_features_valid), .get_switchres_valid(get_switchres_valid),
        .init_lz4(i_lz4), .init_sound_rate(i_sr),
        .init_sound_chan(i_sc), .init_rgb_mode(i_rgb),
        .sr_pclk(sr_pclk), .sr_h_active(), .sr_h_begin(), .sr_h_end(), .sr_h_total(sr_h_total),
        .sr_v_active(), .sr_v_begin(), .sr_v_end(), .sr_v_total(sr_v_total), .sr_interlace(),
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
        .new_session(), .end_session(), .cfg_bytes_per_pixel()
    );

    // ---- TX: ACK path (policy -> sender) ----
    wire        ack_start, ack_busy, ack_valid, ack_last, ack_ready;
    wire [7:0]  ack_data;
    wire [31:0] ack_frame_echo, ack_fpga_frame;
    wire [15:0] ack_vsync_echo, ack_fpga_vcount;
    wire [7:0]  ack_status;

    groovy_ack_policy u_policy (
        .clk(clk50m), .rst(core_rst),
        .init_valid(init_valid), .get_status_valid(get_status_valid),
        .blit_valid(blit_valid), .blit_frame(blit_frame), .blit_vsync(blit_vsync),
        .fpga_frame(32'd0), .fpga_vcount(ck50[15:0]), .status_bits(8'd0),  // placeholders until video exists
        .ack_busy(ack_busy),
        .ack_start(ack_start),
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

    // ---- TX: FEATURES path (v2.0.0). Advertise only what is implemented: RAW. ----
    wire ft_valid, ft_last, ft_ready, ft_busy;  wire [7:0] ft_data;
    groovy_features #(
        .PROTO_MAJOR(8'd2), .PROTO_MINOR(8'd0), .PROTO_PATCH(8'd0),
        .COMPRESSION(8'b0000_0001),    // RAW only for now
        .RGB_MODES  (8'b0000_0101)     // RGB888 + RGB565
    ) u_feat (
        .clk(clk50m), .rst(core_rst), .start(get_features_valid),
        .out_valid(ft_valid), .out_data(ft_data), .out_last(ft_last),
        .out_ready(ft_ready), .busy(ft_busy)
    );

    // ---- SWITCHRES compute + result reply (Rung 4a) ----
    wire sr_v, sr_l, sr_rdy;  wire [7:0] sr_d;
    groovy_switchres u_switchres (
        .clk(clk50m), .clk_slow(clk1m), .rst(core_rst),
        .switchres_valid(switchres_valid), .sr_pclk(sr_pclk),
        .sr_h_total(sr_h_total), .sr_v_total(sr_v_total),
        .send(get_switchres_valid),
        .out_valid(sr_v), .out_data(sr_d), .out_last(sr_l), .out_ready(sr_rdy), .busy(),
        .result_valid(), .idiv(), .fbdiv(), .odiv(), .achieved_khz(), .ok()
    );

    // ---- TX arbiter -> udp ----
    // Reply to the captured requester. TX path proven; header-capture race is
    // absorbed by req_valid (arbiter holds the send until the address is latched).
    // (DEBUG_FIXED_DEST=1 forces 192.168.15.15:32101 to isolate TX, if ever needed.)
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

    assign led = ~{heartbeat, ready, clk50_hb, rx_seen, tx_req_seen, session_active};
endmodule
