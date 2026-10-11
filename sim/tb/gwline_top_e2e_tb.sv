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

    integer i, f, d;  real t0;  reg sender_done = 0;
    initial begin
        void'($value$plusargs("DIR=%s", dir));
        void'($value$plusargs("LEAD=%d", lead));
        void'($value$plusargs("GAP=%d", gap_hdr));
        $readmemh({dir, "/stream_bytes.hex"}, sbytes);
        $readmemh({dir, "/stream_idx.hex"}, sidx);
        while (nframes_eth < 1024 && sidx[nframes_eth] !== 64'hx && sidx[nframes_eth][55:32] != 0)
            nframes_eth = nframes_eth + 1;
        nf_net = (nframes_eth - 1) / 121;
        $display("stream: %0d ethernet frames = %0d network frames, lead=%0d", nframes_eth, nf_net, lead);

        // udp.sv waits on real MDIO negotiation for phy_rdy: give it a clean 0->1 edge.
        force dut.udp_inst.phy_rdy = 1'b0;
        repeat (20) @(posedge clk50m);  rst_n = 1;
        repeat (20) @(posedge clk50m);  force dut.udp_inst.phy_rdy = 1'b1;
        #5000;

        send_eth(0);                                    // CMD_INIT (rgb565)
        #200_000;
        @(posedge dut.frame_start);                     // lock to the raster
        t0 = $realtime + FRAME_T - lead * LINE_T;
        if (t0 < $realtime + 300_000.0) t0 = t0 + FRAME_T;

        i = 1;
        for (f = 0; f < nf_net; f = f + 1) begin
            // BLIT header timed to END gap_hdr cycles before the first pixel datagram:
            // a runt immediately followed by a full-size frame (72 bytes * 80 ns).
            wait_until(t0 + f * FRAME_T - 72 * 80.0 - gap_hdr * 20.0);
            send_eth(i);  i = i + 1;
            for (d = 0; d < 120; d = d + 1) begin
                wait_until(t0 + f * FRAME_T + d * DGRAM_T);
                send_eth(i);  i = i + 1;
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

    initial begin
        wait (sender_done);
        #(FRAME_T * 1.2);
        $display("SUMMARY lead=%0d gap_hdr=%0d : %0d/%0d network frames shown pixel-perfect; RD=%0d TO=%0d RJ=%0d",
                 lead, gap_hdr, perfect_frames, nf_net, dut.frame_cnt, dut.to_cnt, dut.rj_cnt);
        if (perfect_frames == nf_net && dut.frame_cnt == nf_net && dut.to_cnt == 0)
             $display("PASS: gwline_top_e2e_tb");
        else $display("FAIL: gwline_top_e2e_tb");
        $finish;
    end
endmodule

`default_nettype wire
