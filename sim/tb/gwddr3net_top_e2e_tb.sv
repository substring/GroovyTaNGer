// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - END-TO-END test of the real gwddr3net_top.sv: Ethernet frames clocked
// into the real udp.sv over RMII -> parser -> blit_rx -> async FIFO -> DDR3 writer ->
// adapter -> (Gowin DDR3 IP *model*) -> line-buffer reader -> raster pixels.
//
// The DUT is gwddr3net_top itself; only the Gowin PLL/CLKDIV/DVI primitives
// (gwline_sim_stubs.sv) and the encrypted DDR3 IP (gwddr3_ip_model.sv) are replaced.
//
// Three independent verdicts, because "the picture looks wrong" has three causes:
//   WRITE  every BL8 beat the IP model commits is checked as it happens: right address
//          (strictly sequential, none skipped), right data for the frame being sent.
//   STORE  at the end, the model's memory is compared word for word with the last frame.
//   SHOW   every output line is compared with every frame sent; a line is good if it is
//          pixel-exact from ONE frame. (With a single shared buffer a line fetched while
//          it is being overwritten legitimately mixes two frames: that is tearing, not
//          corruption, and it is counted apart as "torn".)
//
// Plusargs: +DIR=<dir with stream_*.hex>
//           +MODE=0 continuous stream at 1.0x of the raster (default)
//                 1 burst: every datagram back to back at wire speed, frames back to back
//                 2 one frame at 1.0x, then silence
//           +STRICT=<0|1>  see gwddr3_ip_model.sv
`timescale 1ns/1ps
`include "rmii.svh"
`default_nettype none

module gwddr3net_top_e2e_tb;
    localparam real PIX_T   = 13.468;
    localparam real FRAME_T = 1650.0 * 750.0 * PIX_T;
    localparam real DGRAM_T = FRAME_T / 120.0;
    localparam integer MAXF = 8;
    localparam integer NPIX = 320 * 240;

    reg clk27 = 0;  always #18.5185 clk27 = ~clk27;
    reg clk50m = 0; always #10 clk50m = ~clk50m;
    reg rst_n = 0;

    reg  [1:0] rxd_drv = 0;  reg crs_drv = 0;  wire mdio_w;
    rmii netrmii(.clk50m(clk50m), .rx_crs(crs_drv), .mdc(), .txen(), .mdio(mdio_w),
                 .txd(), .rxd(rxd_drv));
    wire [5:0] led;  wire uart_txp;
    gwddr3net_top dut (.clk(clk27), .rst(rst_n), .netrmii(netrmii), .phyrst(),
        .ddr_dq(), .ddr_dqs(), .ddr_dqs_n(), .ddr_addr(), .ddr_bank(), .ddr_cs(), .ddr_we(),
        .ddr_ras(), .ddr_cas(), .ddr_clk(), .ddr_clk_n(), .ddr_reset_n(), .ddr_cke(),
        .ddr_odt(), .ddr_dm(),
        .O_tmds_clk_p(), .O_tmds_clk_n(), .O_tmds_data_p(), .O_tmds_data_n(),
        .led(led), .uart_txp(uart_txp));

    function automatic [15:0] pix(input integer f, input integer l, input integer c);
        pix = (l * 16'h9E37) ^ (c * 16'h7F4B) ^ (f * 16'h1D2F) ^ 16'h5A5A;
    endfunction

    // ------------------------------------------------------------ stream from file
    reg [7:0]  sbytes [0:800_000-1];
    reg [63:0] sidx   [0:1023];
    integer nframes_eth = 0, nf_net = 0;
    string dir = ".";
    integer mode = 0;

    task automatic send_byte(input [7:0] b);
        integer k; reg [7:0] v;
        begin v = b; for (k = 0; k < 4; k = k + 1) begin rxd_drv = v[1:0]; v = v >> 2; @(posedge clk50m); end end
    endtask
    task automatic send_eth(input integer i);
        integer off, len, j;
        begin
            off = sidx[i][31:0];  len = sidx[i][55:32];
            crs_drv = 1;
            for (j = 0; j < 7; j = j + 1) send_byte(8'h55);
            send_byte(8'hD5);
            for (j = 0; j < len; j = j + 1) send_byte(sbytes[off + j]);
            crs_drv = 0;  rxd_drv = 0;
        end
    endtask
    task automatic wait_until(input real t);
        begin if ($realtime < t) #(t - $realtime); @(posedge clk50m); end
    endtask

    integer i, f, d;  real t0;  reg sender_done = 0;
    initial begin
        void'($value$plusargs("DIR=%s", dir));
        void'($value$plusargs("MODE=%d", mode));
        $readmemh({dir, "/stream_bytes.hex"}, sbytes);
        $readmemh({dir, "/stream_idx.hex"}, sidx);
        while (nframes_eth < 1024 && sidx[nframes_eth] !== 64'hx && sidx[nframes_eth][55:32] != 0)
            nframes_eth = nframes_eth + 1;
        nf_net = (nframes_eth - 1) / 121;
        if (mode == 2) nf_net = 1;
        $display("stream: %0d network frames, mode=%0d", nf_net, mode);

        force dut.udp_inst.phy_rdy = 1'b0;
        repeat (20) @(posedge clk50m);  rst_n = 1;
        repeat (20) @(posedge clk50m);  force dut.udp_inst.phy_rdy = 1'b1;
        wait (dut.init_calib_complete);
        #5000;

        @(posedge clk50m);                              // dibits must be edge-aligned: udp.sv
        send_eth(0);                                    // needs the whole 7-byte preamble
        #200_000;
        t0 = $realtime + 300_000.0;

        i = 1;
        for (f = 0; f < nf_net; f = f + 1) begin
            if (mode == 1) begin
                repeat (48) @(posedge clk50m);          // 96-bit inter-frame gap
                send_eth(i);  i = i + 1;
                for (d = 0; d < 120; d = d + 1) begin
                    repeat (48) @(posedge clk50m);
                    send_eth(i);  i = i + 1;
                end
            end else begin
                wait_until(t0 + f * FRAME_T - 72 * 80.0 - 48 * 20.0);
                send_eth(i);  i = i + 1;
                for (d = 0; d < 120; d = d + 1) begin
                    wait_until(t0 + f * FRAME_T + d * DGRAM_T);
                    send_eth(i);  i = i + 1;
                end
            end
        end
        sender_done = 1;
    end

    // ------------------------------------------------------------ WRITE verdict
    // Every committed beat, as the IP model stores it.
    integer wf = -1, exp_addr = 0, w_beats = 0, w_bad_data = 0, w_skipped = 0, w_masked = 0;
    integer w_per_frame [0:MAXF-1];
    integer w_msgs = 0;
    integer k, idx;
    initial for (k = 0; k < MAXF; k = k + 1) w_per_frame[k] = 0;
    always @(posedge dut.u_ddr3.clk_out) if (dut.u_ddr3.ev_wr) begin
        // a beat at or below the last one written = the writer wrapped to a new frame
        if (wf < 0 || dut.u_ddr3.ev_addr < exp_addr - 8) begin
            if (wf >= 0 && exp_addr != NPIX) begin
                w_skipped = w_skipped + (NPIX - exp_addr) / 8;
                if (w_msgs < 8) begin w_msgs = w_msgs + 1; $display("  WRITE: frame %0d ended at word %0d, tail never written", wf, exp_addr); end
            end
            wf = wf + 1;  exp_addr = 0;
        end
        if (dut.u_ddr3.ev_mask != 16'd0) w_masked = w_masked + 1;
        if (dut.u_ddr3.ev_addr > exp_addr) begin
            w_skipped = w_skipped + (dut.u_ddr3.ev_addr - exp_addr) / 8;
            if (w_msgs < 8) begin w_msgs = w_msgs + 1; $display("  WRITE: frame %0d skipped words %0d..%0d (line %0d col %0d) at %0t", wf, exp_addr,
                                          dut.u_ddr3.ev_addr - 1, exp_addr / 320, exp_addr % 320, $time); end
        end
        if (dut.u_ddr3.ev_mask == 16'd0 || dut.u_ddr3.ev_mask[15:14] == 2'b00) exp_addr = (dut.u_ddr3.ev_addr & ~7) + 8;
        w_beats = w_beats + 1;
        if (wf >= 0 && wf < MAXF) w_per_frame[wf] = w_per_frame[wf] + 1;
        for (k = 0; k < 8; k = k + 1) begin
            idx = dut.u_ddr3.ev_addr + k;
            if (!dut.u_ddr3.ev_mask[2*k] &&
                dut.u_ddr3.ev_data[k*16 +: 16] !== pix(wf, idx / 320, idx % 320)) w_bad_data = w_bad_data + 1;
        end
    end

`ifdef LEGACY_PROBE
    // Pre-2026-10 port sharing only: how often the writer BELIEVES a beat was accepted
    // (it saw the shared `busy` rise) versus how often the adapter really latched one.
    integer wr_believed = 0, wr_latched = 0, fifo_max = 0;
    always @(posedge dut.pclk) begin
        if (dut.u_ddrwr.pending && dut.ddr_busy && (dut.u_ddrwr.st == 3 || dut.u_ddrwr.st == 4))
            wr_believed = wr_believed + 1;
        if (dut.u_adapt.st == 0 && dut.init_calib_complete && !dut.a_rd && (dut.a_wr || dut.a_wr_beat))
            wr_latched = wr_latched + 1;
    end
    final $display("LEGACY writer believed %0d beats accepted, adapter latched %0d -> %0d discarded silently",
                   wr_believed, wr_latched, wr_believed - wr_latched);
`endif

    // ------------------------------------------------------------ SHOW verdict (pix_clk)
    wire pclk = dut.pix_clk;
    reg [15:0] hc1, hc2, vc1, vc2;  reg de1, de2;
    always @(posedge pclk) begin
        hc1 <= dut.hcount; hc2 <= hc1;
        vc1 <= dut.vcount; vc2 <= vc1;
        de1 <= dut.de;     de2 <= de1;
    end
    integer vframe = -1, good_total, lines_good = 0, lines_torn = 0, lines_bad = 0, lines_all = 0;
    integer bad [0:MAXF-1];  integer good_from [0:MAXF-1];  reg in_line = 0;
    integer anybad, pxbad, fr_torn, fr_bad;  reg pm;
    initial for (k = 0; k < MAXF; k = k + 1) begin bad[k] = 0; good_from[k] = 0; end
    initial begin anybad = 0; fr_torn = 0; fr_bad = 0; end

    // Lines that started before the reader had fetched anything (it leaves reset when
    // the first frame has landed, at an arbitrary raster position) cannot show that
    // frame; judging starts with the first line that begins after its first fetch.
    reg fetched = 0, judge = 0;
    always @(posedge pclk) begin
        if (dut.u_lbr.buf_line0 != 16'hFFFF) fetched <= 1'b1;
        if (de1 && !de2) judge <= fetched;
    end
    integer j;
`ifdef SHOW_DBG
    // the top's static-picture stability probes (UART FD/SD), once per video frame
    always @(posedge pclk) if (dut.frame_start)
        $display("%t STAB vframe %0d RD=%0d FD=%0d SD=%0d FK=%h SK=%h PW=%0d", $time, vframe,
                 dut.frame_cnt, dut.fdiff, dut.sdiff, dut.fck_prev, dut.sck_prev, dut.port_wait_max);
    // first mismatching pixel of each line, against the newest frame received so far
    integer dbg_col, dbg_last, dbg_cnt, dbg_n = 0;  reg [15:0] dbg_got, dbg_want, dbg_line;
    always @(posedge pclk) begin
        if (de2 && judge && !in_line) begin dbg_col = -1; dbg_cnt = 0; dbg_line = vc2; end
        if (de2 && judge && dbg_col < 0 && nf_net > 0 &&
            dut.pix565 !== pix(dut.frame_cnt > 0 ? dut.frame_cnt - 1 : 0, vc2 / 3, hc2 >> 2)) begin
            dbg_col = hc2; dbg_got = dut.pix565;
        end
        if (de2 && judge && nf_net > 0 &&
            dut.pix565 !== pix(dut.frame_cnt > 0 ? dut.frame_cnt - 1 : 0, vc2 / 3, hc2 >> 2)) begin
            dbg_cnt = dbg_cnt + 1; dbg_last = hc2;
            dbg_want = pix(dut.frame_cnt > 0 ? dut.frame_cnt - 1 : 0, vc2 / 3, hc2 >> 2);
        end
        if (!(de2 && judge) && in_line && anybad != 0 && dbg_n < 40) begin
            dbg_n = dbg_n + 1;
            $display("  SHOW: vframe %0d out line %0d (src %0d) first bad col %0d (src %0d) got %h want %h, %0d bad px, last bad col %0d",
                     vframe, dbg_line, dbg_line / 3, dbg_col, dbg_col >> 2, dbg_got, dbg_want, dbg_cnt, dbg_last);
        end
    end
`endif
    always @(posedge pclk) begin
        if (dut.frame_start) begin
            if (vframe >= 0 && judge) begin
                good_total = 0;
                for (j = 0; j < MAXF; j = j + 1) good_total = good_total + good_from[j];
                $write("video frame %0d: %0d/720 lines exact [", vframe, good_total);
                for (j = 0; j < MAXF; j = j + 1) if (good_from[j] != 0) $write(" net%0d:%0d", j, good_from[j]);
                $write(" ] torn=%0d CORRUPT=%0d   RD=%0d DP=%0d\n", fr_torn, fr_bad, dut.frame_cnt, dut.drop_cnt);
            end
            for (j = 0; j < MAXF; j = j + 1) good_from[j] = 0;
            fr_torn = 0;  fr_bad = 0;
            vframe = vframe + 1;
        end
        if (de2 && judge) begin
            in_line <= 1;
            pm = 0;
            for (j = 0; j < nf_net; j = j + 1) begin
                if (dut.pix565 !== pix(j, vc2 / 3, hc2 >> 2)) bad[j] = bad[j] + 1;
                else pm = 1;
            end
            if (!pm) anybad = anybad + 1;          // pixel belongs to NO frame ever sent
        end else if (in_line) begin
            in_line <= 0;
            pxbad = 1;
            for (j = 0; j < nf_net; j = j + 1) begin
                if (bad[j] == 0) begin good_from[j] = good_from[j] + 1; pxbad = 0; end
                bad[j] = 0;
            end
            lines_all = lines_all + 1;
            if (!pxbad) lines_good = lines_good + 1;
            else if (anybad == 0) begin lines_torn = lines_torn + 1; fr_torn = fr_torn + 1; end
            else begin lines_bad = lines_bad + 1; fr_bad = fr_bad + 1; end
            anybad = 0;
        end
    end

    // ------------------------------------------------------------ STORE verdict + summary
    integer s_ok, s_stale, s_other, a;  reg st;
    initial begin
        wait (sender_done);
        #(FRAME_T * 2.2);
        s_ok = 0; s_stale = 0; s_other = 0;
        for (a = 0; a < NPIX; a = a + 1) begin
            if (dut.u_ddr3.mem[a] === pix(nf_net - 1, a / 320, a % 320)) s_ok = s_ok + 1;
            else begin
                st = 0;
                for (k = 0; k < nf_net - 1; k = k + 1)
                    if (dut.u_ddr3.mem[a] === pix(k, a / 320, a % 320)) st = 1;
                if (st) s_stale = s_stale + 1; else s_other = s_other + 1;
            end
        end
        if (exp_addr != NPIX) begin
            w_skipped = w_skipped + (NPIX - exp_addr) / 8;
            $display("  WRITE: last frame %0d ended at word %0d, tail never written", wf, exp_addr);
        end
        $display("NET    RD=%0d/%0d frames completed, DP=%0d pixels dropped at the FIFO", dut.frame_cnt, nf_net, dut.drop_cnt);
        $display("WRITE  %0d beats committed (want %0d): skipped=%0d bad_data_words=%0d masked_beats=%0d",
                 w_beats, nf_net * NPIX / 8, w_skipped, w_bad_data, w_masked);
        $write  ("       per frame:");
        for (k = 0; k < nf_net; k = k + 1) $write(" %0d", w_per_frame[k]);
        $write("\n");
        $display("STORE  last frame in memory: %0d/%0d words right, %0d stale (older frame), %0d other",
                 s_ok, NPIX, s_stale, s_other);
        $display("SHOW   %0d output lines: %0d exact, %0d torn (two frames), %0d CORRUPT",
                 lines_all, lines_good, lines_torn, lines_bad);
        $display("IP     reads=%0d writes=%0d  strobes with ready low: cmd=%0d data=%0d  LOST: cmd=%0d data=%0d (strict=%0d)",
                 dut.u_ddr3.n_rd, dut.u_ddr3.n_wr, dut.u_ddr3.viol_cmd, dut.u_ddr3.viol_dat,
                 dut.u_ddr3.lost_cmd, dut.u_ddr3.lost_dat, dut.u_ddr3.strict);
        if (dut.frame_cnt == nf_net && dut.drop_cnt == 0 && w_skipped == 0 && w_bad_data == 0 &&
            w_beats == nf_net * NPIX / 8 && s_ok == NPIX && lines_bad == 0 &&
            dut.u_ddr3.lost_cmd == 0 && dut.u_ddr3.lost_dat == 0)
             $display("PASS: gwddr3net_top_e2e_tb");
        else $display("FAIL: gwddr3net_top_e2e_tb");
        $finish;
    end
endmodule

`default_nettype wire
