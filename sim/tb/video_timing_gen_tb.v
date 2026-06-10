// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking testbench for rtl/generic/video/video_timing_gen.v
// Small synthetic modeline; checks counters wrap, de/hsync/vsync windows,
// and that a full frame is exactly h_total*v_total pixels.
`timescale 1ns/1ps
module video_timing_gen_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    reg        rst, en;
    // synthetic modeline (16-bit to match the DUT port widths)
    localparam [15:0] HT=10, HA=4, HSB=6, HSE=8;
    localparam [15:0] VT=6,  VA=3, VSB=4, VSE=5;

    wire [15:0] hcount, vcount;
    wire        hsync, vsync, de, line_start, frame_start;
    integer     errors = 0;
    integer     i, frame_pixels, frames_seen;

    video_timing_gen dut (
        .clk(clk), .rst(rst), .en(en),
        .h_total(HT), .h_active(HA), .h_sync_begin(HSB), .h_sync_end(HSE),
        .v_total(VT), .v_active(VA), .v_sync_begin(VSB), .v_sync_end(VSE),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),
        .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de),
        .line_start(line_start), .frame_start(frame_start));

`ifdef DUMP
    initial begin $dumpfile("sim/build/wave.vcd"); $dumpvars(0, video_timing_gen_tb); end
`endif

    initial begin
        rst = 1; en = 0;
        @(negedge clk); @(negedge clk);
        rst = 0; en = 1;

        frame_pixels = 0; frames_seen = 0;

        for (i = 0; i < HT*VT*2 + 3; i = i + 1) begin
            @(negedge clk);

            // bounds
            if (hcount >= HT) begin
                $display("FAIL: hcount %0d >= h_total", hcount); errors = errors + 1; end
            if (vcount >= VT) begin
                $display("FAIL: vcount %0d >= v_total", vcount); errors = errors + 1; end

            // de window
            if (de !== ((hcount < HA) && (vcount < VA))) begin
                $display("FAIL: de wrong at (%0d,%0d) de=%b", hcount, vcount, de);
                errors = errors + 1; end

            // sync windows (active-high configured)
            if (hsync !== ((hcount >= HSB) && (hcount < HSE))) begin
                $display("FAIL: hsync wrong at h=%0d hsync=%b", hcount, hsync);
                errors = errors + 1; end
            if (vsync !== ((vcount >= VSB) && (vcount < VSE))) begin
                $display("FAIL: vsync wrong at v=%0d vsync=%b", vcount, vsync);
                errors = errors + 1; end

            // frame_start must coincide with (0,0)
            if (frame_start !== ((hcount==0) && (vcount==0))) begin
                $display("FAIL: frame_start wrong at (%0d,%0d)", hcount, vcount);
                errors = errors + 1; end

            // count pixels between frame_start pulses
            if (frame_start) begin
                if (frames_seen > 0 && frame_pixels !== HT*VT) begin
                    $display("FAIL: frame had %0d pixels, expected %0d",
                             frame_pixels, HT*VT);
                    errors = errors + 1;
                end
                frame_pixels = 0;
                frames_seen  = frames_seen + 1;
            end
            frame_pixels = frame_pixels + 1;
        end

        if (frames_seen < 2) begin
            $display("FAIL: saw only %0d frame_start pulses", frames_seen);
            errors = errors + 1; end

        if (errors == 0) $display("PASS: video_timing_gen_tb");
        else begin $display("FAIL: video_timing_gen_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
