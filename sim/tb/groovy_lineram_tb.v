// SPDX-License-Identifier: GPL-2.0-or-later
// groovy_lineram tb: write source lines into the ring (writer ahead), read them back
// a few lines behind (reader chasing), ACROSS the ring wrap, on two different clocks.
// Checks every read pixel == what was written to that (line,col), and that a slot the
// reader is NOT reading is free to be overwritten (ring reuse) without corrupting the
// slot the reader IS reading. Data model: pixel(line,col) = (line*LINE_W + col) ^ 16'h5A5A.
`timescale 1ns/1ps
module groovy_lineram_tb;
    localparam NLINES=8, LINE_W=64, DATA_W=16, LNSEL_W=3, COL_W=6;
    localparam integer NATIVE_W = 40;      // native line < LINE_W
    localparam integer TOTLINES = 40;      // stream 40 source lines through an 8-slot ring

    reg wclk=0; always #10 wclk=~wclk;     // ~50 MHz
    reg rclk=0; always #7  rclk=~rclk;     // ~71 MHz (pix-ish)

    reg                 we=0;
    reg [LNSEL_W-1:0]   w_slot=0;
    reg [COL_W-1:0]     w_col=0;
    reg [DATA_W-1:0]    w_data=0;
    reg [LNSEL_W-1:0]   r_slot=0;
    reg [COL_W-1:0]     r_col=0;
    wire [DATA_W-1:0]   r_data;

    groovy_lineram #(.NLINES(NLINES),.LINE_W(LINE_W),.DATA_W(DATA_W),
                     .LNSEL_W(LNSEL_W),.COL_W(COL_W)) dut (
        .wr_clk(wclk),.we(we),.w_slot(w_slot),.w_col(w_col),.w_data(w_data),
        .rd_clk(rclk),.r_slot(r_slot),.r_col(r_col),.r_data(r_data));

    function [15:0] pix; input integer line; input integer col;
        pix = ((line*LINE_W + col) & 16'hFFFF) ^ 16'h5A5A; endfunction

    // shared progress: highest line fully written (like groovy_writeline) and the
    // line the reader has finished (so the writer never LAPS the reader = the ring
    // invariant write_line - read_done < NLINES; violating it IS an underrun, which
    // the real top prevents by flow control - here the writer waits).
    integer write_line = 0;
    integer read_done  = 0;
    integer errs = 0, checks = 0;

    // WRITER: fill line after line; wait if writing this line would overwrite a slot
    // the reader hasn't passed yet (keep write_line - read_done <= NLINES-1).
    integer wl, wc;
    initial begin
        we=0; wl=0;
        @(negedge wclk);
        for (wl=0; wl<TOTLINES; wl=wl+1) begin
            // ring flow control: don't clobber a slot still needed by the reader
            while (wl - read_done > NLINES-1) @(negedge wclk);
            for (wc=0; wc<NATIVE_W; wc=wc+1) begin
                w_slot <= wl % NLINES; w_col <= wc; w_data <= pix(wl,wc); we<=1;
                @(negedge wclk);
            end
            we<=0; @(negedge wclk);
            write_line = wl+1;                 // this line is now fully written
            repeat(3) @(negedge wclk);         // pace so the reader can chase
        end
        we<=0;
    end

    // READER: chase, staying MARGIN=3 lines behind write_line; read each line's
    // native cols and check. Runs on rclk. Only reads a line once write_line is far
    // enough ahead (read_line <= write_line - MARGIN) - the top's rule.
    localparam MARGIN=3;
    integer rl, rc; reg [15:0] got;
    initial begin
        @(negedge rclk);
        for (rl=0; rl<TOTLINES; rl=rl+1) begin
            // wait until this line is safe to read (writer is MARGIN ahead)
            while (write_line < rl + MARGIN && write_line < TOTLINES) @(negedge rclk);
            for (rc=0; rc<NATIVE_W; rc=rc+1) begin
                r_slot <= rl % NLINES; r_col <= rc;
                @(negedge rclk);               // addr registered
                @(negedge rclk);               // r_data valid (1-cycle BRAM read)
                got = r_data;
                checks = checks + 1;
                if (got !== pix(rl,rc)) begin
                    if (errs<20) $display("BAD line=%0d col=%0d got=%h exp=%h", rl, rc, got, pix(rl,rc));
                    errs = errs + 1;
                end
            end
            read_done = rl+1;                   // reader has passed this line -> slot free
        end
        if (errs==0 && checks==TOTLINES*NATIVE_W)
            $display("PASS: groovy_lineram_tb (%0d px, write-chases-read across ring wrap, no corruption)", checks);
        else
            $display("FAIL: errs=%0d checks=%0d (want %0d)", errs, checks, TOTLINES*NATIVE_W);
        $finish;
    end
    initial begin #2000000; $display("TIMEOUT checks=%0d errs=%0d", checks, errs); $finish; end
endmodule
