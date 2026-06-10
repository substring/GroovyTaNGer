// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking testbench for rtl/board/.../bringup/led_blink.v
// Uses a tiny HALF_PERIOD and checks the LED toggles exactly on schedule.
`timescale 1ns/1ps
module led_blink_tb;
    localparam integer HP = 5;     // toggle every 5 clocks

    reg  clk = 0;
    always #5 clk = ~clk;
    wire led;
    integer errors = 0;
    integer i, edges, last_edge_i;
    reg prev;

    led_blink #(.HALF_PERIOD(HP)) dut (.Clock(clk), .IO_voltage(led));

    initial begin
        // sample on negedge; count cycles between LED transitions
        prev = led; edges = 0; last_edge_i = 0;
        for (i = 1; i <= HP*6 + 2; i = i + 1) begin
            @(negedge clk);
            if (led !== prev) begin
                if (edges > 0 && (i - last_edge_i) !== HP) begin
                    $display("FAIL: toggle gap = %0d cycles, expected %0d",
                             i - last_edge_i, HP);
                    errors = errors + 1;
                end
                edges       = edges + 1;
                last_edge_i = i;
                prev        = led;
            end
        end

        if (edges < 3) begin
            $display("FAIL: only %0d LED toggles seen", edges); errors = errors + 1; end

        if (errors == 0) $display("PASS: led_blink_tb (%0d toggles)", edges);
        else begin $display("FAIL: led_blink_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
