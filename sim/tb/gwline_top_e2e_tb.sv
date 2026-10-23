// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - END-TO-END test of the real gwline_top.sv: Ethernet frames clocked into
// the real udp.sv over RMII -> parser -> blit_rx -> groovy_linering -> raster pixels,
// checked pixel-exact at the point they would enter the DVI encoder.
//
// Nothing of the design is re-wired here: the DUT is gwline_top itself, with only the
// Gowin PLL/CLKDIV/DVI primitives replaced by clock stubs (gwline_sim_stubs.sv). An
// earlier e2e bench copied the top's glue by hand and drifted from it.
//
// The host model does what tools/gm_test_sender.py blitrace does: lock to the raster,
// then stream network frames continuously at 1.0x, starting each one LEAD source lines
// before the raster's line 0. Frame bytes come from tools/gen_gwline_stream.py (every
// pixel = hash(frame,line,col), recomputed here).
//
// Plusargs: +DIR=<dir with stream_*.hex>  +LEAD=<lines, default 24>  +GAP=<clk50m cycles
//           forced between the BLIT header and the first pixel datagram, default 48>
`timescale 1ns/1ps
`include "rmii.svh"
`default_nettype none

module gwline_top_e2e_tb;
    localparam real PIX_T   = 13.468;
    localparam real FRAME_T = 1650.0 * 750.0 * PIX_T;
    localparam real DGRAM_T = FRAME_T / 120.0;
    localparam real LINE_T  = FRAME_T / 240.0;
    localparam integer MAXF = 8;

    reg clk27 = 0;  always #18.5185 clk27 = ~clk27;
    reg clk50m = 0; always #10 clk50m = ~clk50m;
    reg rst_n = 0;

    reg  [1:0] rxd_drv = 0;  reg crs_drv = 0;  wire mdio_w;
    rmii netrmii(.clk50m(clk50m), .rx_crs(crs_drv), .mdc(), .txen(), .mdio(mdio_w),
                 .txd(), .rxd(rxd_drv));
    wire [5:0] led;  wire uart_txp;
    gwline_top dut (.clk(clk27), .rst(rst_n), .netrmii(netrmii), .phyrst(),
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
    integer lead = 24, gap_hdr = 48;

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

    integer i, f, d, hdr, n_status_sent = 0;  real t0;  reg sender_done = 0;  real beacon_on_at = -1.0;
    initial begin
        void'($value$plusargs("DIR=%s", dir));
        void'($value$plusargs("LEAD=%d", lead));
        void'($value$plusargs("GAP=%d", gap_hdr));
        $readmemh({dir, "/stream_bytes.hex"}, sbytes);
        $readmemh({dir, "/stream_idx.hex"}, sidx);
        while (nframes_eth < 1024 && sidx[nframes_eth] !== 64'hx && sidx[nframes_eth][55:32] != 0)
            nframes_eth = nframes_eth + 1;
        hdr = 0;                                         // ARP, INIT [, CMD_SET_BEACON]
        while (hdr < nframes_eth && sidx[hdr][63:56] != 8'd1) hdr = hdr + 1;
        nf_net = 0;
        for (i = 0; i < nframes_eth; i = i + 1) if (sidx[i][63:56] == 8'd1) nf_net = nf_net + 1;
        $display("stream: %0d ethernet frames = %0d network frames, lead=%0d", nframes_eth, nf_net, lead);

        // udp.sv waits on real MDIO negotiation for phy_rdy: give it a clean 0->1 edge.
        force dut.udp_inst.phy_rdy = 1'b0;
        repeat (20) @(posedge clk50m);  rst_n = 1;
        repeat (20) @(posedge clk50m);  force dut.udp_inst.phy_rdy = 1'b1;
        #5000;

        for (i = 0; i < hdr; i = i + 1) begin            // ARP, CMD_INIT (rgb565), beacon on
            send_eth(i);
            if (sidx[i][63:56] == 8'd3) beacon_on_at = $realtime;
            #100_000;
        end
        #100_000;
        @(posedge dut.frame_start);                     // lock to the raster
        t0 = $realtime + FRAME_T - lead * LINE_T;
        if (t0 < $realtime + 300_000.0) t0 = t0 + FRAME_T;

        i = hdr;
        for (f = 0; f < nf_net; f = f + 1) begin
            // BLIT header timed to END gap_hdr cycles before the first pixel datagram:
            // a runt immediately followed by a full-size frame (72 bytes * 80 ns).
            wait_until(t0 + f * FRAME_T - 72 * 80.0 - gap_hdr * 20.0);
            send_eth(i);  i = i + 1;
            for (d = 0; d < 120; d = d + 1) begin
                wait_until(t0 + f * FRAME_T + d * DGRAM_T);
                send_eth(i);  i = i + 1;
            end
            // optional CMD_GET_STATUS burst between frames: replies close together
            while (i < nframes_eth && sidx[i][63:56] == 8'd4) begin
                #2000;  send_eth(i);  i = i + 1;  n_status_sent = n_status_sent + 1;
            end
        end
        sender_done = 1;
    end

    // ------------------------------------------------------------ checker (pix_clk)
    wire pclk = dut.pix_clk;
    reg [15:0] hc1, hc2, hc3, vc1, vc2, vc3;  reg de1, de2, de3;
    always @(posedge pclk) begin
        hc1 <= dut.hcount; hc2 <= hc1; hc3 <= hc2;
        vc1 <= dut.vcount; vc2 <= vc1; vc3 <= vc2;
        de1 <= dut.de;     de2 <= de1; de3 <= de2;
    end
    integer vframe = -1, k, good_total, perfect_frames = 0;
    integer bad [0:MAXF-1];  integer good_from [0:MAXF-1];  reg in_line = 0;
    initial for (k = 0; k < MAXF; k = k + 1) begin bad[k] = 0; good_from[k] = 0; end

    always @(posedge pclk) begin
        if (dut.frame_start) begin
            if (vframe >= 0) begin
                good_total = 0;
                for (k = 0; k < MAXF; k = k + 1) good_total = good_total + good_from[k];
                $write("video frame %0d: %0d/720 lines pixel-exact [", vframe, good_total);
                for (k = 0; k < MAXF; k = k + 1) if (good_from[k] != 0) $write(" net%0d:%0d", k, good_from[k]);
                $write(" ]  DUT: GL=%0d LT=%0d RD=%0d TO=%0d RJ=%0d\n", dut.good_lines,
                       dut.lead_top, dut.frame_cnt, dut.to_cnt, dut.rj_cnt);
                if (good_total == 720) perfect_frames = perfect_frames + 1;
                for (k = 0; k < MAXF; k = k + 1) good_from[k] = 0;
            end
            vframe = vframe + 1;
        end
        if (de3) begin
            in_line <= 1;
            for (k = 0; k < nf_net; k = k + 1)
                if (dut.pix565 !== pix(k, vc3 / 3, hc3 >> 2)) bad[k] = bad[k] + 1;
        end else if (in_line) begin
            in_line <= 0;
            for (k = 0; k < nf_net; k = k + 1) begin
                if (bad[k] == 0) good_from[k] = good_from[k] + 1;
                bad[k] = 0;
            end
        end
    end

    // ------------------------------------------------------------ what udp.sv puts on the wire
    // RMII TX decoded back into Ethernet frames (dibits LSB first), and every frame
    // checked: FCS, IPv4 header checksum, UDP length + checksum. Catches a corrupted or
    // misaligned TX FIFO, which the byte stream into udp.sv cannot show.
    reg [7:0] fr [0:1599];  integer fn = 0, dib = 0;  reg [7:0] sh;  reg txen_q = 0, in_frame = 0;
    integer tx_frames = 0, tx_bad = 0, tx_udp = 0, tx_arp = 0, tx_acks = 0, tx_beacons = 0;
    real t_fire = -1.0, bc_delay_max = 0.0;              // beacon trigger -> end of its frame
    always @(posedge clk50m) if (dut.beacon_fire) t_fire = $realtime;
    function automatic [31:0] crc32_upd(input [31:0] c, input [7:0] b);
        integer q; reg [31:0] r; begin r = c ^ b;
        for (q = 0; q < 8; q = q + 1) r = r[0] ? (r >> 1) ^ 32'hEDB88320 : (r >> 1);
        crc32_upd = r; end
    endfunction
    function automatic [15:0] csum_fold(input [31:0] x);
        reg [31:0] y; begin y = x; while (y[31:16] != 0) y = y[15:0] + y[31:16]; csum_fold = y[15:0]; end
    endfunction
    task automatic check_tx_frame;
        integer s0, q, iphl, iplen, ulen; reg [31:0] c, sum; reg bad; begin
        bad = 0;  s0 = 0;                                   // fr[] starts after the SFD
        tx_frames = tx_frames + 1;
        if (fn < 64) begin
            bad = 1; $write("TX: runt (%0d bytes after SFD):", fn);
            for (q = 0; q < 16 && q < fn; q = q + 1) $write(" %h", fr[q]);  $write("\n");
        end
        else begin
            c = 32'hFFFFFFFF;
            for (q = s0; q < fn - 4; q = q + 1) c = crc32_upd(c, fr[q]);
            c = ~c;
            if (c != {fr[fn-1], fr[fn-2], fr[fn-3], fr[fn-4]}) begin bad = 1; $display("TX: bad FCS at %0t", $time); end
            if ({fr[s0+12], fr[s0+13]} == 16'h0806) tx_arp = tx_arp + 1;
            else if ({fr[s0+12], fr[s0+13]} == 16'h0800) begin
                iphl = (fr[s0+14] & 15) * 4;  iplen = {fr[s0+16], fr[s0+17]};
                sum = 0;  for (q = 0; q < iphl; q = q + 2) sum = sum + {fr[s0+14+q], fr[s0+15+q]};
                if (csum_fold(sum) != 16'hFFFF) begin bad = 1; $display("TX: bad IP checksum at %0t", $time); end
                if (fr[s0+23] == 8'h11) begin
                    ulen = {fr[s0+14+iphl+4], fr[s0+14+iphl+5]};
                    if (ulen != iplen - iphl) begin bad = 1; $display("TX: UDP len %0d vs IP %0d at %0t", ulen, iplen - iphl, $time); end
                    else begin
                        sum = 32'h11 + ulen;
                        for (q = 0; q < 8; q = q + 2) sum = sum + {fr[s0+26+q], fr[s0+27+q]};   // src+dst ip
                        for (q = 0; q < ulen; q = q + 2)
                            sum = sum + {fr[s0+14+iphl+q], (q + 1 < ulen) ? fr[s0+15+iphl+q] : 8'h00};
                        if (csum_fold(sum) != 16'hFFFF) begin bad = 1; $display("TX: bad UDP checksum (len %0d) at %0t", ulen, $time); end
                        else begin
                            tx_udp = tx_udp + 1;
                            if (ulen - 8 == 13) tx_acks = tx_acks + 1;
                            if (ulen - 8 == 16) begin
                                tx_beacons = tx_beacons + 1;
                                if (t_fire >= 0 && $realtime - t_fire > bc_delay_max) bc_delay_max = $realtime - t_fire;
                            end
                        end
                    end
                end
            end else begin bad = 1; $display("TX: ethertype %h at %0t", {fr[s0+12], fr[s0+13]}, $time); end
        end
        if (bad) tx_bad = tx_bad + 1;
        end
    endtask
    always @(posedge clk50m) begin
        txen_q <= netrmii.txen;
        if (netrmii.txen) begin
            if (!in_frame) begin                            // preamble 01 01 ..., SFD ends 11
                if (netrmii.txd == 2'b11) begin in_frame = 1; dib = 0; fn = 0; end
            end else begin
                sh = {netrmii.txd, sh[7:2]};  dib = dib + 1;
                if (dib == 4) begin dib = 0; if (fn < 1600) fr[fn] = sh; fn = fn + 1; end
            end
        end else if (txen_q) begin
            check_tx_frame;  fn = 0;  dib = 0;  in_frame = 0;
        end
    end

    // ------------------------------------------------------------ raster beacons (clk50m)
    // Every datagram the top hands to udp.sv, rebuilt from the arbiter's byte stream.
    // A beacon (16 bytes, "GTB1") must come once per video frame, built when the raster
    // enters vertical blanking (source line 240), seq +1 each, video_frame +1 each.
    reg [7:0] txb [0:63];  integer txn = 0, n_beacon = 0, bc_err = 0, last_seq = -1;
    integer last_vf = -1, bc_gl_min = 9999, bc_gl_max = -1, bc_lt_min = 9999, bc_lt_max = -1;
    integer bc_vf, bc_rl, bc_gl, bc_lt, bc_sq;
    always @(posedge clk50m) begin
        if (dut.tx_data_av) begin if (txn < 64) txb[txn] = dut.tx_data; txn = txn + 1; end
        if (dut.tx_req) begin
            if (txn == 16 && txb[0] == "G" && txb[1] == "T" && txb[2] == "B" && txb[3] == "1") begin
                bc_vf = {txb[7], txb[6], txb[5], txb[4]};  bc_rl = {txb[9], txb[8]};
                bc_gl = {txb[11], txb[10]};  bc_lt = {txb[13], txb[12]};  bc_sq = txb[15];
                n_beacon = n_beacon + 1;
                if (bc_rl != 240) begin bc_err = bc_err + 1; $display("BEACON: raster_line %0d != 240", bc_rl); end
                if (last_seq >= 0 && bc_sq != ((last_seq + 1) & 255)) begin bc_err = bc_err + 1; $display("BEACON: seq %0d after %0d", bc_sq, last_seq); end
                if (last_vf >= 0 && bc_vf != last_vf + 1) begin bc_err = bc_err + 1; $display("BEACON: video_frame %0d after %0d", bc_vf, last_vf); end
                last_seq = bc_sq;  last_vf = bc_vf;
                if (sender_done == 0 && n_beacon > 3) begin       // stream running: picture health
                    if (bc_gl < bc_gl_min) bc_gl_min = bc_gl;  if (bc_gl > bc_gl_max) bc_gl_max = bc_gl;
                    if (bc_lt < bc_lt_min) bc_lt_min = bc_lt;  if (bc_lt > bc_lt_max) bc_lt_max = bc_lt;
                end
            end
            txn = 0;
        end
    end

    initial begin
        wait (sender_done);
        #(FRAME_T * 1.2);
        $display("SUMMARY lead=%0d gap_hdr=%0d : %0d/%0d network frames shown pixel-perfect; RD=%0d TO=%0d RJ=%0d",
                 lead, gap_hdr, perfect_frames, nf_net, dut.frame_cnt, dut.to_cnt, dut.rj_cnt);
        if (beacon_on_at >= 0)
            $display("BEACON %0d beacons over %0d video frames since enabled, %0d errors; while streaming GL %0d..%0d LT %0d..%0d",
                     n_beacon, $rtoi(($realtime - beacon_on_at) / FRAME_T), bc_err,
                     bc_gl_min, bc_gl_max, bc_lt_min, bc_lt_max);
        $display("TX %0d frames on the wire: %0d BAD, %0d UDP (%0d ACK-sized, %0d beacons), %0d ARP; %0d status requests sent; beacon trigger->wire max %0.1f us",
                 tx_frames, tx_bad, tx_udp, tx_acks, tx_beacons, tx_arp, n_status_sent, bc_delay_max / 1000.0);
        if (perfect_frames == nf_net && dut.frame_cnt == nf_net && dut.to_cnt == 0 && tx_bad == 0 &&
            (beacon_on_at < 0 || (n_beacon >= $rtoi(($realtime - beacon_on_at) / FRAME_T) - 1 && bc_err == 0)))
             $display("PASS: gwline_top_e2e_tb");
        else $display("FAIL: gwline_top_e2e_tb");
        $finish;
    end
endmodule

`default_nettype wire
