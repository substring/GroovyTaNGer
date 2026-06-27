// SPDX-License-Identifier: GPL-2.0-or-later
// CDC + burst-coalescing tb: blit-side pixel stream (50 MHz) -> groovy_async_fifo ->
// groovy_ddr3_writer (faster pclk) -> fake DDR3. Pushes N sequential pixels with a
// known {addr,data} pattern at a realistic blit burst rate, decodes the writer's
// full-beat (wr_beat/din_beat) AND single-word (wr/din) writes back into per-word
// values, and checks EVERY pixel landed at the right address with no loss/dup. This
// is the seam that fixes the FIFO-overflow flicker (8 px -> 1 BL8 write).
`timescale 1ns/1ps
module groovy_ddr3_cdc_tb;
    localparam integer DW = 42;   // {addr[25:0], data[15:0]}
    localparam integer AW = 10;
    localparam integer N  = 4096; // pixels (multiple of 8 -> all full beats)

    reg wclk=0; always #10 wclk=~wclk;   // 50 MHz
    reg rclk=0; always #6  rclk=~rclk;   // ~83 MHz
    reg wrst=1, rrst=1;

    reg          wr_en=0;
    reg  [DW-1:0] wr_data=0;
    wire         full, empty, fifo_rd_en;
    wire [DW-1:0] fifo_rdata;

    groovy_async_fifo #(.DATA_W(DW), .ADDR_W(AW)) dut_fifo (
        .wr_clk(wclk), .wr_rst(wrst), .wr_en(wr_en & ~full), .wr_data(wr_data), .full(full),
        .rd_clk(rclk), .rd_rst(rrst), .rd_en(fifo_rd_en), .rd_data(fifo_rdata), .empty(empty));

    wire         w_wr, w_wr_beat; wire [25:0] w_addr; wire [15:0] w_din;
    wire [127:0] w_din_beat; wire wr_active;
    reg          busy=0;
    groovy_ddr3_writer #(.AW(26), .FIFO_AW(AW)) dut_wr (
        .clk(rclk), .rst(rrst),
        .fifo_empty(empty), .fifo_rdata(fifo_rdata), .fifo_rd_en(fifo_rd_en),
        .wr(w_wr), .wr_beat(w_wr_beat), .addr(w_addr), .din(w_din), .din_beat(w_din_beat),
        .busy(busy), .active(wr_active));

    // fake adapter: any write pulse -> busy rises next cycle, holds a few cycles.
    // GRANT gate: model the top's reader-priority mux. Periodically the reader "steals"
    // the bus (grant=0), so the writer's request must be SUPPRESSED those cycles and
    // it must retry without hanging or double-writing. Toggle a pseudo-random-ish grant.
    reg grant; integer gctr;
    always @(posedge rclk) begin
        if (rrst) begin grant<=1; gctr<=0; end
        else begin
            gctr <= gctr + 1;
            grant <= (gctr % 13) < 8;   // ~62% granted, gaps of ~5 cycles (like fetch_active)
        end
    end
    // gated requests actually presented to the fake adapter
    wire g_wr      = w_wr      & grant;
    wire g_wr_beat = w_wr_beat & grant;

    // model memory: write each accepted word, count writes per address.
    reg [15:0] mem [0:8191];
    integer    wcount [0:8191];
    integer    i, k;
    initial for (i=0;i<8192;i=i+1) begin mem[i]=16'hDEAD; wcount[i]=0; end

    function [15:0] exp_data; input integer i; exp_data = i[15:0] ^ 16'hABCD; endfunction

    // fake adapter: accept a GATED request when idle (busy 0->1) and COMMIT the write
    // to memory at that exact accept event (mirrors the real adapter latching the
    // command A_IDLE->A_WR, which is the same event the DUT's busy-rising 'accept'
    // detects). Hold busy a few cycles, then drop. One accept = one commit.
    integer bcd;
    always @(posedge rclk) begin
        if (rrst) begin busy<=0; bcd<=0; end
        else if (!busy && (g_wr | g_wr_beat)) begin
            busy<=1; bcd<=4;
            if (g_wr_beat) for (k=0;k<8;k=k+1) begin
                mem[w_addr + k]    <= w_din_beat[k*16 +: 16];
                wcount[w_addr + k] <= wcount[w_addr + k] + 1;
            end
            if (g_wr) begin
                mem[w_addr]    <= w_din;
                wcount[w_addr] <= wcount[w_addr] + 1;
            end
        end
        else if (busy && bcd>0) begin bcd<=bcd-1; if (bcd==1) busy<=0; end
    end

    integer ovf=0;
    always @(posedge wclk) if (!wrst && wr_en && full) ovf=ovf+1;

    initial begin
        repeat(4) @(negedge wclk); wrst=0;
        repeat(4) @(negedge rclk); rrst=0;
        @(negedge wclk);
        // push N pixels in sequential address order, in 720-word bursts (1440B UDP
        // datagrams) with a gap between bursts - the exact RX pattern that overflowed.
        for (i=0;i<N;i=i+1) begin
            while (full) @(negedge wclk);
            wr_data <= {i[25:0], exp_data(i)};
            wr_en   <= 1'b1; @(negedge wclk); wr_en <= 1'b0;
            if (i % 720 == 719) repeat(8) @(negedge wclk);   // inter-datagram gap
        end
        repeat(40000) @(negedge rclk);   // let the writer drain fully (gated, pending idiom)

        // check: every pixel written exactly once with the right value.
        begin : chk
            integer errs; errs=0;
            for (i=0;i<N;i=i+1) begin
                if (wcount[i] != 1) begin
                    if (errs<15) $display("BAD addr=%0d written %0d times (want 1)", i, wcount[i]);
                    errs=errs+1;
                end else if (mem[i] !== exp_data(i)) begin
                    if (errs<15) $display("BAD addr=%0d data=%h exp=%h", i, mem[i], exp_data(i));
                    errs=errs+1;
                end
            end
            if (errs==0 && ovf==0) $display("PASS: groovy_ddr3_cdc_tb (all %0d px coalesced+written once, no loss, no overflow)", N);
            else                   $display("FAIL: errs=%0d ovf=%0d", errs, ovf);
        end
        $finish;
    end
    initial begin #20000000; $display("TIMEOUT"); $finish; end
endmodule
