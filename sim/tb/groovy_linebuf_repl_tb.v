// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb for groovy_linebuf_reader integer replication (H_REPL/V_REPL)
// in SINGLE_WORD mode. Source framebuffer SRC_W x SRC_H, output upscaled
// H_REPL x V_REPL; checks each output pixel == source(hcount/H_REPL, vcount/V_REPL).
//
// The raster is the real video_timing_gen with fetch_fs made like the real tops, and
// every pixel of every frame after the cold first one is checked, left edge included.
`timescale 1ns/1ps
module groovy_linebuf_repl_tb;
    // source 8x4, repl 2x3 -> output 16x12. HTOTAL/VTOTAL give blanking.
    localparam SRC_W=8, SRC_H=4, HREP=2, VREP=3, HSH=1;
    localparam OUT_W=SRC_W*HREP, OUT_H=SRC_H*VREP;           // 16 x 12
    localparam HTOTAL=OUT_W+10, VTOTAL=OUT_H+4, LINE_W=32, LW=5, AW=26;

    reg pix_clk=0; always #7 pix_clk=~pix_clk;
    reg pclk=0;    always #5 pclk=~pclk;
    reg pix_rst=1, pclk_rst=1;
    reg run = 0;
    wire [15:0] pix_rgb;
    wire rd; wire [AW-1:0] addr; reg busy=0, data_ready=0; reg [127:0] dout128=0; reg [15:0] dout=0;
    wire fetch_active; integer errors=0;

    // source pixel value = y*SRC_W + x + 1 (nonzero, unique per source pixel)
    function [15:0] spix; input [15:0] x,y; spix = y*SRC_W + x + 16'd1; endfunction

    groovy_linebuf_reader #(.LINE_W(LINE_W), .LW_ADDR(LW), .DDR_AW(AW),
        .SINGLE_WORD(1), .H_REPL(HREP), .V_REPL(VREP), .H_SH(HSH)) dut (
        .pix_clk(pix_clk), .pix_rst(pix_rst), .h_active(SRC_W[15:0]), .v_active(SRC_H[15:0]),
        .hcount(hcount), .vcount(vcount), .de(de),
        .line_start(line_start), .frame_start(frame_start), .fetch_fs(fetch_fs),
        .pix_rgb565(pix_rgb),
        .pclk(pclk), .pclk_rst(pclk_rst), .base_addr(26'd0),
        .rd(rd), .addr(addr), .busy(busy), .data_ready(data_ready),
        .dout128(dout128), .dout(dout), .fetch_active(fetch_active));

    // single-word DDR3 model: addr = y*SRC_W + x -> return spix(x,y). 3-cyc latency.
    reg [AW-1:0] raddr_l; integer dly;
    always @(posedge pclk) begin
        data_ready <= 1'b0;
        if (rd) begin raddr_l <= addr; dly <= 3; busy <= 1'b1; end
        else if (dly > 0) begin
            dly <= dly - 1;
            if (dly == 1) begin dout <= raddr_l[15:0] + 16'd1; data_ready <= 1'b1; busy <= 1'b0; end
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

    // checker: the DUT scanout is a 2-stage pipeline (src_col -> q0/1/2 register,
    // then the read_idx mux register), so pix_rgb565 for hcount=N is valid 2
    // pix_clk later. Carry the expected value + valid through a 2-deep shift
    // register so the comparison auto-aligns (same approach as the burst tb).
    localparam PIPE = 1;
    reg [15:0] eh [0:PIPE];
    reg [15:0] ev [0:PIPE];
    reg        eact [0:PIPE];
    integer p;
    always @(posedge pix_clk) begin
        eh[0]   <= hcount; ev[0] <= vcount; eact[0] <= (de && hcount < OUT_W);
        for (p = 1; p <= PIPE; p = p + 1) begin
            eh[p] <= eh[p-1]; ev[p] <= ev[p-1]; eact[p] <= eact[p-1];
        end
    end
    integer checked=0;
    always @(posedge pix_clk) if (run && warm && eact[PIPE]) begin
        if (pix_rgb !== spix(eh[PIPE]/HREP, ev[PIPE]/VREP)) begin
            $display("FAIL out(%0d,%0d): got %0d exp %0d (src %0d,%0d)",
                     eh[PIPE], ev[PIPE], pix_rgb, spix(eh[PIPE]/HREP, ev[PIPE]/VREP),
                     eh[PIPE]/HREP, ev[PIPE]/VREP);
            errors = errors + 1;
        end
        checked = checked + 1;
    end

    initial begin
        repeat (4) @(negedge pclk); pclk_rst=0; pix_rst=0;
        repeat (4) @(negedge pix_clk);
        run = 1;
        repeat (4*VTOTAL*HTOTAL + 50) @(negedge pix_clk);   // cold frame + 3 checked
        run = 0;
        if (errors==0 && checked >= 3*OUT_W*OUT_H)
            $display("PASS: groovy_linebuf_repl_tb (%0d px checked)", checked);
        else begin $display("FAIL: groovy_linebuf_repl_tb (%0d err, %0d checked)", errors, checked); $fatal(1); end
        $finish;
    end
    initial begin #3000000; $display("FAIL: timeout"); $fatal(1); end
endmodule
