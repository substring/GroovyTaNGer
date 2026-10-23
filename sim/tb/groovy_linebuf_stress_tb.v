// SPDX-License-Identifier: GPL-2.0-or-later
// Timing-STRESS tb for groovy_linebuf_reader (SINGLE_WORD + replication).
// Models REALISTIC DDR3 single-word latency and a hardware-like pix/pclk ratio so
// the fetch CANNOT fill a source line within one output line - reproducing the
// "scanout reads a half-filled buffer" race seen on hardware (3 garbage + 1 valid
// per 4-px replication group). Used to verify the fix (buffer-ready handshake /
// pacing) before flashing.
`timescale 1ns/1ps
module groovy_linebuf_stress_tb;
    // proportions mirror hardware: wide source, slow single-word reads, fast pixel
    // clock vs pclk. Source 64 wide so a line = 64 reads >> 1 output line.
    localparam SRC_W=64, SRC_H=6, HREP=4, VREP=3, HSH=2;
    localparam OUT_W=SRC_W*HREP, OUT_H=SRC_H*VREP;          // 256 x 18
    localparam HTOTAL=OUT_W+40, VTOTAL=OUT_H+4, LINE_W=128, LW=7, AW=26;
    localparam READ_LAT=11;        // realistic single-word read latency (pclk)

    // hardware-like: pix_clk ~74.25MHz (period ~6.73ns), pclk ~99.5MHz (~5.02ns)
    reg pix_clk=0; always #3365 pix_clk=~pix_clk;   // ps
    reg pclk=0;    always #2513 pclk=~pclk;

    reg pix_rst=1, pclk_rst=1;
    reg run = 0;
    wire [15:0] pix_rgb;
    wire rd; wire [AW-1:0] addr; reg busy=0, data_ready=0; reg [127:0] d128=0; reg [15:0] dout=0;
    wire fetch_active; integer errors=0;

    function [15:0] spix; input [15:0] x,y; spix = y*SRC_W + x + 16'd1; endfunction

    // BURST mode reader (the real fix). 8-word dout128 reads, rot-4 remap.
    groovy_linebuf_reader #(.LINE_W(LINE_W), .LW_ADDR(LW), .DDR_AW(AW),
        .SINGLE_WORD(0), .H_REPL(HREP), .V_REPL(VREP), .H_SH(HSH)) dut (
        .pix_clk(pix_clk), .pix_rst(pix_rst), .h_active(SRC_W[15:0]), .v_active(SRC_H[15:0]),
        .hcount(hcount), .vcount(vcount), .de(de),
        .line_start(line_start), .frame_start(frame_start), .fetch_fs(fetch_fs),
        .pix_rgb565(pix_rgb),
        .pclk(pclk), .pclk_rst(pclk_rst), .base_addr(26'd0),
        .rd(rd), .addr(addr), .busy(busy), .data_ready(data_ready),
        .dout128(d128), .dout(dout), .fetch_active(fetch_active));

    // realistic DDR3 BURST model: on rd at address `ral`, return 8 words
    // [ral..ral+7] packed in the HARDWARE rot-4 order (word k -> lane (k+4)%8),
    // so the reader's rot-4 remap must reconstruct them. addr = y*SRC_W + x, so
    // the value of word at address A = the source pixel spix(A%SRC_W, A/SRC_W).
    // We model value = A+1 (matches spix since spix(x,y)=y*W+x+1 = addr+1).
    function [15:0] memval; input [AW-1:0] a; memval = a[15:0] + 16'd1; endfunction
    reg [AW-1:0] ral; integer dly; integer lane;
    reg [127:0] d128_next;
    always @(posedge pclk) begin
        data_ready <= 1'b0;
        if (rd && !busy) begin ral <= addr; dly <= READ_LAT; busy <= 1'b1; end
        else if (busy) begin
            if (dly > 1) dly <= dly - 1;
            else begin
                // pack 8 words [ral..ral+7] rotated by 4: word k goes to lane
                // (k+4)%8; lane L occupies bits [127 - L*16 -: 16]. So word k
                // (=memval(ral+k)) is placed at bit-group (k+4)%8.
                for (lane=0; lane<8; lane=lane+1)
                    d128_next[127 - ((lane+4)%8)*16 -: 16] = memval(ral + lane);
                d128 <= d128_next;
                dout <= memval(ral);     // single-word still valid (lane0=ral... rot4)
                data_ready <= 1'b1; busy <= 1'b0;
            end
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

    // checker (2-deep pipeline align), every frame after the cold first one
    localparam PIPE = 1;
    reg [15:0] eh [0:PIPE]; reg [15:0] ev [0:PIPE]; reg eact [0:PIPE];
    integer p;
    always @(posedge pix_clk) begin
        eh[0] <= hcount; ev[0] <= vcount; eact[0] <= (de && hcount < OUT_W);
        for (p=1; p<=PIPE; p=p+1) begin eh[p]<=eh[p-1]; ev[p]<=ev[p-1]; eact[p]<=eact[p-1]; end
    end
    integer checked=0, badrun=0;
    always @(posedge pix_clk) if (run && warm && eact[PIPE]) begin
        if (pix_rgb !== spix(eh[PIPE]/HREP, ev[PIPE]/VREP)) begin
            if (badrun < 8) $display("FAIL out(%0d,%0d): got %0d exp %0d",
                     eh[PIPE], ev[PIPE], pix_rgb, spix(eh[PIPE]/HREP, ev[PIPE]/VREP));
            errors = errors + 1; badrun = badrun + 1;
        end
        checked = checked + 1;
    end

    initial begin
        repeat (4) @(negedge pclk); pclk_rst=0; pix_rst=0;
        repeat (4) @(negedge pix_clk);
        run = 1;
        repeat (4*VTOTAL*HTOTAL) @(negedge pix_clk);
        run = 0;
        $display("STRESS: %0d errors / %0d checked", errors, checked);
        if (errors==0) $display("PASS: groovy_linebuf_stress_tb");
        else $display("FAIL: groovy_linebuf_stress_tb (fetch cannot keep up -> half-filled buffer)");
        $finish;
    end
    initial begin #2000000000; $display("timeout"); $finish; end
endmodule
