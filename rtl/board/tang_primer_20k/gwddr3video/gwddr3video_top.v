// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - DDR3 -> line buffer -> 720p HDMI (DDR3 step 3b).
//
// Proves the core docs/ddr3.md thesis on hardware: a framebuffer in DDR3, scanned
// out at 720p (74.25 MHz) through a 3-line ping-pong BRAM buffer, so the pixel
// clock only ever reads a one-line BRAM -> BYPASSES the ~40 MHz BRAM-read wall
// that caps a full-frame BRAM framebuffer at 800x600. No network, no scaler: on
// boot an FSM writes a fixed test pattern into DDR3 once, then the line-buffer
// reader streams it to the Gowin DVI_TX continuously.
//
// Two PLLs from the 27 MHz input (both already HW-proven elsewhere):
//   - Gowin_rPLL  : DDR3 clocks (398.25 fclk / 90deg ck / ~99.56 MHz pclk)
//   - rpll_tmds   : 371.25 MHz serial -> CLKDIV/5 -> 74.25 MHz pix_clk (720p)
//
// One DDR3 user port, two clients: the boot WRITER owns it until the frame is
// filled (fill_done), then it hands off permanently to the line-buffer READER.
// A refresh scheduler injects an auto-refresh (~every 7.8us) in idle gaps.
//
// DVI_TX_Top is the encrypted Gowin DVI_TX IP - NOT committed; generate it with
// the Gowin IP wizard (see the dvi_tx/ README).
`default_nettype none

module gwddr3video_top (
    input  wire        sys_clk,      // 27 MHz, H11
    input  wire        sys_resetn,   // active-low, T10

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
    output wire        uart_txp     // M11 -> FT2232 -> /dev/ttyUSB1 @115200 (debug)
);
    // ====================== geometry ===================================
    // SOURCE framebuffer = 320x240 (single-word DDR3 reads fit its bandwidth),
    // upscaled 4x(H) x 3x(V) by the line-buffer reader to the 1280x720 OUTPUT.
    localparam [15:0] SRC_W = 16'd320, SRC_H = 16'd240;   // framebuffer (source)
    localparam [15:0] OUT_W = 16'd1280, OUT_H = 16'd720;  // HDMI output (timing)
    localparam integer HREP = 4, VREP = 3, HSH = 2;       // 320*4=1280, 240*3=720
    localparam [25:0] BASE  = 26'd0;                      // frame base in DDR3 words
    localparam [31:0] NPIX  = 32'd76800;                  // 320*240 source words

    // ====================== DDR3 clocks ================================
    // mem_pll: 27 MHz -> 302.4 MHz memory_clk (the proven Sipeed PLL for this IP).
    wire memory_clk, ddr_pll_lock;
    mem_pll u_mempll (.clkout(memory_clk), .lock(ddr_pll_lock), .clkoutd3(), .reset(~sys_resetn), .clkin(sys_clk));

    // ====================== 720p pixel clock ===========================
    wire serial_clk, tmds_lock, pix_clk;
    rpll_tmds u_tmdspll (.clkin(sys_clk), .clkout(serial_clk), .lock(tmds_lock));
    wire hdmi_rst_n = sys_resetn & tmds_lock;
    CLKDIV u_div (.RESETN(hdmi_rst_n), .HCLKIN(serial_clk), .CLKOUT(pix_clk), .CALIB(1'b1));
    defparam u_div.DIV_MODE = "5";
    defparam u_div.GSREN    = "false";

    // ====================== GOWIN DDR3 IP + adapter ====================
    // The Gowin DDR3 Memory Interface IP (HW read training -> clean reads) on its
    // native cmd/data interface; the adapter bridges it to the reader/writer's simple
    // rd/wr/busy/data_ready/dout (single-word) port. The IP's clk_out (~75 MHz) is the
    // fetch/user clock = "pclk" everywhere below. Refresh is handled INSIDE the IP.
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

    // adapter: single-word port for the writer (w_*) and reader (r_*), muxed by fill_done.
    reg  [25:0]  ddr_addr_m;   // muxed word address
    reg  [15:0]  ddr_din;      // writer data
    reg          a_rd, a_wr;   // muxed read/write pulse
    wire [15:0]  ddr_dout;
    wire         ddr_data_ready, ddr_busy;
    groovy_gwddr3_adapter u_adapt (
        .uclk(pclk), .urst(ddr_rst), .init_calib_complete(init_calib_complete),
        .rd(a_rd), .wr(a_wr), .addr(ddr_addr_m), .din(ddr_din),
        .busy(ddr_busy), .data_ready(ddr_data_ready), .dout(ddr_dout),
        .cmd(ip_cmd), .cmd_en(ip_cmd_en), .cmd_ready(ip_cmd_ready), .ip_addr(ip_addr),
        .wr_data(ip_wr_data), .wr_data_en(ip_wr_data_en), .wr_data_end(ip_wr_data_end),
        .wr_data_mask(ip_wr_data_mask), .wr_data_rdy(ip_wr_data_rdy),
        .rd_data(ip_rd_data), .rd_data_valid(ip_rd_data_valid)
    );
    wire [127:0] ddr_dout128 = 128'd0;   // burst path unused (adapter feeds single words)
    wire [7:0]   ddr_state = 8'd0;        // (no controller state to expose)

    // refresh is internal to the IP; stub the old scheduler signals the writer/probe ref.
    wire refresh_due = 1'b0, do_refresh = 1'b0;
    reg  refresh_ack = 1'b0;
    always @(posedge pclk) begin
        if (1'b0) begin   // (kept so the always block exists; no refresh logic needed)
            refresh_ack <= 1'b0;
        end
    end

    // ====================== boot pattern writer ========================
    // On boot, once the controller is initialised (busy low), write NPIX words:
    //   pixel(x,y) = test pattern in RGB565. We pick a pattern that makes any
    //   addressing/scanout error obvious: vertical color bars + a moving-free
    //   gradient in the low bits, so neighbouring lines differ.
    localparam W_INIT = 2'd0, W_RUN = 2'd1, W_DONE = 2'd2;
    reg [1:0]  wstate = W_INIT;
    reg [25:0] waddr_c = 26'd0;       // linear write address (= pixel index)
    reg [15:0] wx = 16'd0, wy = 16'd0;// (x,y) tracked as counters (no divide)
    reg        fill_done = 1'b0;

    // ONE SHARED pattern function: 8 horizontal colour bands by SOURCE ROW (0..239),
    // 30 source rows per band. The WRITER uses it (source_row = wy) to fill DDR3, and
    // the read-back CHECKER uses the SAME function (source_row = vcount/3) to know the
    // expected colour of any output pixel. Single source of truth -> the self-check is
    // DEFINITIONALLY consistent with what was written; a bug in one can't desync them.
    function [15:0] band_color; input [15:0] srow;
        reg [2:0] b;
        begin
            b = (srow >= 16'd210) ? 3'd7 : (srow >= 16'd180) ? 3'd6 :
                (srow >= 16'd150) ? 3'd5 : (srow >= 16'd120) ? 3'd4 :
                (srow >= 16'd90)  ? 3'd3 : (srow >= 16'd60)  ? 3'd2 :
                (srow >= 16'd30)  ? 3'd1 : 3'd0;
            case (b)
                3'd0: band_color=16'hF800; 3'd1: band_color=16'h07E0;  // red, green
                3'd2: band_color=16'h001F; 3'd3: band_color=16'hFFE0;  // blue, yellow
                3'd4: band_color=16'h07FF; 3'd5: band_color=16'hF81F;  // cyan, magenta
                3'd6: band_color=16'hFFFF; default: band_color=16'h8410; // white, grey
            endcase
        end
    endfunction
    wire [15:0] bands_pat = band_color(wy);   // writer: colour for source row wy

    // DIAGNOSTIC: PAT_MODE selects the written pattern.
    //   0 = SOLID RED everywhere.
    //   1 = 8 horizontal colour bands.
    //   2 = ADDRESS-AS-DATA column gradient: pixel value encodes its OWN column x
    //       in the colour. Perfect read/write -> a smooth L-to-R gradient. A
    //       period-2 read/write error shows as a regular comb; the value at each
    //       column reveals which address it actually came from.
    //   3 = EVEN/ODD column test: even columns BLACK, odd columns WHITE. The
    //       cleanest write-vs-read phase probe. Perfect -> fine black/white comb.
    //       If even/odd merge or swap -> the DDR3 word-phase (DDR even/odd) is
    //       the culprit. THIS is the active probe for the period-2 stripes.
    // PAT_MODE: 1=colour bars (visual), 4=flat grey, 5=SCRAMBLE (per-pixel addr hash,
    // for the UART read-vs-expected diagnostic on the real read path).
    localparam integer PAT_MODE = 1;   // 8 colour bars - visual quality test
    // gradient: map x (0..319) to a colour ramp - R from high bits, B from low.
    wire [15:0] grad_pat = { wx[8:4], wx[8:3], wx[4:0] };
    wire [15:0] evenodd  = wx[0] ? 16'hFFFF : 16'h0000;   // odd=white, even=black
    // PAT_MODE=5: SCRAMBLE - each pixel = scramble(its address). Adjacent pixels
    // differ in many bits, so the UART read-vs-expected check can detect ANY byte-lane
    // skew / wrong-address read on ddr3video's REAL read path (mirrors the CRC probe).
    function [15:0] scramble; input [25:0] a;
        scramble = ({a[15:0]} * 16'h9E37) ^ 16'hA5A5; endfunction
    wire [15:0] wpat = (PAT_MODE == 0) ? 16'hF800 :
                       (PAT_MODE == 1) ? bands_pat :
                       (PAT_MODE == 2) ? grad_pat :
                       (PAT_MODE == 4) ? 16'h8410 :   // flat mid-grey
                       (PAT_MODE == 5) ? scramble(waddr_c) :
                                         evenodd;

    reg        w_wr;                  // writer's port request (writes only); 1-cyc pulse
    reg        w_pending;             // a write was issued, waiting for busy to rise
    reg [25:0] w_addr;
    reg [15:0] w_din;
    always @(posedge pclk) begin
        w_wr <= 1'b0;
        if (!pclk_resetn) begin
            wstate <= W_INIT; waddr_c <= 26'd0; wx <= 16'd0; wy <= 16'd0;
            fill_done <= 1'b0; w_pending <= 1'b0;
        end else case (wstate)
            W_INIT: if (!ddr_busy) wstate <= W_RUN;   // wait for calibration
            W_RUN: begin
                // Clear the pending flag once the controller has ACCEPTED our write
                // (busy rises one cycle after it latches wr at IDLE).
                if (w_pending && ddr_busy) w_pending <= 1'b0;

                if (waddr_c == NPIX[25:0]) begin
                    fill_done <= 1'b1; wstate <= W_DONE;
                // ROOT-CAUSE FIX for the HW "1-of-4 columns correct" symptom:
                // the controller registers busy<=1 the cycle AFTER it accepts a
                // command (ddr3_controller IDLE: `if(rd|wr) busy<=1`). So `ddr_busy`
                // is STILL 0 for one cycle after we pulse w_wr. The old gate
                // (!ddr_busy) therefore fired AGAIN that next cycle, issuing a 2nd
                // write with the next address while the controller was mid-accept ->
                // dropped/misaligned BC4 writes -> 3 of 4 words corrupted.
                // Fix: after issuing, set w_pending and DON'T issue again until busy
                // has actually risen (command accepted), i.e. w_pending cleared.
                end else if (!w_pending && !ddr_busy && !do_refresh) begin
                    w_wr      <= 1'b1;
                    w_pending <= 1'b1;
                    w_addr    <= BASE + waddr_c;
                    w_din     <= wpat;
                    waddr_c   <= waddr_c + 26'd1;
                    if (wx == SRC_W - 16'd1) begin wx <= 16'd0; wy <= wy + 16'd1; end
                    else                          wx <= wx + 16'd1;
                end
            end
            W_DONE: ;   // hold; reader owns the port now
        endcase
    end

    // ====================== 720p timing ================================
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

    // delay de/hs/vs to match the line-buffer reader's pixel pipeline (2 pix_clk)
    reg [1:0] de_p, hs_p, vs_p;
    always @(posedge pix_clk) begin
        de_p <= {de_p[0], de};
        hs_p <= {hs_p[0], hsync};
        vs_p <= {vs_p[0], vsync};
    end
    wire de_o = de_p[1], hs_o = hs_p[1], vs_o = vs_p[1];

    // ====================== line-buffer reader =========================
    wire        r_rd;
    wire [25:0] r_addr;
    wire [15:0] pix565;
    wire        fetch_active;
    // SINGLE_WORD mode (=1): one pixel per DDR3 read via `dout` (the calibrated,
    // HW-proven path). The dout128 8-word BURST is HW-CONFIRMED non-functional on
    // this controller (only lane 0 valid; lanes 1..7 garbage even on clean memory),
    // so burst is dropped. Throughput: ~11 cyc/word = ~35 us per 320-word source
    // line. That FITS because the scaler replays each SOURCE line V_REPL(=3) times,
    // so the fetch budget is V_REPL*output_line = ~66 us (>> 35 us). See the
    // ddr3-single-word-fits + ddr3-dout128-broken notes. 320x240 source upscaled
    // HREP x VREP (4x3) -> 1280x720. LINE_W=1024 (>= 768 widest arcade line).
    groovy_linebuf_reader #(.LINE_W(1024), .LW_ADDR(10), .DDR_AW(26),
                            .SINGLE_WORD(1), .H_REPL(HREP), .V_REPL(VREP), .H_SH(HSH)) u_lbr (
        .pix_clk(pix_clk), .pix_rst(~hdmi_rst_n),
        .h_active(SRC_W), .v_active(SRC_H),
        .hcount(hcount), .vcount(vcount), .de(de),
        .line_start(line_start), .frame_start(frame_start),
        .pix_rgb565(pix565),
        // HOLD the reader's fetch FSM in reset until the boot writer has filled
        // the framebuffer (fill_done). Before that the arbiter gives DDR3 to the
        // writer and swallows the reader's reads -> the reader would desync. With
        // this gate it starts cleanly the moment the frame is ready.
        .pclk(pclk), .pclk_rst(~pclk_resetn | ~fill_done), .base_addr(BASE),
        .rd(r_rd), .addr(r_addr),
        .busy(ddr_busy), .data_ready(ddr_data_ready),
        .dout128(ddr_dout128), .dout(ddr_dout),
        .fetch_active(fetch_active),
        .dbg_lbwe(dbg_lbwe), .dbg_lbdata(dbg_lbdata), .dbg_fillline(dbg_fillline),
        .dbg_col(dbg_col), .dbg_fstate(dbg_fstate),
        .dbg_fe(dbg_fe), .dbg_pr(dbg_pr), .dbg_dr(dbg_dr));

    // ---- DDR3 READ-DATA CHECK (before the scaler): on each line-buffer write,
    // compare the value the reader got from DDR3 to the expected band colour for the
    // source line being filled. LBE = wrong words written into the buffer; LBT = total.
    // If LBE is ~87% -> the DDR3 READ is broken (data enters the buffer already wrong).
    // If LBE ~ 0 but the output ERR is ~87% -> the line-buffer/scaler read is broken.
    wire        dbg_lbwe; wire [15:0] dbg_lbdata, dbg_fillline, dbg_col; wire [2:0] dbg_fstate;
    wire [15:0] dbg_fe, dbg_pr, dbg_dr;
    reg [15:0] q_fe, q_pr, q_dr, q_lk, q_rs; reg [7:0] q_st;
    always @(posedge sys_clk) begin q_fe<=busy_max; q_pr<=rd_cnt; q_dr<=dbg_dr; q_st<=stall_state; q_lk<=lk_drop; q_rs<=rst_cnt; end
    wire [15:0] lb_exp = band_color(dbg_fillline);
    // CO = max fetch column EVER reached; FS = current fetch FSM state. If CO never
    // nears hact_s(320) the per-word reads aren't completing; FS shows where it sits
    // (0=FIDLE 1=FSETTLE 2=FREAD 3=FWAIT 4=FDRAIN 5=FDONE).
    reg [15:0] co_max=0; reg [2:0] fs_snap=0;
    always @(posedge pclk) begin
        if (dbg_col > co_max) co_max <= dbg_col;
        fs_snap <= dbg_fstate;
    end

    // ---- THROUGHPUT PROBE (pclk) -----------------------------------------
    // The fetch does only ~36 words/frame (~46k pclk cycles per word) though a
    // controller READ is ~9 cycles. Two hypotheses: (A) busy stays high ~46k
    // cycles between the reader's reads (controller back-pressure/refresh hang)
    // -> reader parks in FREAD; (B) the reader issues rd rarely. These two taps
    // replace the now-understood E(fs_edge=frames)/R(pclk_rst=frozen) fields:
    //   BR = worst consecutive run of (reader in FREAD && busy) cycles, i.e. how
    //        long the reader is BLOCKED wanting to issue rd but busy is high. This
    //        is the actual per-read stall. RESET each report window (not all-time)
    //        so a one-time boot stall doesn't dominate the typical gap. If BR ~46k
    //        the controller holds busy ~46k cyc every read -> per-read stall.
    //   RC = total r_rd pulses issued (cumulative). RC ~= D -> every issued read
    //        completes (reader is rd/busy-limited, not data-dropped).
    // FREAD = fstate 2 (FIDLE0 FSETTLE1 FREAD2 FWAIT3 FDRAIN4 FDONE5).
    // The reader actually parks in FWAIT (fstate 3), waiting for data_ready - NOT in
    // FREAD. So measure the stall there: how long it sits in FWAIT, and what the
    // controller state is meanwhile.
    // PER-FRAME FETCH-STATE HISTOGRAM. Earlier snapshot probes were unreliable
    // (BR=0, ST=00=uninit default, RS=0). Ground truth: count pclk cycles the fetch
    // FSM spends in each state during ONE frame, latched at fs_edge. States:
    // FIDLE0 FSETTLE1 FREAD2 FWAIT3 FDRAIN4 FDONE5. A frame is ~1.65M pclk cyc.
    //   BR (reuse) = cycles in FIDLE / 16  (idle = credit-paced waiting / nothing to do)
    //   LK (reuse) = cycles in FREAD / 16  (waiting for !busy to issue rd)
    //   RS (reuse) = cycles in FWAIT / 16  (waiting for data_ready after rd)
    //   RC stays = total rd pulses. Divided by 16 so 1.65M cyc fits 16 bits (~103k).
    reg [19:0] c_idle=0, c_read=0, c_wait=0;     // this-frame accumulators
    reg [15:0] h_idle=0, h_read=0, h_wait=0;     // latched last-frame (cyc/16)
    reg [15:0] rd_cnt=0;
    reg [2:0] fsx=0;   // frame_start crossed pix_clk -> pclk
    always @(posedge pclk) fsx <= {fsx[1:0], frame_start};
    wire pfs_edge = (fsx[2]==1'b0) && (fsx[1]==1'b1);   // rising edge of frame_start in pclk
    always @(posedge pclk) begin
        if (pfs_edge) begin
            h_idle <= c_idle[19:4]; h_read <= c_read[19:4]; h_wait <= c_wait[19:4];
            c_idle <= 0; c_read <= 0; c_wait <= 0;
        end else begin
            if (dbg_fstate == 3'd0) c_idle <= c_idle + 1'b1;
            if (dbg_fstate == 3'd2) c_read <= c_read + 1'b1;
            if (dbg_fstate == 3'd3) c_wait <= c_wait + 1'b1;
        end
        if (r_rd && rd_cnt!=16'hFFFF) rd_cnt <= rd_cnt + 1'b1;
    end
    // RAW data_ready / busy behaviour, per frame (/16). Disambiguates stuck-high vs
    // pulsing. ID <- data_ready-high cycles/16 ; RD <- busy-high cycles/16. If
    // data_ready is STUCK high, ID ~= frame (0x19000). Normal: ~ rd_count (a few k).
    reg [19:0] c_dr=0, c_busy=0; reg [15:0] h_dr=0, h_busy=0;
    always @(posedge pclk) begin
        if (pfs_edge) begin h_dr<=c_dr[19:4]; h_busy<=c_busy[19:4]; c_dr<=0; c_busy<=0; end
        else begin
            if (ddr_data_ready) c_dr   <= c_dr   + 1'b1;
            if (ddr_busy)       c_busy <= c_busy + 1'b1;
        end
    end
    reg [7:0] stall_state=8'h00;   // ST field = live controller state snapshot
    reg [15:0] busy_max=0, lk_drop=0, rst_cnt=0;
    // ID <- data_ready-high/16, RD <- busy-high/16, WT <- FWAIT cycles, ST <- ddr_state
    always @(*) begin busy_max=h_dr; lk_drop=h_busy; rst_cnt=h_wait; stall_state=ddr_state; end
    // PER-FRAME LE/LT (reset each frame) so the ratio is visible (was all-time -> both
    // saturated at FFFFF, ratio unreadable). LT/frame ~= 320*240 = 0x12C00 words if every
    // line fetches; LE/frame = how many of those words are WRONG vs band_color. LE/LT
    // ratio = the true DDR3-read error rate now that lines actually fetch.
    reg [19:0]  lbe_a=0, lbt_a=0, lbe=0, lbt=0;
    always @(posedge pclk) begin
        if (!pclk_resetn) begin lbe_a<=0; lbt_a<=0; lbe<=0; lbt<=0; end
        else if (pfs_edge) begin lbe<=lbe_a; lbt<=lbt_a; lbe_a<=0; lbt_a<=0; end
        else if (dbg_lbwe) begin
            if (lbt_a!=20'hFFFFF) lbt_a<=lbt_a+1'b1;
            if (dbg_lbdata !== lb_exp && lbe_a!=20'hFFFFF) lbe_a<=lbe_a+1'b1;
        end
    end

    // ====================== DDR3 port arbitration ======================
    // Writer owns the port until fill_done, then the reader owns it. Refresh may
    // ONLY be injected when the active client is fully IDLE between transactions
    // - NOT merely "not asserting a command this cycle". A read is a multi-cycle
    // transaction (rd pulse -> ~6 cyc -> data_ready, ~11 cyc total in SINGLE_WORD
    // mode): injecting a refresh mid-transaction corrupts that line. So we gate
    // refresh on the
    // client's whole-transaction-idle signal:
    //   - reader: fetch_active low (the fetch FSM is in FIDLE)
    //   - writer: not currently issuing a write (single-cycle writes; safe)
    // and only when !ddr_busy (controller ready). Refresh is edge-issued (one
    // pulse) so it can't repeat while still due.
    // ====================== port mux (writer vs reader) ================
    // The Gowin IP handles refresh internally, so no refresh arbitration. The writer
    // owns the adapter port until fill_done, then the reader does. Both use the same
    // single-word rd/wr/busy/data_ready handshake the adapter presents.
    always @(*) begin
        if (!fill_done) begin
            a_wr       = w_wr;
            a_rd       = 1'b0;
            ddr_addr_m = w_addr;
            ddr_din    = w_din;
        end else begin
            a_wr       = 1'b0;
            a_rd       = r_rd;
            ddr_addr_m = r_addr;
            ddr_din    = 16'd0;
        end
    end

    // ============ EXPECTED-COLOUR CHECK (UART) - CANNOT BE FOOLED ============
    // Compare every OUTPUT pixel to the colour it MUST be, using the SAME band_color()
    // function the writer used (source_row = vcount/3, VREP=3). Single source of truth.
    // ERR = output pixels whose colour != expected this frame. A "mostly black" screen
    // scores ERR=huge (black where red expected = wrong), so this CAN'T be fooled like
    // a transition count. (Only valid for PAT_MODE==1 colour bars.)
    reg de_o_d, vs_o_d;
    reg [19:0] err_acc=0, err=0;        // wrong pixels this frame (acc / latched)
    reg [19:0] tot_acc=0, tot=0;        // total active pixels (denominator)
    reg [15:0] firstbad_h=16'hFFFF, firstbad_v=16'hFFFF, bad_this=0, bad_exp=0;
    // LEFT/RIGHT error split (DIAGNOSTIC): errors in the left eighth (hcount<160) vs
    // right eighth (hcount>=1120) of the 1280-wide output. left>>right => scanout
    // outruns fetch / fill-latency on the left edge; roughly equal => DDR3 data
    // corruption (uniform). Counted /16 (>>4) so they fit the LE/LT report fields.
    reg [19:0] errL_acc=0, errR_acc=0; reg [15:0] errL=0, errR=0;
    // BLACK-error split: how many wrong pixels are exactly 0x0000 (read returned ZERO
    // = timing/swallow/unfilled) vs a NON-zero wrong colour (byte-lane/DQS scramble).
    // errB_acc = black wrong px; (err_acc - errB) = coloured wrong px. Both /16.
    reg [19:0] errB_acc=0; reg [15:0] errB=0;
    wire [15:0] exp_now = band_color(vcount / 16'd3);   // SAME function as the writer
    always @(posedge pix_clk) begin
        if (~hdmi_rst_n) begin
            err_acc<=0; err<=0; tot_acc<=0; tot<=0; de_o_d<=0; vs_o_d<=0;
            firstbad_h<=16'hFFFF; firstbad_v<=16'hFFFF;
            errL_acc<=0; errR_acc<=0; errL<=0; errR<=0; errB_acc<=0; errB<=0;
        end else begin
            de_o_d <= de_o; vs_o_d <= vs_o;
            if (vs_o && !vs_o_d) begin   // latch per frame
                err <= err_acc; tot <= tot_acc; err_acc<=0; tot_acc<=0;
                errL <= errL_acc[19:4]; errR <= errR_acc[19:4]; errL_acc<=0; errR_acc<=0;
                errB <= errB_acc[19:4]; errB_acc<=0;
                firstbad_h <= 16'hFFFF; firstbad_v <= 16'hFFFF;
            end
            if (de_o) begin
                if (tot_acc!=20'hFFFFF) tot_acc <= tot_acc + 1'b1;
                if (pix565 !== exp_now) begin
                    if (err_acc!=20'hFFFFF) err_acc <= err_acc + 1'b1;
                    if (pix565 == 16'd0 && errB_acc!=20'hFFFFF) errB_acc <= errB_acc + 1'b1;
                    if (hcount < 16'd160     && errL_acc!=20'hFFFFF) errL_acc <= errL_acc + 1'b1;
                    if (hcount >= 16'd1120   && errR_acc!=20'hFFFFF) errR_acc <= errR_acc + 1'b1;
                    if (firstbad_h==16'hFFFF) begin
                        firstbad_h <= hcount; firstbad_v <= vcount;
                        bad_this <= pix565; bad_exp <= exp_now;
                    end
                end
            end
        end
    end

    // ---- REFRESH-RATE probe (pclk): count refreshes per ~16.7ms window. A healthy
    // DDR3 needs ~2140 refreshes/frame (1 per 7.8us). If REF is far below that during
    // the read phase, refresh is STARVED -> the stored framebuffer decays -> rain.
    // Window = 1_666_666 pclk cycles (~16.7ms @99.8MHz).
    reg [20:0] ref_win=0; reg [15:0] ref_acc=0, ref_cnt=0;
    always @(posedge pclk) begin
        if (!pclk_resetn) begin ref_win<=0; ref_acc<=0; ref_cnt<=0; end
        else begin
            if (ref_win >= 21'd1_666_666) begin
                ref_cnt <= ref_acc; ref_acc <= (refresh_ack?16'd1:16'd0); ref_win<=0;
            end else begin
                ref_win <= ref_win + 1'b1;
                if (refresh_ack && ref_acc!=16'hFFFF) ref_acc <= ref_acc + 1'b1;
            end
        end
    end

    // CDC to sys_clk for UART. q_bad=ERR (wrong px/frame), q_chk=TOT[19:4] (total px
    // hi bits), q_pp=expected colour, q_pt=got colour at first bad, q_ref=refreshes.
    // NL = max source line the fetch reached in the last frame (latched at vsync). If
    // NL < SRC_H(240) the fetch is BANDWIDTH-STARVED (can't keep up) -> scanout reads
    // unfilled buffers -> black. NL~240 means throughput is fine and any error is data.
    reg [15:0] nl_max=0, nl_hold=0; reg vs_e=0;
    always @(posedge pix_clk) begin
        vs_e <= vsync;
        if (vsync && !vs_e) begin nl_hold <= nl_max; nl_max <= 0; end
        else if (dbg_fillline > nl_max) nl_max <= dbg_fillline;
    end
    reg [15:0] q_nl, q_co; reg [2:0] q_fs;
    reg [19:0] q_bad, q_tot, q_lbe, q_lbt; reg [15:0] q_pt, q_pp, q_fbv, q_fbh; reg [25:0] q_wa; reg q_fd;
    always @(posedge sys_clk) begin
        q_co<=co_max; q_fs<=fs_snap;
        q_bad<=err; q_tot<=tot; q_pt<=bad_this; q_pp<=bad_exp;
        q_wa<=waddr_c; q_fd<=fill_done; q_fbv<=firstbad_v; q_fbh<=firstbad_h;
        q_lbe<={4'd0,errL}; q_lbt<={4'd0,errB};  // LL field=LEFT errors/16, EB field=BLACK(0x0000) errors/16
        q_nl<=nl_hold;
    end

    wire [7:0] tx_din; wire tx_wr, tx_busy;
    uart_tx_V2 #(.clk_freq(27_000_000), .uart_freq(115200)) u_dbgtx (
        .clk(sys_clk), .din(tx_din), .wr_en(tx_wr), .tx_busy(tx_busy), .tx_p(uart_txp));
    function [7:0] hxd; input [3:0] n; hxd = (n<4'd10)?(8'h30+n):(8'h41+n-4'd10); endfunction
    // "TRA=xxxxx MAX=xxxx H=xxxx V=xxxx P=xxxx/xxxx\r\n"
    //   TRA  = total pixel transitions in the last frame (clean colour bars ~ a few
    //          thousand = bars*lines; rainy = huge). MAX = worst single line's
    //          transitions (clean ~ #bars; rainy = hundreds). H/V = first transition
    //          position; P = prev/this colours there. Alignment-free, can't lie.
    localparam [7:0] DBGLEN = 8'd127;
    reg [7:0] di=0; reg [7:0] dtx=0; reg dwr=0; reg [2:0] dst=0; reg [23:0] dhold=0;
    reg [7:0] dlb;
    always @(*) begin
        case (di)
            // ERR = wrong OUTPUT pixels/frame (vs band colour). LBE = wrong words read
            // from DDR3 INTO the line buffer (vs band colour). LBT = total such words.
            // THE SPLIT: LBE high -> DDR3 READ broken (data wrong entering buffer);
            // LBE~0 + ERR high -> scaler/buffer read broken. P = expected/got at first
            // bad output pixel. FD = writer fill_done.
            0:dlb="E";1:dlb="R";2:dlb="R";3:dlb="=";
            4:dlb=hxd(q_bad[19:16]);5:dlb=hxd(q_bad[15:12]);6:dlb=hxd(q_bad[11:8]);7:dlb=hxd(q_bad[7:4]);8:dlb=hxd(q_bad[3:0]);9:dlb=" ";
            // LL = LEFT-eighth (hcount<160) output errors/16. RR = RIGHT-eighth
            // (hcount>=1120) errors/16. LL>>RR => scanout outruns fetch (fill latency
            // on left edge). LL~RR => uniform DDR3 data corruption.
            10:dlb="L";11:dlb="L";12:dlb="=";
            13:dlb=hxd(q_lbe[19:16]);14:dlb=hxd(q_lbe[15:12]);15:dlb=hxd(q_lbe[11:8]);16:dlb=hxd(q_lbe[7:4]);17:dlb=hxd(q_lbe[3:0]);18:dlb=" ";
            // EB = errors that are exactly BLACK(0x0000)/16. EB~=ERR/16 => reads return
            // ZERO (timing/swallow/unfilled). EB<<ERR => scrambled colour (byte-lane/DQS).
            19:dlb="E";20:dlb="B";21:dlb="=";
            22:dlb=hxd(q_lbt[19:16]);23:dlb=hxd(q_lbt[15:12]);24:dlb=hxd(q_lbt[11:8]);25:dlb=hxd(q_lbt[7:4]);26:dlb=hxd(q_lbt[3:0]);27:dlb=" ";
            28:dlb="P";29:dlb="=";
            30:dlb=hxd(q_pp[15:12]);31:dlb=hxd(q_pp[11:8]);32:dlb=hxd(q_pp[7:4]);33:dlb=hxd(q_pp[3:0]);
            34:dlb="/";
            35:dlb=hxd(q_pt[15:12]);36:dlb=hxd(q_pt[11:8]);37:dlb=hxd(q_pt[7:4]);38:dlb=hxd(q_pt[3:0]);39:dlb=" ";
            40:dlb="F";41:dlb="D";42:dlb="=";43:dlb=hxd({3'b0,q_fd});44:dlb=" ";
            // V = vcount of the first bad output pixel (1024px wide -> tells if the
            // bulk error is band-0 top-left (data) or a shifted band boundary (mapping)).
            45:dlb="V";46:dlb="=";
            47:dlb=hxd(q_fbv[15:12]);48:dlb=hxd(q_fbv[11:8]);49:dlb=hxd(q_fbv[7:4]);50:dlb=hxd(q_fbv[3:0]);51:dlb=" ";
            // H = hcount of the first bad output pixel. Small H every line = horizontal
            // fill latency (left edge); H spanning full width = whole-line failure.
            52:dlb="H";53:dlb="=";
            54:dlb=hxd(q_fbh[15:12]);55:dlb=hxd(q_fbh[11:8]);56:dlb=hxd(q_fbh[7:4]);57:dlb=hxd(q_fbh[3:0]);58:dlb=" ";
            // NL = max line the fetch reached last frame (want ~00F0=240). NL<240 = fetch
            // bandwidth-starved -> black. NL~240 + ERR high = data, not throughput.
            59:dlb="N";60:dlb="L";61:dlb="=";
            62:dlb=hxd(q_nl[15:12]);63:dlb=hxd(q_nl[11:8]);64:dlb=hxd(q_nl[7:4]);65:dlb=hxd(q_nl[3:0]);66:dlb=" ";
            // CO = max fetch column EVER reached (want ~0140=320). FS = current fetch state.
            67:dlb="C";68:dlb="O";69:dlb="=";
            70:dlb=hxd(q_co[15:12]);71:dlb=hxd(q_co[11:8]);72:dlb=hxd(q_co[7:4]);73:dlb=hxd(q_co[3:0]);74:dlb=" ";
            75:dlb="F";76:dlb="S";77:dlb="=";78:dlb=hxd({1'b0,q_fs});79:dlb=" ";
            // PER-FRAME FETCH-STATE HISTOGRAM (cycles/16, one frame ~= 1.65M cyc = ~0x19000):
            //   ID = cycles in FIDLE  (credit-paced idle / nothing to fetch)
            //   RD = cycles in FREAD  (waiting !busy to issue rd)
            //   WT = cycles in FWAIT  (waiting data_ready after rd)
            // RC = rd pulses. D = data_ready. ST = live controller state (IDLE4 READ5
            // WRITE6 REFRESH7 WLEVEL8 CALIB9). Sum ID+RD+WT ~= 0x19000 accounts a frame.
            80:dlb="I";81:dlb="D";82:dlb="=";
            83:dlb=hxd(q_fe[15:12]);84:dlb=hxd(q_fe[11:8]);85:dlb=hxd(q_fe[7:4]);86:dlb=hxd(q_fe[3:0]);87:dlb=" ";
            88:dlb="R";89:dlb="C";90:dlb="=";
            91:dlb=hxd(q_pr[15:12]);92:dlb=hxd(q_pr[11:8]);93:dlb=hxd(q_pr[7:4]);94:dlb=hxd(q_pr[3:0]);95:dlb=" ";
            96:dlb="D";97:dlb="=";
            98:dlb=hxd(q_dr[15:12]);99:dlb=hxd(q_dr[11:8]);100:dlb=hxd(q_dr[7:4]);101:dlb=hxd(q_dr[3:0]);102:dlb=" ";
            103:dlb="S";104:dlb="T";105:dlb="=";
            106:dlb=hxd(q_st[7:4]);107:dlb=hxd(q_st[3:0]);108:dlb=" ";
            109:dlb="R";110:dlb="D";111:dlb="=";
            112:dlb=hxd(q_lk[15:12]);113:dlb=hxd(q_lk[11:8]);114:dlb=hxd(q_lk[7:4]);115:dlb=hxd(q_lk[3:0]);116:dlb=" ";
            117:dlb="W";118:dlb="T";119:dlb="=";
            120:dlb=hxd(q_rs[15:12]);121:dlb=hxd(q_rs[11:8]);122:dlb=hxd(q_rs[7:4]);123:dlb=hxd(q_rs[3:0]);
            125:dlb=8'h0D;126:dlb=8'h0A;default:dlb=" ";
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

    // ====================== RGB565 -> RGB888 ===========================
    wire [4:0] r5 = pix565[15:11];
    wire [5:0] g6 = pix565[10:5];
    wire [4:0] b5 = pix565[4:0];
    wire [7:0] r8 = {r5, r5[4:2]};       // replicate top bits into the low ones
    wire [7:0] g8 = {g6, g6[5:4]};
    wire [7:0] b8 = {b5, b5[4:2]};

    // ====================== DVI_TX (Gowin IP) ==========================
    DVI_TX_Top u_dvi (
        .I_rst_n(hdmi_rst_n),
        .I_serial_clk(serial_clk),
        .I_rgb_clk(pix_clk),
        .I_rgb_vs(vs_o), .I_rgb_hs(hs_o), .I_rgb_de(de_o),
        .I_rgb_r(r8), .I_rgb_g(g8), .I_rgb_b(b8),
        .O_tmds_clk_p(O_tmds_clk_p),   .O_tmds_clk_n(O_tmds_clk_n),
        .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n));

    // ====================== LEDs (BOARD-number convention) ==============
    // board[k] = lit on the LED labelled k on the Dock (the Dock LEDs are
    // scrambled vs led[] bit index - see led_board_map.vh / tang-led-mapping).
    //   board0 = ddr_lock        board1 = tmds_lock     board2 = fill_done
    //   board4 = fetch_active     board5 = heartbeat
    //   board3 = (L16, dim w/ DDR3) - left off
    reg [24:0] hb;
    always @(posedge sys_clk or negedge sys_resetn)
        if (!sys_resetn) hb <= 25'd0; else hb <= hb + 25'd1;
    wire [5:0] board;
    assign board[0] = init_calib_complete;   // DDR3 IP trained
    assign board[1] = tmds_lock;
    assign board[2] = fill_done;
    assign board[3] = 1'b0;          // L16 - unreliable, unused
    assign board[4] = fetch_active;
    assign board[5] = hb[24];        // heartbeat
    // scramble board[] -> led[] (active-low). See led_board_map.vh.
    assign led = ~{ board[0], board[2], board[4], board[3], board[5], board[1] };

endmodule

`default_nettype wire
