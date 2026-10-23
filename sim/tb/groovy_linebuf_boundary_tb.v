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
    reg run=0;
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

    // ---- raster: the real video_timing_gen, wired like gwddr3video/gwddr3net_top ----
    // Active video first (vcount 0..OUT_H-1), blanking after. frame_start is the registered
    // pulse WITH the first active pixel; fetch_fs is the tops' registered pulse at the
    // start of vertical blanking (vcount == OUT_H, hcount == 0). The raster starts at (0,0)
    // when run rises, so frame 0 is a cold start with no vblank pre-fill; `warm` rises
    // at the first fetch_fs.
    wire [15:0] hcount, vcount;
    wire        de, line_start, frame_start;
    video_timing_gen u_vtg (
        .clk(pix_clk), .rst(pix_rst), .en(run),
        .h_total(HTOTAL[15:0]), .h_active(OUT_W[15:0]),
        .h_sync_begin(OUT_W[15:0] + 16'd2), .h_sync_end(OUT_W[15:0] + 16'd4),
        .v_total(VTOTAL[15:0]), .v_active(OUT_H[15:0]),
        .v_sync_begin(OUT_H[15:0] + 16'd1), .v_sync_end(OUT_H[15:0] + 16'd2),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),
        .hcount(hcount), .vcount(vcount), .hsync(), .vsync(), .de(de),
        .line_start(line_start), .frame_start(frame_start));
    reg fetch_fs = 1'b0, warm = 1'b0;
    always @(posedge pix_clk) begin
        fetch_fs <= (vcount == OUT_H) && (hcount == 16'd0);
        if (fetch_fs) warm <= 1'b1;
    end

    // checker: expected output pixel = sline_val(vcount/VREP), for every active pixel
    // of every frame after the cold first one. The DUT's read pipeline is 2 pix_clk.
    reg [15:0] ev0, ev1; reg eact0, eact1;
    always @(posedge pix_clk) begin
        ev0 <= vcount; eact0 <= de;
        ev1 <= ev0;    eact1 <= eact0;
    end
    integer errs=0, checked=0;
    always @(posedge pix_clk) if (run && warm && eact1) begin
        checked=checked+1;
        if (pix_rgb !== sline_val(ev1/VREP)) begin
            if (errs<20) $display("BAD vcount=%0d srcline=%0d got=%h exp=%h",
                                  ev1, ev1/VREP, pix_rgb, sline_val(ev1/VREP));
            errs=errs+1;
        end
    end

    initial begin
        repeat(6) @(negedge pclk); pclk_rst=0; pix_rst=0;
        repeat(6) @(negedge pix_clk); run=1;
        repeat(4*VTOTAL*HTOTAL) @(negedge pix_clk);   // cold frame + 3 checked
        if (errs==0 && checked>=3*OUT_W*OUT_H)
                     $display("PASS: groovy_linebuf_boundary_tb (no wrong output lines, %0d px)", checked);
        else         $display("FAIL: groovy_linebuf_boundary_tb (%0d bad pixels)", errs);
        $finish;
    end
    initial begin #4000000; $display("timeout"); $finish; end
endmodule
