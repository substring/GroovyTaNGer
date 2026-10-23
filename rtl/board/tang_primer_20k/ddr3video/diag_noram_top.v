// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - DIAGNOSTIC: line-buffer reader + scaler + DVI with NO real DDR3.
//
// Rung 0b of the diagnostic ladder. Replaces the real DDR3 controller (+ writer +
// arbiter + refresh) with groovy_fake_ddr3, a PERFECT synthetic memory that
// answers each read with pix = f(addr) at a fixed latency. Everything else - the
// pixel clock, the groovy_linebuf_reader (3-line buffer + 4x3 scaler), the
// RGB565->888, the DVI tail - is IDENTICAL to ddr3video.
//
// PURPOSE: if the period-2 vertical stripes appear even with this perfect memory,
// the bug is in the READER / SCALER / SCANOUT - not DDR3 or its controller. If the
// screen instead shows a clean deterministic ramp (the f(addr) pattern, 4x3
// scaled), the reader/scaler path is proven good and the bug is in DDR3.
//
// Observation: SCREEN shows the f(addr) pattern (detail). LEDs show liveness.
`default_nettype none

module diag_noram_top (
    input  wire        sys_clk,      // 27 MHz, H11
    input  wire        sys_resetn,   // active-low, T10
    output wire        O_tmds_clk_p,
    output wire        O_tmds_clk_n,
    output wire [2:0]  O_tmds_data_p,
    output wire [2:0]  O_tmds_data_n,
    output wire [5:0]  led,
    output wire        uart_txp     // M11 -> /dev/ttyUSB1: TRA transition counter
);
    // geometry: same 320x240 source -> 1280x720 output (4x3) as ddr3video
    localparam [15:0] SRC_W = 16'd320, SRC_H = 16'd240;
    localparam [15:0] OUT_W = 16'd1280, OUT_H = 16'd720;
    localparam integer HREP = 4, VREP = 3, HSH = 2;
    localparam [25:0] BASE  = 26'd0;

    // ---- DDR3-domain clock (pclk ~99.5MHz): the fake mem runs here, same as the
    // real controller's user clock, so the reader's CDC behaviour is identical ----
    wire ddr_fclk, ddr_ck, pclk, ddr_lock;
    Gowin_rPLL u_ddrpll (
        .clkout(ddr_fclk), .clkoutp(ddr_ck), .lock(ddr_lock),
        .clkoutd(pclk), .clkin(sys_clk));
    wire pclk_resetn = sys_resetn & ddr_lock;

    // ---- 720p pixel clock (identical to ddr3video) ----
    wire serial_clk, tmds_lock, pix_clk;
    rpll_tmds u_tmdspll (.clkin(sys_clk), .clkout(serial_clk), .lock(tmds_lock));
    wire hdmi_rst_n = sys_resetn & tmds_lock;
    CLKDIV u_div (.RESETN(hdmi_rst_n), .HCLKIN(serial_clk), .CLKOUT(pix_clk), .CALIB(1'b1));
    defparam u_div.DIV_MODE = "5";
    defparam u_div.GSREN    = "false";

    // ---- fake DDR3 (perfect synthetic memory) ----
    wire        r_rd;
    wire [25:0] r_addr;
    wire [15:0] fk_dout;
    wire        fk_dready, fk_busy;
    // LATENCY(40): stress test. Real DDR3 single-word reads are ~11 cyc + refresh/
    // arbiter stalls; cranking the fake memory's latency way up tests whether a SLOW
    // fetch (fill-vs-scan race / credit pacing) corrupts the picture - WITHOUT any
    // data corruption (fake mem returns perfect bars). If TRA stays ~1 here, timing/
    // pacing is NOT the cause and the rain is the DDR3 DATA; if TRA blows up, the
    // fill-vs-scan race is real.
    groovy_fake_ddr3 #(.ADDR_W(26), .LATENCY(11), .BARS(1), .WIDTH(320), .HEIGHT(240)) u_fake (
        .clk(pclk), .rst(~pclk_resetn),
        .rd(r_rd), .wr(1'b0), .refresh(1'b0),
        .addr(r_addr), .din(16'd0),
        .dout(fk_dout), .data_ready(fk_dready), .busy(fk_busy));

    // ---- 720p timing ----
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

    // fetch_fs: 1-cycle pulse at the START OF VERTICAL BLANKING (vcount==OUT_H &&
    // hcount==0), as in gwddr3video_top. The reader restarts its fetch on it (and its
    // scanout line counter); left unconnected, the fetch filled frame 0 only.
    reg fetch_fs;
    always @(posedge pix_clk)
        fetch_fs <= (vcount == OUT_H) && (hcount == 16'd0);

    reg [1:0] de_p, hs_p, vs_p;
    always @(posedge pix_clk) begin
        de_p <= {de_p[0], de}; hs_p <= {hs_p[0], hsync}; vs_p <= {vs_p[0], vsync};
    end
    wire de_o = de_p[1], hs_o = hs_p[1], vs_o = vs_p[1];

    // ---- the SAME line-buffer reader + scaler under test ----
    wire [15:0] pix565;
    wire        fetch_active;
    groovy_linebuf_reader #(.LINE_W(512), .LW_ADDR(9), .DDR_AW(26),
                            .SINGLE_WORD(1), .H_REPL(HREP), .V_REPL(VREP), .H_SH(HSH)) u_lbr (
        .pix_clk(pix_clk), .pix_rst(~hdmi_rst_n),
        .h_active(SRC_W), .v_active(SRC_H),
        .hcount(hcount), .vcount(vcount), .de(de),
        .line_start(line_start), .frame_start(frame_start),
        .fetch_fs(fetch_fs),
        .pix_rgb565(pix565),
        .pclk(pclk), .pclk_rst(~pclk_resetn), .base_addr(BASE),
        .rd(r_rd), .addr(r_addr),
        .busy(fk_busy), .data_ready(fk_dready),
        .dout128(128'd0), .dout(fk_dout),
        .fetch_active(fetch_active));

    // ---- RGB565 -> 888 ----
    wire [4:0] r5 = pix565[15:11];
    wire [5:0] g6 = pix565[10:5];
    wire [4:0] b5 = pix565[4:0];
    wire [7:0] r8 = {r5, r5[4:2]};
    wire [7:0] g8 = {g6, g6[5:4]};
    wire [7:0] b8 = {b5, b5[4:2]};

    DVI_TX_Top u_dvi (
        .I_rst_n(hdmi_rst_n), .I_serial_clk(serial_clk), .I_rgb_clk(pix_clk),
        .I_rgb_vs(vs_o), .I_rgb_hs(hs_o), .I_rgb_de(de_o),
        .I_rgb_r(r8), .I_rgb_g(g8), .I_rgb_b(b8),
        .O_tmds_clk_p(O_tmds_clk_p), .O_tmds_clk_n(O_tmds_clk_n),
        .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n));

    // ===== UNFOOLABLE band-colour check (same as ddr3video) =====
    // Expected colour = the SAME band function the fake memory (BARS=1) writes:
    // band by source_row (=vcount/3), 30 source rows per band. ERR = output pixels
    // whose colour != expected this frame. If diag_noram (PERFECT memory) shows ERR
    // high, the SCALER/scanout itself is broken (independent of DDR3).
    function [15:0] band_color; input [15:0] srow;
        reg [2:0] b;
        begin
            b = srow / 16'd30;
            case (b)
                3'd0: band_color=16'hF800; 3'd1: band_color=16'h07E0;
                3'd2: band_color=16'h001F; 3'd3: band_color=16'hFFE0;
                3'd4: band_color=16'h07FF; 3'd5: band_color=16'hF81F;
                3'd6: band_color=16'hFFFF; default: band_color=16'h8410;
            endcase
        end
    endfunction
    reg de_o_d, vs_o_d;
    reg [19:0] err_acc=0, err=0;
    reg [15:0] firstbad_h=16'hFFFF, firstbad_v=16'hFFFF, bad_this=0, bad_exp=0;
    wire [15:0] exp_now = band_color(vcount / 16'd3);
    always @(posedge pix_clk) begin
        if (~hdmi_rst_n) begin
            err_acc<=0; err<=0; de_o_d<=0; vs_o_d<=0;
            firstbad_h<=16'hFFFF; firstbad_v<=16'hFFFF;
        end else begin
            de_o_d <= de_o; vs_o_d <= vs_o;
            if (vs_o && !vs_o_d) begin err<=err_acc; err_acc<=0; firstbad_h<=16'hFFFF; firstbad_v<=16'hFFFF; end
            if (de_o) begin
                if (pix565 !== exp_now) begin
                    if (err_acc!=20'hFFFFF) err_acc<=err_acc+1'b1;
                    if (firstbad_h==16'hFFFF) begin firstbad_h<=hcount; firstbad_v<=vcount; bad_this<=pix565; bad_exp<=exp_now; end
                end
            end
        end
    end
    reg [19:0] q_bad; reg [15:0] q_chk, q_fh, q_fv, q_pt, q_pp;
    always @(posedge sys_clk) begin
        q_bad<=err; q_chk<=16'd0; q_fh<=firstbad_h; q_fv<=firstbad_v;
        q_pt<=bad_this; q_pp<=bad_exp;
    end
    wire [7:0] tx_din; wire tx_wr, tx_busy;
    uart_tx_V2 #(.clk_freq(27_000_000), .uart_freq(115200)) u_dbgtx (
        .clk(sys_clk), .din(tx_din), .wr_en(tx_wr), .tx_busy(tx_busy), .tx_p(uart_txp));
    function [7:0] hxd; input [3:0] n; hxd = (n<4'd10)?(8'h30+n):(8'h41+n-4'd10); endfunction
    localparam [6:0] DBGLEN = 7'd52;
    reg [6:0] di=0; reg [7:0] dtx=0; reg dwr=0; reg [2:0] dst=0; reg [23:0] dhold=0;
    reg [7:0] dlb;
    always @(*) begin
        case (di)
            0:dlb="T";1:dlb="R";2:dlb="A";3:dlb="=";
            4:dlb=hxd(q_bad[19:16]);5:dlb=hxd(q_bad[15:12]);6:dlb=hxd(q_bad[11:8]);7:dlb=hxd(q_bad[7:4]);8:dlb=hxd(q_bad[3:0]);9:dlb=" ";
            10:dlb="M";11:dlb="A";12:dlb="X";13:dlb="=";
            14:dlb=hxd(q_chk[15:12]);15:dlb=hxd(q_chk[11:8]);16:dlb=hxd(q_chk[7:4]);17:dlb=hxd(q_chk[3:0]);18:dlb=" ";19:dlb=" ";
            20:dlb="H";21:dlb="=";22:dlb=hxd(q_fh[15:12]);23:dlb=hxd(q_fh[11:8]);24:dlb=hxd(q_fh[7:4]);25:dlb=hxd(q_fh[3:0]);26:dlb=" ";
            27:dlb="V";28:dlb="=";29:dlb=hxd(q_fv[15:12]);30:dlb=hxd(q_fv[11:8]);31:dlb=hxd(q_fv[7:4]);32:dlb=hxd(q_fv[3:0]);33:dlb=" ";
            34:dlb="P";35:dlb="=";
            36:dlb=hxd(q_pp[15:12]);37:dlb=hxd(q_pp[11:8]);38:dlb=hxd(q_pp[7:4]);39:dlb=hxd(q_pp[3:0]);
            40:dlb="/";
            41:dlb=hxd(q_pt[15:12]);42:dlb=hxd(q_pt[11:8]);43:dlb=hxd(q_pt[7:4]);44:dlb=hxd(q_pt[3:0]);
            50:dlb=8'h0D;51:dlb=8'h0A;default:dlb=" ";
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

    // ---- LEDs (active-low): liveness ----
    //   led0 ddr_lock  led1 tmds_lock  led2 (unused, 1)  led3 (1)
    //   led4 fetch_active  led5 heartbeat
    reg [24:0] hb;
    always @(posedge sys_clk or negedge sys_resetn)
        if (!sys_resetn) hb <= 25'd0; else hb <= hb + 25'd1;
    assign led = ~{ hb[24], fetch_active, 1'b0, 1'b0, tmds_lock, ddr_lock };

endmodule

`default_nettype wire
