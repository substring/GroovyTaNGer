// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb for rtl/core/groovy_blit_rx.v
`timescale 1ns/1ps
module groovy_blit_rx_tb;
    reg clk=0; always #5 clk=~clk;
    reg         rst, start, in_valid;
    reg  [31:0] bytes_len;
    reg  [2:0]  bytespp;
    reg  [7:0]  in_data;
    wire        blitting, frame_done;
    wire [31:0] bytes_recv;
    wire        wr_en;
    wire [16:0] wr_addr;
    wire [15:0] wr_data;
    integer     errors=0, nwr=0, done_cnt=0;

    groovy_blit_rx #(.ADDR_W(17)) dut (
        .clk(clk), .rst(rst), .start(start), .bytes_len(bytes_len), .bytespp(bytespp),
        .in_valid(in_valid), .in_data(in_data),
        .blitting(blitting), .frame_done(frame_done), .bytes_recv(bytes_recv),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data));

    // capture writes
    reg [15:0] mem [0:15];
    reg [16:0] last_addr;
    always @(posedge clk) begin
        if (wr_en) begin mem[wr_addr]<=wr_data; last_addr<=wr_addr; nwr<=nwr+1; end
        if (frame_done) done_cnt<=done_cnt+1;
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

        if (errors==0) $display("PASS: groovy_blit_rx_tb");
        else begin $display("FAIL: groovy_blit_rx_tb (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
