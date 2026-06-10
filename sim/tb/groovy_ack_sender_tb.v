// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking testbench for rtl/core/groovy_ack_sender.v
// Verifies the 13-byte little-endian ACK layout (spec section 5.4).
`timescale 1ns/1ps
module groovy_ack_sender_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    reg         rst, start, out_ready;
    reg  [31:0] frame_echo, fpga_vga_frame;
    reg  [15:0] vsync_echo, fpga_vga_vcount;
    reg  [7:0]  status_bits;
    wire        out_valid, out_last, busy;
    wire [7:0]  out_data;
    integer     errors = 0;

    reg  [7:0] cap_mem  [0:31];
    reg        cap_last [0:31];
    integer    cap_idx = 0;
    reg  [7:0] exp [0:12];
    integer    k;

    groovy_ack_sender dut (
        .clk(clk), .rst(rst), .start(start),
        .frame_echo(frame_echo), .vsync_echo(vsync_echo),
        .fpga_vga_frame(fpga_vga_frame), .fpga_vga_vcount(fpga_vga_vcount),
        .status_bits(status_bits),
        .out_valid(out_valid), .out_data(out_data), .out_last(out_last),
        .out_ready(out_ready), .busy(busy));

    always @(posedge clk) begin
        if (!rst && out_valid && out_ready) begin
            cap_mem[cap_idx]  = out_data;
            cap_last[cap_idx] = out_last;
            cap_idx           = cap_idx + 1;
        end
    end

    initial begin
        rst = 1; start = 0; out_ready = 1;
        frame_echo      = 32'h11223344;
        vsync_echo      = 16'hAABB;
        fpga_vga_frame  = 32'h55667788;
        fpga_vga_vcount = 16'hCCDD;
        status_bits     = 8'h96;
        // expected little-endian byte stream
        exp[0]=8'h44; exp[1]=8'h33; exp[2]=8'h22; exp[3]=8'h11;
        exp[4]=8'hBB; exp[5]=8'hAA;
        exp[6]=8'h88; exp[7]=8'h77; exp[8]=8'h66; exp[9]=8'h55;
        exp[10]=8'hDD; exp[11]=8'hCC;
        exp[12]=8'h96;

        @(negedge clk); @(negedge clk);
        rst = 0;
        @(negedge clk);
        start = 1; @(negedge clk); start = 0;

        // wait for the 13 bytes
        wait (cap_idx == 13);
        @(negedge clk);

        for (k = 0; k < 13; k = k + 1) begin
            if (cap_mem[k] !== exp[k]) begin
                $display("FAIL: byte %0d = %h expected %h", k, cap_mem[k], exp[k]);
                errors = errors + 1;
            end
        end
        if (cap_last[12] !== 1'b1) begin
            $display("FAIL: out_last not set on byte 12"); errors = errors + 1; end
        for (k = 0; k < 12; k = k + 1)
            if (cap_last[k] !== 1'b0) begin
                $display("FAIL: out_last set early on byte %0d", k); errors = errors + 1; end
        if (busy !== 1'b0) begin
            $display("FAIL: still busy after send"); errors = errors + 1; end

        if (errors == 0) $display("PASS: groovy_ack_sender_tb");
        else begin $display("FAIL: groovy_ack_sender_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
