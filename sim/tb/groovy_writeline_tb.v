// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb for rtl/core/groovy_writeline.v
`timescale 1ns/1ps
module groovy_writeline_tb;
    reg clk=0; always #5 clk=~clk;
    reg         rst, frame_start, wr_en;
    reg  [11:0] native_w;
    wire [11:0] write_line;
    integer     errors=0, i;

    groovy_writeline #(.LW(12)) dut (
        .clk(clk), .rst(rst), .frame_start(frame_start),
        .wr_en(wr_en), .native_w(native_w), .write_line(write_line));

    task pix; begin @(negedge clk); wr_en=1'b1; @(negedge clk); wr_en=1'b0; end endtask
    task chk; input [11:0] exp; input [127:0] name; begin
        if (write_line !== exp) begin
            $display("FAIL: %0s write_line=%0d exp %0d", name, write_line, exp);
            errors=errors+1; end
    end endtask

    initial begin
        rst=1; frame_start=0; wr_en=0; native_w=12'd4;   // 4 px/line
        @(negedge clk); @(negedge clk); rst=0;
        @(negedge clk); frame_start=1; @(negedge clk); frame_start=0;
        chk(12'd0, "start");

        // write line 0 (4 px) -> write_line becomes 1 after the 4th pixel
        pix; pix; pix; chk(12'd0, "3 of line0");
        pix;            chk(12'd1, "line0 done");
        // line 1
        pix; pix; pix; pix; chk(12'd2, "line1 done");
        // partial line 2
        pix; pix;       chk(12'd2, "line2 partial");
        // a gap (wr_en low) must not advance
        @(negedge clk); @(negedge clk); chk(12'd2, "gap holds");
        pix; pix;       chk(12'd3, "line2 done");

        // new frame resets
        @(negedge clk); frame_start=1; @(negedge clk); frame_start=0;
        chk(12'd0, "reframe");
        pix; pix; pix; pix; chk(12'd1, "new line0 done");

        if (errors==0) $display("PASS: groovy_writeline_tb");
        else begin $display("FAIL: groovy_writeline_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
