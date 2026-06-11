// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb for rtl/generic/video/test_pattern_gen.v
`timescale 1ns/1ps
module test_pattern_gen_tb;
    reg  [15:0] hcount, vcount;
    reg         de;
    wire [7:0]  r, g, b;
    integer     errors = 0;

    localparam HA = 1280, VA = 720, BW = HA/8;
    reg [11:0] h_act = HA, v_act = VA;

    test_pattern_gen dut (
        .h_act(h_act), .v_act(v_act),
        .hcount(hcount), .vcount(vcount), .de(de), .r(r), .g(g), .b(b));

    task chk; input [15:0] h, v; input dd;
             input [7:0] er, eg, eb; input [127:0] name;
    begin
        hcount=h; vcount=v; de=dd; #1;
        if (r!==er || g!==eg || b!==eb) begin
            $display("FAIL: %0s @(%0d,%0d,de=%b) = %02h%02h%02h exp %02h%02h%02h",
                     name, h, v, dd, r, g, b, er, eg, eb);
            errors = errors + 1;
        end
    end endtask

    initial begin
        // blanking -> black
        chk(16'd500, 16'd300, 1'b0, 8'h00,8'h00,8'h00, "blank");
        // border -> white
        chk(16'd1, 16'd300, 1'b1, 8'hFF,8'hFF,8'hFF, "left border");
        chk(16'd500, 16'd2, 1'b1, 8'hFF,8'hFF,8'hFF, "top border");
        // bars (mid-screen vertically, away from borders)
        chk(BW*0+80,  16'd360, 1'b1, 8'hFF,8'hFF,8'hFF, "bar0 white");
        chk(BW*1+10,  16'd360, 1'b1, 8'hFF,8'hFF,8'h00, "bar1 yellow");
        chk(BW*2+10,  16'd360, 1'b1, 8'h00,8'hFF,8'hFF, "bar2 cyan");
        chk(BW*3+10,  16'd360, 1'b1, 8'h00,8'hFF,8'h00, "bar3 green");
        chk(BW*4+10,  16'd360, 1'b1, 8'hFF,8'h00,8'hFF, "bar4 magenta");
        chk(BW*5+10,  16'd360, 1'b1, 8'hFF,8'h00,8'h00, "bar5 red");
        chk(BW*6+10,  16'd360, 1'b1, 8'h00,8'h00,8'hFF, "bar6 blue");
        chk(BW*7+10,  16'd360, 1'b1, 8'h00,8'h00,8'h00, "bar7 black");

        if (errors == 0) $display("PASS: test_pattern_gen_tb");
        else begin $display("FAIL: test_pattern_gen_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
