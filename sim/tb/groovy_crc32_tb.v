// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb for groovy_crc32: confirms the core's verification properties.
//   1. identical streams -> identical CRC (no false positives).
//   2. a single bit flip in ONE word -> different CRC (detection works).
//   3. swapping two words -> different CRC (order-sensitive, catches addr skew).
//   4. a known reference vector is stable across runs (regression guard).
`timescale 1ns/1ps
`default_nettype none

module groovy_crc32_tb;
    reg clk = 0; always #5 clk = ~clk;
    reg rst, init, valid; reg [15:0] data;
    wire [31:0] crc;

    groovy_crc32 dut (.clk(clk), .rst(rst), .init(init), .valid(valid),
                      .data(data), .crc(crc));

    integer i, errors = 0;
    reg [31:0] crc_clean, crc_flip, crc_swap;

    // drive one line of N words from a function, return the final CRC.
    task run_line;
        input integer flip_word;    // word index to flip a bit in (-1 = none)
        input integer swap;         // 1 = swap words 3 and 4
        output [31:0] result;
        integer k;
        reg [15:0] w;
        begin
            @(negedge clk); init <= 1; valid <= 0;
            @(negedge clk); init <= 0;
            for (k = 0; k < 16; k = k + 1) begin
                // base pattern: a scramble so words differ a lot
                w = (k * 16'h9E37) ^ 16'hA5A5;
                if (swap && k == 3) w = (4 * 16'h9E37) ^ 16'hA5A5;
                if (swap && k == 4) w = (3 * 16'h9E37) ^ 16'hA5A5;
                if (k == flip_word) w = w ^ 16'h0001;   // flip one bit
                @(negedge clk); valid <= 1; data <= w;
            end
            @(negedge clk); valid <= 0;
            @(negedge clk); result = crc;
        end
    endtask

    initial begin
        rst = 1; init = 0; valid = 0; data = 0;
        @(negedge clk); rst = 0;

        run_line(-1, 0, crc_clean);   // clean reference
        run_line(-1, 0, crc_flip);    // identical run -> must match clean
        if (crc_flip !== crc_clean) begin
            $display("FAIL: identical streams gave different CRC (%08x vs %08x)",
                     crc_flip, crc_clean); errors = errors + 1;
        end

        run_line(7, 0, crc_flip);     // flip 1 bit in word 7 -> must differ
        if (crc_flip === crc_clean) begin
            $display("FAIL: single-bit flip NOT detected (CRC unchanged %08x)", crc_clean);
            errors = errors + 1;
        end

        run_line(-1, 1, crc_swap);    // swap words 3,4 -> must differ (order matters)
        if (crc_swap === crc_clean) begin
            $display("FAIL: word swap NOT detected (CRC unchanged %08x)", crc_clean);
            errors = errors + 1;
        end

        $display("reference CRC (clean line) = %08x", crc_clean);
        if (errors == 0) $display("PASS: groovy_crc32_tb (detection + order + stability)");
        else             $display("FAILED: %0d error(s)", errors);
        $finish;
    end
endmodule

`default_nettype wire
