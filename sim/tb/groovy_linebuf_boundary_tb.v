// SPDX-License-Identifier: GPL-2.0-or-later
// Targeted tb: catch a SINGLE wrong OUTPUT LINE at a source-line boundary (the
// "1-pixel-tall white line between bands" seen on HW). Drives the real reader with
// a perfect fake memory where source line L has the distinct value (L+1)*256, runs
// a realistic raster with VREP=3, and checks EVERY output line maps to the correct
// source line. Reports any output row whose colour != band(vcount/VREP).
`timescale 1ns/1ps
module groovy_linebuf_boundary_tb;
    localparam SRC_W=8, SRC_H=12, HREP=4, VREP=3, HSH=2;
    localparam OUT_W=SRC_W*HREP, OUT_H=SRC_H*VREP;          // 32 x 36
    localparam HTOTAL=OUT_W+12, VTOTAL=OUT_H+6, LINE_W=32, LW=5, AW=26;

    reg pix_clk=0; always #7 pix_clk=~pix_clk;
    reg pclk=0;    always #5 pclk=~pclk;
    reg pix_rst=1, pclk_rst=1;
    reg [15:0] hcount=0; wire [15:0] vcount;
    reg de=0, line_start=0, frame_start=0, fetch_fs=0;
    wire [15:0] pix_rgb;
    wire rd; wire [AW-1:0] addr; reg busy=0, data_ready=0; reg [15:0] dout=0;
    wire [2:0] dbg_fstate;

    // source pixel value depends ONLY on the source LINE (so a wrong line = wrong
    // colour, and a 1-output-line error is unambiguous): src line L -> (L+1)*256.
    function [15:0] sline_val; input [15:0] l; sline_val = (l + 16'd1) << 8; endfunction

    groovy_linebuf_reader #(.LINE_W(LINE_W),.LW_ADDR(LW),.DDR_AW(AW),
                            .SINGLE_WORD(1),.H_REPL(HREP),.V_REPL(VREP),.H_SH(HSH)) dut (
        .pix_clk(pix_clk),.pix_rst(pix_rst),.h_active(SRC_W[15:0]),.v_active(SRC_H[15:0]),
        .hcount(hcount),.vcount(vcount),.de(de),
        .line_start(line_start),.frame_start(frame_start),.fetch_fs(fetch_fs),
        .pix_rgb565(pix_rgb),
        .pclk(pclk),.pclk_rst(pclk_rst),.base_addr(26'd0),
        .rd(rd),.addr(addr),.busy(busy),.data_ready(data_ready),
        .dout128(128'd0),.dout(dout),
        .fetch_active(),.dbg_lbwe(),.dbg_lbdata(),.dbg_fillline(),.dbg_col(),
        .dbg_fstate(dbg_fstate),.dbg_fe(),.dbg_pr(),.dbg_dr());

    // fake DDR3: word addr -> value of its SOURCE LINE. LAT-cycle latency (stress the
    // fetch so it just barely keeps up -> exposes buffer-recycle/tag races at boundaries).
    parameter integer LAT = 14;
    reg [AW-1:0] ra; integer dly;
    always @(posedge pclk) begin
        data_ready<=1'b0;
        if (rd) begin ra<=addr; dly<=LAT; busy<=1'b1; end
        else if (dly>0) begin dly<=dly-1;
            if (dly==1) begin dout<=sline_val(ra / SRC_W); data_ready<=1'b1; busy<=1'b0; end
        end
    end

    // raster (vcount is the ACTIVE line index; vblank at top preloads)
    localparam VB = VTOTAL - OUT_H;
    reg [15:0] vraw=0; reg run=0;
    wire active_line = (vraw >= VB);
    assign vcount = active_line ? (vraw - VB) : 16'd0;
    always @(posedge pix_clk) if (run) begin
        if (hcount==HTOTAL-1) begin hcount<=0; vraw<=(vraw==VTOTAL-1)?0:vraw+1; end
        else hcount<=hcount+1;
    end
    always @(*) begin
        de          = run && active_line && (hcount<OUT_W);
        line_start  = run && (hcount==0) && active_line;
        frame_start = run && (hcount==0) && (vraw==0);
        fetch_fs    = run && (hcount==0) && (vraw==(VB-1));   // vblank-start prefill
    end

    // checker: expected output pixel = sline_val(vcount/VREP). Check at mid-line (skip
    // the 2px left-edge pipeline shadow). Record per-output-line pass/fail.
    integer errs=0, lines_checked=0; reg [15:0] last_vraw=16'hFFFF;
    always @(posedge pix_clk) if (run && de && active_line && hcount>=OUT_W/2) begin
        if (pix_rgb !== sline_val(vcount/VREP)) begin
            if (errs<20) $display("BAD out_row(vraw)=%0d vcount=%0d srcline=%0d got=%h exp=%h",
                                  vraw, vcount, vcount/VREP, pix_rgb, sline_val(vcount/VREP));
            errs=errs+1;
        end
    end

    initial begin
        repeat(6) @(negedge pclk); pclk_rst=0; pix_rst=0;
        repeat(6) @(negedge pix_clk); run=1;
        repeat(3*VTOTAL*HTOTAL) @(negedge pix_clk);
        if (errs==0) $display("PASS: groovy_linebuf_boundary_tb (no wrong output lines)");
        else         $display("FAIL: groovy_linebuf_boundary_tb (%0d bad pixels)", errs);
        $finish;
    end
    initial begin #4000000; $display("timeout"); $finish; end
endmodule
