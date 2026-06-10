// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking testbench for rtl/generic/video/superres_factor.v
// Checks the table from spec section 8.
`timescale 1ns/1ps
module superres_factor_tb;
    reg  [31:0] pclk;
    wire [3:0]  n;
    wire [31:0] pclk_out;
    integer     errors = 0;

    superres_factor #(.MIN_KHZ(25000), .MAX_N(6)) dut (
        .pclk_src_khz(pclk), .n(n), .pclk_out_khz(pclk_out));

    task check; input [31:0] khz; input [3:0] expect_n;
    begin
        pclk = khz; #1;
        if (n !== expect_n) begin
            $display("FAIL: pclk=%0d kHz -> n=%0d expected n=%0d (out=%0d)",
                     khz, n, expect_n, pclk_out);
            errors = errors + 1;
        end else if (pclk_out !== khz * expect_n) begin
            $display("FAIL: pclk_out mismatch pclk=%0d n=%0d out=%0d", khz, n, pclk_out);
            errors = errors + 1;
        end
    end endtask

    initial begin
        check(32'd6000,  4'd5);   // 6.0  MHz x5 = 30.0 (x4=24 < 25)
        check(32'd6144,  4'd5);   // 6.144 -> x5 = 30.72
        check(32'd7500,  4'd4);   // 7.5  x4 = 30.0
        check(32'd13500, 4'd2);   // 13.5 x2 = 27.0
        check(32'd25000, 4'd1);   // 25.0 x1 = 25.0
        check(32'd74250, 4'd1);   // 720p pixel clock, already >= 25
        check(32'd4000,  4'd6);   // below reach: clamps to MAX_N

        if (errors == 0) $display("PASS: superres_factor_tb");
        else begin $display("FAIL: superres_factor_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
