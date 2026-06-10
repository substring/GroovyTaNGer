// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking testbench for rtl/generic/binary_to_bcd.v
`timescale 1ns/1ps
module binary_to_bcd_tb;
    reg  [15:0] bin;
    wire [19:0] bcd;          // 5 digits
    integer     errors = 0;

    binary_to_bcd #(.IN_WIDTH(16), .DIGITS(5)) dut (.bin(bin), .bcd(bcd));

    task check; input [15:0] b; input [19:0] exp;
    begin
        bin = b; #1;
        if (bcd !== exp) begin
            $display("FAIL: bin=%0d bcd=%05h expected=%05h", b, bcd, exp);
            errors = errors + 1;
        end
    end endtask

    initial begin
        check(16'd0,     20'h00000);
        check(16'd9,     20'h00009);
        check(16'd10,    20'h00010);
        check(16'd1234,  20'h01234);
        check(16'd9999,  20'h09999);
        check(16'd65535, 20'h65535);

        if (errors == 0) $display("PASS: binary_to_bcd_tb");
        else begin $display("FAIL: binary_to_bcd_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
