// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - END-TO-END test of gwline_top VIDEO_MODE 4: the raster follows the
// CMD_SWITCHRES modeline (rtl/core/groovy_modeline_ctl.v + the dynamic rPLL).
//
// The DUT is the real gwline_top #(.VIDEO_MODE(4)); the dynamic rPLL is the behavioural
// model in gwline_sim_stubs.sv (CLKOUT = 27 MHz * FBDIV / IDIV from its select inputs,
// CLKDIV a real /5), so the pixel clock really changes with the modeline.
//
// Stream: tools/gen_gwline_stream.py --modes (GroovyMAME dialect, RGB565, one line per
// pixel datagram). For each modeline segment the bench:
//   1. sends CMD_SWITCHRES and waits for the controller to apply it (and for the
//      PLL settle when the rPLL coefficients changed);
//   2. MEASURES the raster on the DUT's own timing outputs and checks it against the
//      modeline: N = smallest factor with pclk * N >= 25 MHz; active width ha*N and HSYNC
//      at hb*N .. he*N pix_clk after the line start; the REAL-TIME line period within
//      0.1 % of htotal / pclk (h_total is recomputed on the achieved clock); lines per
//      field = vtotal, or 263/262 alternating with `field` when interlaced; active lines
//      va (va/2); VSYNC starting at line vb (vb/2);
//   3. streams the segment's frames paced at the measured line rate, starting LEAD lines
//      before each field, and checks every output pixel: each frame must be shown
//      pixel-exact in a whole field, and no pixel may ever be neither black nor right;
//   4. counts pixel-domain resets: none when the rPLL coefficients did not change (a
//      seamless change, as for 320x240p -> 320x448i at one pclk), one when they did.
// Plusargs: +DIR=<stream dir>  +SEGS=<number of segments, default 3>  +LEAD=<lines, 16>
//           +QOI: the stream is QOI per line (gen_gwline_stream.py --modes ... --qoi), the
//                 frames are pixq() and the decoder must report no corrupted line (QE)
//                 and no dropped byte (QO).
`timescale 1ns/1ps
`include "rmii.svh"
`default_nettype none

module gwline_modeline_tb;
    localparam integer MAXF = 16, MAXS = 4;

    reg clk27 = 0;  always #18.5185 clk27 = ~clk27;
    reg clk50m = 0; always #10 clk50m = ~clk50m;
    reg rst_n = 0;

    reg  [1:0] rxd_drv = 0;  reg crs_drv = 0;  wire mdio_w;
    rmii netrmii(.clk50m(clk50m), .rx_crs(crs_drv), .mdc(), .txen(), .mdio(mdio_w),
                 .txd(), .rxd(rxd_drv));
    wire [5:0] led;  wire uart_txp;  wire hp_bck, hp_ws, hp_din, pa_en;
    gwline_top #(.VIDEO_MODE(4)) dut (.clk(clk27), .rst(rst_n), .netrmii(netrmii), .phyrst(),
                    .O_tmds_clk_p(), .O_tmds_clk_n(), .O_tmds_data_p(), .O_tmds_data_n(),
                    .led(led), .uart_txp(uart_txp),
                    .HP_BCK(hp_bck), .HP_WS(hp_ws), .HP_DIN(hp_din), .PA_EN(pa_en));

    function automatic [15:0] pix(input integer f, input integer l, input integer c);
        pix = (l * 16'h9E37) ^ (c * 16'h7F4B) ^ (f * 16'h1D2F) ^ 16'h5A5A;
    endfunction
    // keep in sync with gen_gwline_stream.py pixq()
    function automatic [15:0] pixq(input integer f, input integer l, input integer c);
        if (l % 8 == 7) pixq = pix(f, l, c);
        else            pixq = pix(f, l, c >> 4) ^ (((c >> 2) & 3) << 5);
    endfunction
    reg qoi = 1'b0;
    integer fx_want = 0;
    function automatic [15:0] want(input integer f, input integer l, input integer c);
        want = qoi ? pixq(f, l, c) : pix(f, l, c);
    endfunction

    // ------------------------------------------------------------ stream from file
    reg [7:0]  sbytes [0:2_000_000-1];
    reg [63:0] sidx   [0:4095];
    integer nframes_eth = 0;
    string dir = ".";
    integer lead = 16, nsegs = 3, errors = 0;

    task automatic send_byte(input [7:0] b);
        integer k; reg [7:0] v;
        begin v = b; for (k = 0; k < 4; k = k + 1) begin rxd_drv = v[1:0]; v = v >> 2; @(posedge clk50m); end end
    endtask
    task automatic send_eth(input integer i);
        integer off, len, j;
        begin
            off = sidx[i][31:0];  len = sidx[i][55:32];
            // start on a clk50m edge like every later dibit: started from another clock's
            // edge, the first dibit is overwritten before udp.sv samples it, and udp.sv
            // wants > 26 preamble cycles (a 7-byte preamble leaves no slack)
            @(posedge clk50m);
            crs_drv = 1;
            for (j = 0; j < 7; j = j + 1) send_byte(8'h55);
            send_byte(8'hD5);
            for (j = 0; j < len; j = j + 1) send_byte(sbytes[off + j]);
            crs_drv = 0;  rxd_drv = 0;
            repeat (48) @(posedge clk50m);              // inter-frame gap
        end
    endtask
    task automatic wait_until(input real t);
        begin if ($realtime < t) #(t - $realtime); @(posedge clk50m); end
    endtask

    // modeline of a CMD_SWITCHRES datagram (UDP payload at Ethernet offset 42)
    real    m_pclk;  integer m_ha, m_hb, m_he, m_ht, m_va, m_vb, m_ve, m_vt, m_il;
    task automatic decode_switchres(input integer i);
        integer o;  reg [63:0] d;
        begin
            o = sidx[i][31:0] + 42 + 1;
            d = {sbytes[o+7], sbytes[o+6], sbytes[o+5], sbytes[o+4], sbytes[o+3], sbytes[o+2], sbytes[o+1], sbytes[o]};
            m_pclk = $bitstoreal(d);
            o = o + 8;
            m_ha = {sbytes[o+1], sbytes[o]};    m_hb = {sbytes[o+3], sbytes[o+2]};
            m_he = {sbytes[o+5], sbytes[o+4]};  m_ht = {sbytes[o+7], sbytes[o+6]};
            m_va = {sbytes[o+9], sbytes[o+8]};  m_vb = {sbytes[o+11], sbytes[o+10]};
            m_ve = {sbytes[o+13], sbytes[o+12]}; m_vt = {sbytes[o+15], sbytes[o+14]};
            m_il = sbytes[o+16];
        end
    endtask

    // ------------------------------------------------------------ raster probes (pix_clk)
    wire pclk = dut.pix_clk;
    integer resets = 0;
    integer n_sw = 0, n_sol = 0;              // CMD_SWITCHRES parsed / PLL solutions
    always @(posedge clk50m) if (dut.switchres_valid) n_sw = n_sw + 1;
    always @(posedge dut.clk1m) if (dut.sr_res_valid) n_sol = n_sol + 1;
    // diagnostics for the 'never applied' message
    integer n_head = 0, n_tx = 0;
    always @(posedge clk50m) begin
        if (dut.rx_head_av && dut.rx_head_rdy) n_head = n_head + 1;
        if (dut.tx_req && dut.tx_req_rdy) n_tx = n_tx + 1;
    end
    integer n_dg = 0, n_blit = 0;  reg [7:0] last_cmd;  reg sop_q = 0;
    always @(posedge clk50m) begin
        if (dut.p_sop && dut.p_valid) begin n_dg = n_dg + 1; last_cmd = dut.p_data; end
        if (dut.blit_valid) n_blit = n_blit + 1;
    end
    always @(negedge dut.hdmi_rst_n) resets = resets + 1;

    // per line: pix_clk count, DE length, HSYNC start/end (from the line start), real time
    integer hc = 0, de_len = 0, de_cnt = 0, hs0 = -1, hs1 = -1, l_hs0 = -1, l_hs1 = -1, l_ht = 0;
    real    t_ls = 0.0, l_period = 0.0;
    reg     hs_q = 1;
    always @(posedge pclk) if (dut.hdmi_rst_n) begin
        if (dut.line_start) begin
            l_ht = hc;  t_ls = $realtime;
            if (de_cnt != 0) de_len = de_cnt;
            l_hs0 = hs0;  l_hs1 = hs1;
            hc = 0;  de_cnt = 0;  hs0 = -1;  hs1 = -1;
        end
        if (dut.de) de_cnt = de_cnt + 1;
        if (!dut.hsync && hs_q && hs0 < 0) hs0 = hc;      // negative syncs
        if (dut.hsync && !hs_q && hs1 < 0) hs1 = hc;
        hs_q = dut.hsync;
        hc = hc + 1;
    end
    // per field: lines, DE lines, VSYNC start line, field flag
    integer lines = 0, de_lines = 0, vs_line = -1, f_lines = 0, f_de = 0, f_vs = -1, f_fld = 0, n_fields = 0;
    reg vs_q = 1, fld_now = 0;  real t_fs = 0.0;
    always @(posedge pclk) if (dut.hdmi_rst_n) begin
        if (dut.frame_start) begin
            f_lines = lines;  f_de = de_lines;  f_vs = vs_line;  f_fld = fld_now;
            if (lines != 0) l_period = ($realtime - t_fs) / lines;   // mean line period
            t_fs = $realtime;
            n_fields = n_fields + 1;
            lines = 0;  de_lines = 0;  vs_line = -1;  fld_now = dut.field;
        end
        if (dut.line_start) begin
            lines = lines + 1;
            if (dut.de) de_lines = de_lines + 1;
        end
        if (!dut.vsync && vs_q && vs_line < 0) vs_line = dut.vcount;
        vs_q = dut.vsync;
    end

    // ------------------------------------------------------------ pixel checker
    // at the ring's output (3 pipeline stages after the raster counters)
    reg [15:0] vc1, vc2, vc3;  reg de1, de2, de3;
    always @(posedge pclk) begin vc1 <= dut.vcount; vc2 <= vc1; vc3 <= vc2; de1 <= dut.de; de2 <= de1; de3 <= de2; end
    integer x = 0, k, f_lo = 0, f_hi = -1, wrong_lines = 0, cur_h = 0;  reg checking = 0, in_line = 0, nz = 0;
    integer bad [0:MAXF-1];  integer badnb [0:MAXF-1];  integer good_in_field [0:MAXF-1];
    integer good_max [0:MAXF-1];
    initial for (k = 0; k < MAXF; k = k + 1) begin bad[k] = 0; badnb[k] = 0; good_in_field[k] = 0; good_max[k] = 0; end
    reg any_good, torn_ok;
    always @(posedge pclk) begin
        if (dut.frame_start) begin
            for (k = 0; k < MAXF; k = k + 1) begin
                if (good_in_field[k] > good_max[k]) good_max[k] = good_in_field[k];
                good_in_field[k] = 0;
            end
        end
        if (de3 && checking) begin
            in_line = 1;
            if (dut.pix565 != 16'h0000) nz = 1;
            for (k = f_lo; k <= f_hi; k = k + 1)
                if (dut.pix565 !== want(k, vc3, x / dut.r_rep)) begin
                    bad[k] = bad[k] + 1;  if (dut.pix565 != 16'h0000) badnb[k] = badnb[k] + 1;
                end
            x = x + 1;
        end else if (in_line) begin
            in_line = 0;  x = 0;  any_good = 0;  torn_ok = 0;
            for (k = f_lo; k <= f_hi; k = k + 1) begin
                if (bad[k] == 0) begin good_in_field[k] = good_in_field[k] + 1; any_good = 1; end
                if (badnb[k] == 0) torn_ok = 1;
                bad[k] = 0;  badnb[k] = 0;
            end
            if (!any_good && nz && !torn_ok) begin
                wrong_lines = wrong_lines + 1;
                if (wrong_lines < 6) $display("  WRONG pixels on field line %0d", vc3);
            end
            nz = 0;
        end else x = 0;
    end

    // ------------------------------------------------------------ the scenario
    integer i, s, seg_first_frame, nf_seg, d, n_exp, ht_exp, h_seg, res0, napp0, t;
    integer seg_frames [0:MAXS-1];  integer seg_h [0:MAXS-1];  integer seg_lo [0:MAXS-1];
    reg [6:0] idv0, fbd0;  reg [7:0] odv0;  reg pll_changed;
    real    lt, t_next, t_line_exp, err_rel;
    integer nf_total = 0;
    initial begin
        void'($value$plusargs("DIR=%s", dir));
        void'($value$plusargs("LEAD=%d", lead));
        void'($value$plusargs("SEGS=%d", nsegs));
        if ($test$plusargs("QOI")) qoi = 1'b1;
        void'($value$plusargs("FX=%d", fx_want));
        $readmemh({dir, "/stream_bytes.hex"}, sbytes);
        $readmemh({dir, "/stream_idx.hex"}, sidx);
        while (nframes_eth < 4096 && sidx[nframes_eth] !== 64'hx && sidx[nframes_eth][55:32] != 0)
            nframes_eth = nframes_eth + 1;

        force dut.udp_inst.phy_rdy = 1'b0;
        repeat (20) @(posedge clk50m);  rst_n = 1;
        repeat (20) @(posedge clk50m);  force dut.udp_inst.phy_rdy = 1'b1;
        // boot raster: wait for the controller's first settle
        wait (dut.hdmi_rst_n === 1'b1);
        #200_000;
        send_eth(0);  #50_000;  send_eth(1);  #100_000;         // ARP, CMD_INIT
        i = 2;

        for (s = 0; s < nsegs; s = s + 1) begin
            while (i < nframes_eth && sidx[i][63:56] != 8'd9) i = i + 1;
            if (i >= nframes_eth) begin $display("FAIL: stream has fewer than %0d segments", nsegs); $finish; end
            decode_switchres(i);
            $display("segment %0d: %0.3f MHz %0d %0d %0d %0d / %0d %0d %0d %0d il=%0d",
                     s, m_pclk, m_ha, m_hb, m_he, m_ht, m_va, m_vb, m_ve, m_vt, m_il);
            checking = 0;
            res0 = resets;  napp0 = dut.g_dynpll.u_mlctl.n_applied;
            idv0 = dut.ml_idiv;  fbd0 = dut.ml_fbdiv;  odv0 = dut.ml_odiv;
            send_eth(i);  i = i + 1;
            // applied (and settled)?
            t = 0;
            while (dut.g_dynpll.u_mlctl.n_applied == napp0 && t < 40000) begin #1000; t = t + 1; end
            if (dut.g_dynpll.u_mlctl.n_applied == napp0) begin
                $display("FAIL: modeline %0d never applied (err=%0d st=%0d apply=%0d applied=%0d RD=%0d TO=%0d blitting=%0d sw=%0d sol=%0d dg=%0d last=%0d RJ=%0d head=%0d tx=%0d head_av=%0d)",
                         s, dut.ml_err, dut.g_dynpll.u_mlctl.st, dut.ml_apply_tgl, dut.px_applied_tgl,
                         dut.frame_cnt, dut.to_cnt, dut.blitting, n_sw, n_sol, n_dg, last_cmd, dut.rj_cnt, n_head, n_tx, dut.rx_head_av); $finish; end
            wait (dut.ml_pll_hold == 1'b0 && dut.hdmi_rst_n === 1'b1);
            pll_changed = (dut.ml_idiv != idv0) || (dut.ml_fbdiv != fbd0) || (dut.ml_odiv != odv0);
            repeat (3) @(posedge dut.frame_start);
            @(posedge dut.frame_start);  @(posedge pclk);    // f_* = a whole field now

            // ---- raster against the modeline
            n_exp = 1;  while (n_exp < 6 && m_pclk * n_exp < 25.0) n_exp = n_exp + 1;
            t_line_exp = m_ht / m_pclk * 1000.0;            // ns
            err_rel = (l_period - t_line_exp) / t_line_exp;  if (err_rel < 0) err_rel = -err_rel;
            $display("  N=%0d (want %0d)  pix_clk %0.3f MHz  line %0d clk = %0.1f ns (modeline %0.1f, err %0.3f %%)  DE %0d  HSYNC %0d..%0d",
                     dut.r_rep, n_exp, l_ht / l_period * 1000.0, l_ht, l_period, t_line_exp, err_rel * 100.0,
                     de_len, l_hs0, l_hs1);
            $display("  field: %0d lines (field=%0d), %0d DE lines, VSYNC at line %0d; PLL %0d/%0d/%0d changed=%0d, resets %0d",
                     f_lines, f_fld, f_de, f_vs, dut.ml_idiv, dut.ml_fbdiv, dut.ml_odiv, pll_changed, resets - res0);
            if (dut.r_rep != n_exp) begin errors = errors + 1; $display("FAIL: N"); end
            if (err_rel > 0.001) begin errors = errors + 1; $display("FAIL: line period"); end
            if (de_len != m_ha * n_exp) begin errors = errors + 1; $display("FAIL: active width"); end
            if (l_hs0 != m_hb * n_exp || l_hs1 != m_he * n_exp) begin errors = errors + 1; $display("FAIL: HSYNC position"); end
            if (f_de != (m_il ? m_va / 2 : m_va)) begin errors = errors + 1; $display("FAIL: active lines"); end
            if (f_vs != (m_il ? m_vb / 2 : m_vb)) begin errors = errors + 1; $display("FAIL: VSYNC line"); end
            if (!m_il && (f_lines != m_vt || f_fld != 0)) begin errors = errors + 1; $display("FAIL: field length / flag"); end
            if (m_il && f_lines != (f_fld ? m_vt / 2 : m_vt / 2 + 1)) begin errors = errors + 1; $display("FAIL: interlaced field length"); end
            if (resets - res0 != (pll_changed ? 1 : 0)) begin errors = errors + 1; $display("FAIL: pixel-domain resets"); end
            if (s == 1 && pll_changed) begin errors = errors + 1; $display("FAIL: segment 1 is meant to keep the pclk"); end
            if (m_il) begin                                   // and the next field is the other one
                @(posedge dut.frame_start);  @(posedge pclk);
                if (f_lines != (f_fld ? m_vt / 2 : m_vt / 2 + 1)) begin errors = errors + 1; $display("FAIL: other field length %0d", f_lines); end
                $display("  next field: %0d lines (field=%0d)", f_lines, f_fld);
            end

            // ---- stream the segment's frames
            h_seg = m_il ? m_va / 2 : m_va;
            seg_lo[s] = nf_total;  nf_seg = 0;
            lt = l_period;
            f_lo = nf_total;  f_hi = nf_total - 1;
            while (i < nframes_eth && sidx[i][63:56] == 8'd1) begin
                f_hi = nf_total;  nf_total = nf_total + 1;  nf_seg = nf_seg + 1;
                @(posedge dut.frame_start);
                t_next = $realtime + (dut.r_vtot + ((dut.r_il && !dut.field) ? 1 : 0)) * lt;
                checking = 1;
                wait_until(t_next - (lead + 1) * lt);
                send_eth(i);  i = i + 1;                       // CMD_BLIT_VSYNC header
                d = 0;
                // kind 2 = one line of pixels, at its line time; kind 4 = a foreign
                // datagram (gen --foreign), sent right after the line before it
                while (i < nframes_eth && (sidx[i][63:56] == 8'd2 || sidx[i][63:56] == 8'd4)) begin
                    if (sidx[i][63:56] == 8'd2) begin
                        wait_until(t_next + (d - lead) * lt);
                        d = d + 1;
                    end
                    send_eth(i);  i = i + 1;
                end
            end
            repeat (2) @(posedge dut.frame_start);
            seg_frames[s] = nf_seg;  seg_h[s] = h_seg;
        end
        checking = 0;
        repeat (2) @(posedge dut.frame_start);

        $write("exact lines (best field) per frame:");
        for (s = 0; s < nsegs; s = s + 1)
            for (k = seg_lo[s]; k < seg_lo[s] + seg_frames[s]; k = k + 1) begin
                $write(" f%0d:%0d/%0d", k, good_max[k], seg_h[s]);
                if (good_max[k] != seg_h[s]) errors = errors + 1;
            end
        $write("\n");
        $display("ring stats since the last mode change: lead %0d..%0d, bad %0d (late %0d, early %0d, other %0d)",
                 dut.st_lmin, dut.st_lmax, dut.st_bad, dut.st_late, dut.st_early, dut.st_other);
        $display("wrong lines: %0d; blit timeouts TO=%0d, frames received RD=%0d of %0d",
                 wrong_lines, dut.to_cnt, dut.frame_cnt, nf_total);
        if (wrong_lines != 0 || dut.to_cnt != 0 || dut.frame_cnt != nf_total) errors = errors + 1;
        $display("QOI session %0d: corrupted lines QE=%0d, dropped bytes QO=%0d",
                 dut.cfg_qoi, dut.qe_cnt, dut.qo_cnt);
        if (dut.cfg_qoi != qoi || dut.qe_cnt != 0 || dut.qo_cnt != 0) errors = errors + 1;
        // +FX=n: the stream has n broadcasts to another port (gen --foreign), all dropped
        $display("foreign datagrams dropped FX=%0d (expected %0d)", dut.fx_cnt, fx_want);
        if (dut.fx_cnt != fx_want) errors = errors + 1;
        if (errors == 0) $display("PASS: gwline_modeline_tb");
        else             $display("FAIL: gwline_modeline_tb (%0d errors)", errors);
        $finish;
    end
endmodule

`default_nettype wire
