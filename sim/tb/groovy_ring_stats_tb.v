// SPDX-License-Identifier: GPL-2.0-or-later
// groovy_ring_stats: signed lead, window min/max, cause of each bad frame.
`timescale 1ns/1ps
`default_nettype none
module groovy_ring_stats_tb;
    reg clk = 0, rst = 1, fs = 0, wc = 0;
    reg [15:0] line = 16'd100;
    reg [9:0] gl = 10'd224;
    wire signed [15:0] lmin, lmax;
    wire [15:0] bad, late, early, other;
    integer errors = 0;
    always #10 clk = ~clk;

    groovy_ring_stats #(.NLINES(32), .SETTLE(4)) dut (
        .clk(clk), .rst(rst), .frame_start(fs), .raster_line(line), .good_lines(gl),
        .want_lines(10'd224), .window_clear(wc), .lead_min(lmin), .lead_max(lmax),
        .bad_frames(bad), .late_frames(late), .early_frames(early), .other_frames(other));

    // one raster frame of 262 lines, 2 clocks per line; host frame at line `at` (-1: none);
    // g_ended = good_lines of the video frame that ended at this frame's top
    task frame(input integer at, input [9:0] g_ended);
        integer l;
        begin
            for (l = 0; l < 262; l = l + 1) begin
                @(negedge clk); line = l;
                if (l == 0) gl = g_ended;
                fs = (l == at);
                @(negedge clk); fs = 0;
            end
        end
    endtask
    task check(input [255:0] what, input integer got, input integer want);
        if (got !== want) begin
            $display("FAIL %0s: got %0d want %0d", what, got, want); errors = errors + 1;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk); rst = 0;
        frame(-1, 10'd0); frame(-1, 10'd0);            // no stream: nothing counted
        check("idle bad", bad, 0);

        frame(238, 10'd0);                             // first frame, lead 24
        check("lead max", lmax, 24); check("lead min", lmin, 24);
        frame(238, 10'd0); frame(238, 10'd224);        // the first frames (bad, then good)
        repeat (2) @(negedge clk);
        begin : baseline
            integer b0, l0, e0, o0;
            b0 = bad; l0 = late; e0 = early; o0 = other;

            frame(238, 10'd224);                       // healthy
            frame(225, 10'd224);                       // lead 37 for the next frame,
            frame(238, 10'd224);                       // scanned here,
            frame(238, 10'd0);                         // and judged at this top -> early
            check("early", early - e0, 1); check("bad+1", bad - b0, 1);

            wc = 1; @(negedge clk); wc = 0;
            frame(5, 10'd224);                         // this frame starts 5 lines late
            check("late lead min", lmin, -5);
            frame(238, 10'd0);                         // it is shown bad -> late
            check("late", late - l0, 1); check("bad+2", bad - b0, 2);

            frame(238, 10'd224);                       // good lead,
            frame(238, 10'd100);                       // yet the frame shown is bad -> other
            check("other", other - o0, 1); check("bad+3", bad - b0, 3);

            frame(-1, 10'd224);                        // host skips a frame:
            frame(238, 10'd224);                       // nothing to scan here,
            frame(238, 10'd0);                         // judged at this top -> late
            check("skipped", late - l0, 2); check("bad+4", bad - b0, 4);
        end
        begin : wrap_glitch                            // garbage sample before the wrap
            integer l;
            for (l = 0; l < 262; l = l + 1) begin
                @(negedge clk); line = l; @(negedge clk);
            end
            @(negedge clk); line = 16'd999; @(negedge clk);
            wc = 1; @(negedge clk); wc = 0;
            frame(238, 10'd224);                       // lead must still be 24
            check("glitch min", lmin, 24); check("glitch max", lmax, 24);
        end
        if (errors == 0) $display("PASS groovy_ring_stats_tb");
        else $display("FAIL groovy_ring_stats_tb (%0d errors)", errors);
        $finish;
    end
endmodule
`default_nettype wire
