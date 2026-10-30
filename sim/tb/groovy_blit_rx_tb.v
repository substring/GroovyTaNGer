// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb for rtl/core/groovy_blit_rx.v
`timescale 1ns/1ps
module groovy_blit_rx_tb;
    reg clk=0; always #5 clk=~clk;
    reg         rst, start, in_valid;
    reg  [31:0] bytes_len;
    reg  [2:0]  bytespp;
    reg  [7:0]  in_data;
    wire        blitting, frame_done, timed_out;
    wire [31:0] bytes_recv;
    wire        wr_en;
    wire [16:0] wr_addr;
    wire [15:0] wr_data;
    integer     errors=0, nwr=0, done_cnt=0, to_cnt=0;

    // small TIMEOUT_CYCLES so the timeout test doesn't need thousands of cycles
    groovy_blit_rx #(.ADDR_W(17), .TIMEOUT_CYCLES(20)) dut (
        .clk(clk), .rst(rst), .start(start), .bytes_len(bytes_len), .bytespp(bytespp),
        .in_valid(in_valid), .in_data(in_data),
        .blitting(blitting), .frame_done(frame_done), .bytes_recv(bytes_recv),
        .timed_out(timed_out),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data));

    // capture writes
    reg [15:0] mem [0:15];
    reg [16:0] last_addr;
    always @(posedge clk) begin
        if (wr_en) begin mem[wr_addr]<=wr_data; last_addr<=wr_addr; nwr<=nwr+1; end
        if (frame_done) done_cnt<=done_cnt+1;
        if (timed_out) to_cnt<=to_cnt+1;
    end

    task feed; input [7:0] d; begin
        @(negedge clk); in_valid=1'b1; in_data=d; @(negedge clk); in_valid=1'b0;
    end endtask

    initial begin
        rst=1; start=0; in_valid=0; in_data=0; bytes_len=8; bytespp=3'd2;
        @(negedge clk); @(negedge clk); rst=0; @(negedge clk);

        // begin a 4-pixel RGB565 frame (8 bytes)
        @(negedge clk); start=1; @(negedge clk); start=0;
        if (!blitting) begin $display("FAIL: not blitting after start"); errors=errors+1; end

        // packet 1: 4 bytes (2 pixels)
        feed(8'h34); feed(8'h12); feed(8'h78); feed(8'h56);
        // gap (simulate inter-packet) - blitting must persist, no accumulation
        @(negedge clk); @(negedge clk);
        if (!blitting) begin $display("FAIL: blitting dropped across gap"); errors=errors+1; end
        if (bytes_recv !== 32'd4) begin $display("FAIL: bytes_recv=%0d exp 4", bytes_recv); errors=errors+1; end
        // packet 2: 4 bytes (2 pixels) - last byte completes the frame
        feed(8'hBC); feed(8'h9A); feed(8'hF0); feed(8'hDE);
        @(negedge clk); @(negedge clk);

        if (blitting)              begin $display("FAIL: still blitting at end"); errors=errors+1; end
        if (done_cnt !== 1)        begin $display("FAIL: frame_done pulses=%0d exp 1", done_cnt); errors=errors+1; end
        if (nwr !== 4)             begin $display("FAIL: pixel writes=%0d exp 4", nwr); errors=errors+1; end
        if (mem[0]!==16'h1234)     begin $display("FAIL: px0=%04h exp 1234", mem[0]); errors=errors+1; end
        if (mem[1]!==16'h5678)     begin $display("FAIL: px1=%04h exp 5678", mem[1]); errors=errors+1; end
        if (mem[2]!==16'h9ABC)     begin $display("FAIL: px2=%04h exp 9ABC", mem[2]); errors=errors+1; end
        if (mem[3]!==16'hDEF0)     begin $display("FAIL: px3=%04h exp DEF0", mem[3]); errors=errors+1; end
        if (last_addr!==17'd3)     begin $display("FAIL: last_addr=%0d exp 3", last_addr); errors=errors+1; end

        // a second blit must restart cleanly at addr 0
        bytes_len=4; bytespp=3'd2; nwr=0; done_cnt=0;
        @(negedge clk); start=1; @(negedge clk); start=0;
        feed(8'h11); feed(8'h22); feed(8'h33); feed(8'h44);
        @(negedge clk); @(negedge clk);
        if (nwr !== 2)         begin $display("FAIL: 2nd blit writes=%0d exp 2", nwr); errors=errors+1; end
        if (mem[0]!==16'h2211) begin $display("FAIL: 2nd px0=%04h exp 2211", mem[0]); errors=errors+1; end
        if (done_cnt !== 1)    begin $display("FAIL: 2nd frame_done=%0d exp 1", done_cnt); errors=errors+1; end

        // RGB888 as GroovyMAME / the MiSTer core put it on the wire: B,G,R per pixel.
        // pixel 0 = pure red (B=00 G=00 R=FF) -> F800; pixel 1 = B=FF G=80 R=08 -> 0C1F
        bytes_len=6; bytespp=3'd3; nwr=0; done_cnt=0;
        @(negedge clk); start=1; @(negedge clk); start=0;
        feed(8'h00); feed(8'h00); feed(8'hFF);
        feed(8'hFF); feed(8'h80); feed(8'h08);
        @(negedge clk); @(negedge clk);
        if (nwr !== 2)         begin $display("FAIL: RGB888 writes=%0d exp 2", nwr); errors=errors+1; end
        if (mem[0]!==16'hF800) begin $display("FAIL: RGB888 red px0=%04h exp F800", mem[0]); errors=errors+1; end
        if (mem[1]!==16'h0C1F) begin $display("FAIL: RGB888 px1=%04h exp 0C1F", mem[1]); errors=errors+1; end

        // --- TIMEOUT (root-cause fix): start a big blit, feed a few bytes, then a
        // datagram is "lost" - go silent. blitting must NOT stay stuck forever; after
        // TIMEOUT_CYCLES of no byte, it must abort (blitting->0, timed_out pulses), so a
        // fresh CMD_BLIT can start cleanly. This is the exact bug from memory
        // udp-rx-bottleneck: one lost UDP pixel datagram used to wedge blit_rx for good.
        bytes_len=1000; bytespp=3'd2; nwr=0; done_cnt=0; to_cnt=0;
        @(negedge clk); start=1; @(negedge clk); start=0;
        feed(8'hAA); feed(8'hBB);                 // a couple bytes land...
        if (!blitting) begin $display("FAIL: dropped blitting too early"); errors=errors+1; end
        // ...then the datagram carrying the rest is LOST: go silent past TIMEOUT_CYCLES.
        repeat(25) @(negedge clk);
        if (blitting)  begin $display("FAIL: blitting still stuck after timeout window"); errors=errors+1; end
        if (to_cnt !== 1) begin $display("FAIL: timed_out pulses=%0d exp 1", to_cnt); errors=errors+1; end
        // the parser can now route a FRESH header again - prove start works right after.
        bytes_len=4; bytespp=3'd2; nwr=0; done_cnt=0;
        @(negedge clk); start=1; @(negedge clk); start=0;
        feed(8'h11); feed(8'h22); feed(8'h33); feed(8'h44);
        @(negedge clk); @(negedge clk);
        if (nwr !== 2)      begin $display("FAIL: post-timeout blit writes=%0d exp 2", nwr); errors=errors+1; end
        if (done_cnt !== 1) begin $display("FAIL: post-timeout frame_done=%0d exp 1", done_cnt); errors=errors+1; end

        // a byte arriving WITHIN the timeout window must reset the watchdog (no timeout).
        bytes_len=1000; bytespp=3'd2; nwr=0; done_cnt=0; to_cnt=0;
        @(negedge clk); start=1; @(negedge clk); start=0;
        feed(8'hAA);
        repeat(10) @(negedge clk);                // < TIMEOUT_CYCLES, still silent
        feed(8'hBB);                               // byte arrives just in time -> reset idle_cnt
        repeat(10) @(negedge clk);                 // another < TIMEOUT_CYCLES gap
        if (!blitting)     begin $display("FAIL: false timeout despite in-window byte"); errors=errors+1; end
        if (to_cnt !== 0)  begin $display("FAIL: spurious timeout pulses=%0d exp 0", to_cnt); errors=errors+1; end

        if (errors==0) $display("PASS: groovy_blit_rx_tb");
        else begin $display("FAIL: groovy_blit_rx_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
