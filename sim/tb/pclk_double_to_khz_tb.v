// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking testbench for rtl/core/pclk_double_to_khz.v
// Uses $realtobits to generate genuine IEEE-754 doubles for the modeline pClocks.
`timescale 1ns/1ps
module pclk_double_to_khz_tb;
    reg  [63:0] dbl;
    wire [31:0] khz;
    wire        valid;
    integer     errors = 0;

    pclk_double_to_khz dut (.pclk_dbl(dbl), .pclk_khz(khz), .valid(valid));

    // check value (MHz) -> expected kHz, allow +/-1 kHz for double rounding
    task chk; input real mhz; input [31:0] exp_khz;
        integer diff;
    begin
        dbl = $realtobits(mhz); #1;
        diff = (khz > exp_khz) ? (khz - exp_khz) : (exp_khz - khz);
        if (!valid || diff > 1) begin
            $display("FAIL: %f MHz -> %0d kHz (exp %0d, valid=%b)", mhz, khz, exp_khz, valid);
            errors = errors + 1;
        end else
            $display("  OK %f MHz -> %0d kHz", mhz, khz);
    end endtask

    initial begin
        chk(25.175, 32'd25175);   // VGA 640x480@60
        chk(27.000, 32'd27000);
        chk(6.144,  32'd6144);    // low arcade clock
        chk(13.500, 32'd13500);
        chk(74.250, 32'd74250);   // 720p
        chk(148.500,32'd148500);  // 1080p-class upper bound
        chk(1.000,  32'd1000);
        chk(0.500,  32'd500);     // sub-MHz still decodes

        // zero should report invalid
        dbl = 64'd0; #1;
        if (valid || khz !== 32'd0) begin
            $display("FAIL: zero double not flagged invalid"); errors = errors + 1; end

        if (errors == 0) $display("PASS: pclk_double_to_khz_tb");
        else begin $display("FAIL: pclk_double_to_khz_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
