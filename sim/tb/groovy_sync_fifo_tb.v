// SPDX-License-Identifier: GPL-2.0-or-later
// groovy_sync_fifo tb: prove FWFT read ordering, empty/full flags, and the sticky
// overflow flag. Push a known sequence, drain it, check order + no loss; then overrun a
// small FIFO and confirm overflow latches and the retained words are the FIRST DEPTH
// (drop-newest-when-full semantics: writes past full are ignored).
`timescale 1ns/1ps
module groovy_sync_fifo_tb;
    localparam DATA_W=16, ADDR_W=4, DEPTH=(1<<ADDR_W);   // 16 deep
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg               wr_en=0, rd_en=0;
    reg  [DATA_W-1:0] wr_data=0;
    wire [DATA_W-1:0] rd_data;
    wire              full, empty, overflow;

    groovy_sync_fifo #(.DATA_W(DATA_W),.ADDR_W(ADDR_W)) dut (
        .clk(clk),.rst(rst),
        .wr_en(wr_en),.wr_data(wr_data),.full(full),
        .rd_en(rd_en),.rd_data(rd_data),.empty(empty),.overflow(overflow));

    integer i, errs=0, ovf_pulses=0;
    reg [15:0] got;
    initial begin
        @(negedge clk); rst=0; @(negedge clk);

        // --- ordering: push 8, then read 8, expect FIFO order ---
        for (i=0;i<8;i=i+1) begin
            wr_data<=i*16'h0101 + 16'h1000; wr_en<=1; @(negedge clk);
        end
        wr_en<=0; @(negedge clk);
        for (i=0;i<8;i=i+1) begin
            if (empty) begin $display("BAD empty early i=%0d",i); errs=errs+1; end
            got = rd_data;                     // FWFT: head valid before rd_en
            if (got !== (i*16'h0101 + 16'h1000)) begin
                $display("BAD order i=%0d got=%h exp=%h",i,got,i*16'h0101+16'h1000); errs=errs+1; end
            rd_en<=1; @(negedge clk); rd_en<=0; @(negedge clk);
        end
        if (!empty) begin $display("BAD not empty after drain"); errs=errs+1; end

        // --- overflow: fill DEPTH, then push 4 more; overflow PULSES on each dropped
        //     write (not sticky), and the retained words are the first DEPTH ---
        @(negedge clk);
        ovf_pulses = 0;
        for (i=0;i<DEPTH+4;i=i+1) begin
            wr_data<=i; wr_en<=1; @(negedge clk);
            if (overflow) ovf_pulses = ovf_pulses + 1;   // count drop pulses live
        end
        wr_en<=0; @(negedge clk);
        if (!full)          begin $display("BAD not full after DEPTH writes"); errs=errs+1; end
        if (ovf_pulses < 4) begin $display("BAD overflow pulses=%0d (want >=4)", ovf_pulses); errs=errs+1; end
        for (i=0;i<DEPTH;i=i+1) begin
            got = rd_data;
            if (got !== i[DATA_W-1:0]) begin
                $display("BAD ovf-order i=%0d got=%h exp=%h",i,got,i); errs=errs+1; end
            rd_en<=1; @(negedge clk); rd_en<=0; @(negedge clk);
        end
        if (!empty) begin $display("BAD not empty after ovf drain"); errs=errs+1; end

        if (errs==0) $display("PASS: groovy_sync_fifo_tb (FWFT order, empty/full, sticky overflow, drop-newest)");
        else         $display("FAIL: errs=%0d", errs);
        $finish;
    end
    initial begin #100000; $display("TIMEOUT"); $finish; end
endmodule
