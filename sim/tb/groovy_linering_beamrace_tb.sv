// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - beam-race line-ring testbench: REAL operating conditions, pixel-exact.
//
// What "real" means here (each one was missing from at least one earlier ring tb):
//   - the sender streams CONTINUOUSLY at exactly 1.0x the raster rate (240 source lines
//     per 16.67 ms video frame), 2 lines per datagram, each datagram arriving as a burst
//     at blit_rx speed (1 pixel / 2 clk50m cycles). A line ring cannot show a picture at
//     any other average rate, and cannot show a still frame at all.
//   - the picture differs on EVERY line and EVERY frame (hash of frame/line/col), so a
//     line shown from the wrong slot, the wrong lap or the wrong frame is caught. Column-
//     only patterns (vertical bars) hide all of those.
//   - the checker compares each output pixel against the hcount/vcount that produced it
//     (delayed by the scan pipeline's 3 stages), so there is no "seam" to excuse.
//   - the real 720p video_timing_gen and the real ring/scan RTL are used.
//
// Result = per video frame, how many of the 720 output lines are pixel-perfect, and from
// which network frame. A healthy ring gives 720/720 from one frame.
//
// Plusargs:  +LEAD=<source lines the writer leads the raster at line 0>  (default 20)
//            +JIT=<max extra delay per datagram, microseconds, uniform>  (default 0)
//            +NF=<network frames to send>                                (default 6)
//            +RPACE=1  pace datagrams at the raster's ACTIVE line rate, then idle through
//                      vertical blanking (default 0: spread evenly over the whole frame)
`timescale 1ns/1ps
`default_nettype none

module groovy_linering_beamrace_tb;
    localparam integer SRC_W = 320, SRC_H = 240, OUT_W = 1280, OUT_H = 720;
    localparam integer MAXF = 16;
    localparam real    PIX_T   = 13.468;                       // ns, 74.25 MHz
    localparam real    FRAME_T = 1650.0 * 750.0 * PIX_T;       // ns, one video frame
    localparam real    DGRAM_T = FRAME_T / 120.0;              // ns, 2 source lines
    localparam real    LINE_T  = FRAME_T / 240.0;              // ns, sender line period

    reg clk50m = 0;  always #10 clk50m = ~clk50m;
    reg pix_clk = 0; always #(PIX_T/2.0) pix_clk = ~pix_clk;

    reg rst50 = 1, hdmi_rst_n = 0;
    reg frame_start = 0, px_we = 0;  reg [15:0] px_data = 0;

    wire [15:0] hcount, vcount, pix565, write_line;
    wire        de, de_o, vframe_start;

    function automatic [15:0] pix(input integer f, input integer l, input integer c);
        pix = (l * 16'h9E37) ^ (c * 16'h7F4B) ^ (f * 16'h1D2F) ^ 16'h5A5A;
    endfunction

    wire hsync, vsync, line_start, hs_o, vs_o;
    wire [31:0] ovf_count = 0;
    video_timing_gen u_timing (
        .clk(pix_clk), .rst(~hdmi_rst_n), .en(1'b1),
        .h_total(16'd1650), .h_active(16'd1280), .h_sync_begin(16'd1390), .h_sync_end(16'd1430),
        .v_total(16'd750),  .v_active(16'd720),  .v_sync_begin(16'd725),  .v_sync_end(16'd730),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),
        .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de),
        .line_start(line_start), .frame_start(vframe_start));
    wire [9:0]  good_lines;  wire [15:0] lead_top, src_line_wr;
    groovy_linering #(.NLINES(32), .LINE_W(512), .DATA_W(16), .H_SH(2), .V_REPL(3)) dut (
        .wr_clk(clk50m), .wr_rst(rst50), .frame_start(frame_start),
        .px_we(px_we), .px_data(px_data), .native_w(16'd320),
        .write_line(write_line), .src_line_wr(src_line_wr), .lead_top(lead_top),
        .pix_clk(pix_clk), .pix_rst(~hdmi_rst_n),
        .hcount(hcount), .vcount(vcount), .de(de), .hsync(hsync), .vsync(vsync),
        .vframe_start(vframe_start),
        .pix(pix565), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o), .good_lines(good_lines));

    // ------------------------------------------------------------------ sender model
    integer lead = 20, jit_us = 0, nf = 6, seed = 1, rpace = 0;
    real    dgram_t;
    integer f, d, p, l, c;
    real    t0, t_target;
    reg     sender_done = 0;

    task automatic wait_until(input real t);
        begin
            if ($realtime < t) #(t - $realtime);
            @(posedge clk50m);
        end
    endtask

    initial begin
        void'($value$plusargs("LEAD=%d", lead));
        void'($value$plusargs("JIT=%d", jit_us));
        void'($value$plusargs("NF=%d", nf));
        void'($value$plusargs("SEED=%d", seed));
        void'($value$plusargs("RPACE=%d", rpace));
        dgram_t = rpace ? DGRAM_T * 720.0 / 750.0 : DGRAM_T;
        if (nf > MAXF) nf = MAXF;
        repeat (20) @(posedge clk50m);  rst50 = 0;
        repeat (20) @(posedge pix_clk); hdmi_rst_n = 1;
        repeat (100) @(posedge clk50m);        // ring writer's slot-tag clear sweep

        // free-running raster: phase-lock like gm_test_sender (lead lines ahead)
        @(posedge vframe_start);
        t0 = $realtime + FRAME_T - lead * (2.0 * FRAME_T / 240.0 / 2.0);
        if (t0 < $realtime + 50_000.0) t0 = t0 + FRAME_T;

        for (f = 0; f < nf; f = f + 1) begin
            wait_until(t0 + f * FRAME_T - 30_000.0);          // BLIT header just before
            frame_start = 1; @(posedge clk50m); frame_start = 0;
            for (d = 0; d < 120; d = d + 1) begin
                t_target = t0 + f * FRAME_T + d * dgram_t;
                if (jit_us > 0) t_target = t_target + $urandom_range(0, jit_us * 1000);
                wait_until(t_target);
                for (p = 0; p < 640; p = p + 1) begin
                    l = 2 * d + p / 320;  c = p % 320;
                    px_we = 1; px_data = pix(f, l, c); @(posedge clk50m);
                    px_we = 0;                         @(posedge clk50m);
                end
            end
        end
        sender_done = 1;
    end

    // ------------------------------------------------------------------ checker
    // hcount/vcount/de as they were 3 pix_clk edges ago = what the current output pixel
    // was addressed with (scan pipeline: address reg, BRAM output reg, pixel reg).
    reg [15:0] hc1, hc2, hc3, vc1, vc2, vc3;  reg de1, de2, de3;
    always @(posedge pix_clk) begin
        hc1 <= hcount; hc2 <= hc1; hc3 <= hc2;
        vc1 <= vcount; vc2 <= vc1; vc3 <= vc2;
        de1 <= de;     de2 <= de1; de3 <= de2;
    end

    integer vframe = -1;
    integer bad [0:MAXF-1];           // per candidate network frame: mismatches this line
    integer good_from [0:MAXF-1];     // per video frame: lines matching network frame i
    integer good_total, k, total_good_all = 0, total_lines_all = 0;
    integer de_mismatch = 0;
    reg     in_line = 0;
    initial for (k = 0; k < MAXF; k = k + 1) begin bad[k] = 0; good_from[k] = 0; end

    task automatic report_frame;
        integer i; reg [8*64-1:0] s;
        begin
            good_total = 0;
            for (i = 0; i < MAXF; i = i + 1) good_total = good_total + good_from[i];
            $write("video frame %0d: %0d/720 lines pixel-exact  [", vframe, good_total);
            for (i = 0; i < MAXF; i = i + 1)
                if (good_from[i] != 0) $write(" net%0d:%0d", i, good_from[i]);
            $write(" ]  write_line=%0d ovf=%0d\n", write_line, ovf_count);
            if (!sender_done && vframe >= 2) begin       // steady state only
                total_good_all  = total_good_all + good_total;
                total_lines_all = total_lines_all + 720;
            end
            for (i = 0; i < MAXF; i = i + 1) good_from[i] = 0;
        end
    endtask

    always @(posedge pix_clk) begin
        if (vframe_start) begin
            if (vframe >= 0) report_frame;
            vframe = vframe + 1;
        end
        if (de_o !== de3 && hdmi_rst_n) de_mismatch = de_mismatch + 1;
        if (de3) begin
            in_line <= 1;
            for (k = 0; k < nf; k = k + 1)
                if (pix565 !== pix(k, vc3 / 3, hc3 >> 2)) bad[k] = bad[k] + 1;
        end else if (in_line) begin                      // end of an output line
            in_line <= 0;
            for (k = 0; k < nf; k = k + 1) begin
                if (bad[k] == 0) good_from[k] = good_from[k] + 1;
                bad[k] = 0;
            end
        end
    end

    initial begin
        wait (sender_done);
        #(FRAME_T * 1.5);
        $display("SUMMARY LINERING lead=%0d jit_us=%0d : steady-state %0d/%0d lines pixel-exact (%.1f%%), de_mismatch=%0d, ovf=%0d",
                 lead, jit_us, total_good_all, total_lines_all,
                 total_lines_all ? 100.0 * total_good_all / total_lines_all : 0.0, de_mismatch, ovf_count);
        $finish;
    end
endmodule

`default_nettype wire
