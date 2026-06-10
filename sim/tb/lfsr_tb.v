// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking testbench for rtl/generic/lfsr.v
`timescale 1ns/1ps
module lfsr_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    reg        rst, en;
    reg  [7:0] seed;
    wire [7:0] q;
    integer    errors = 0;
    integer    i;
    reg  [7:0] prev;

    lfsr #(.WIDTH(8), .TAPS(8'hB8)) dut (
        .clk(clk), .rst(rst), .en(en), .seed(seed), .q(q));

`ifdef DUMP
    initial begin $dumpfile("sim/build/wave.vcd"); $dumpvars(0, lfsr_tb); end
`endif

    initial begin
        rst = 1; en = 0; seed = 8'h5A;
        @(negedge clk); @(negedge clk);
        rst = 0; en = 1;
        if (q !== 8'h5A) begin
            $display("FAIL: seed not loaded, q=%h", q); errors = errors + 1;
        end

        // Guaranteed properties of a Galois LFSR (invertible linear map, 0->0):
        //  (1) a nonzero state never becomes zero;
        //  (2) the seed reappears within <= 2^WIDTH-1 steps (it sits on a cycle).
        prev = 0;  // reuse as "seed seen again" flag
        for (i = 0; i < 300; i = i + 1) begin
            @(negedge clk);
            if (q === 8'h00) begin
                $display("FAIL: LFSR reached zero at step %0d", i); errors = errors + 1;
            end
            if (i < 255 && q === 8'h5A) prev = 1;
        end
        if (!prev) begin
            $display("FAIL: seed never reappeared within 255 steps"); errors = errors + 1;
        end

        if (errors == 0) $display("PASS: lfsr_tb");
        else begin $display("FAIL: lfsr_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
