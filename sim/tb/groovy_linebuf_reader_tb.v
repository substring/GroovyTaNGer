// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb for rtl/core/groovy_linebuf_reader.v
// Models a small DDR3 (8-word reads) holding mem[a] = a + 1, drives a realistic
// frame (frame_start + per-line line_start with blanking), and checks scanout
// pixels match the stored line for several lines.
`timescale 1ns/1ps
module groovy_linebuf_reader_tb;
    // LINE_W > W (active) and HTOTAL > W, like the real design (buffer depth
    // exceeds h_active so the last column's read pipeline never wraps the index).
    // VTOTAL > H gives vertical blanking, during which the fetch PRELOADS the
    // first lines before active video starts (exactly like real timing - the
    // line buffer must be filled ahead of the beam).
    localparam W = 16, H = 6, HTOTAL = 40, VTOTAL = 10, LINE_W = 32, LW = 5, AW = 26;

    reg pix_clk=0; always #7 pix_clk=~pix_clk;
    reg pclk=0;    always #5 pclk=~pclk;

    reg pix_rst=1, pclk_rst=1;
    reg [15:0] hcount=0, vcount=0;
    reg de=0, line_start=0, frame_start=0;
    wire [15:0] pix_rgb;

    wire        rd;
    wire [AW-1:0] addr;
    reg         busy=0, data_ready=0;
    reg  [127:0] dout128=0;
    wire fetch_active;
    integer errors=0;

    function [15:0] pat; input [25:0] a; pat = a[15:0] + 16'd1; endfunction

    groovy_linebuf_reader #(.LINE_W(LINE_W), .LW_ADDR(LW), .DDR_AW(AW), .SINGLE_WORD(0)) dut (
        .pix_clk(pix_clk), .pix_rst(pix_rst), .h_active(W[15:0]), .v_active(H[15:0]),
        .hcount(hcount), .vcount(vcount), .de(de),
        .line_start(line_start), .frame_start(frame_start), .pix_rgb565(pix_rgb),
        .pclk(pclk), .pclk_rst(pclk_rst), .base_addr(26'd0),
        .rd(rd), .addr(addr), .busy(busy), .data_ready(data_ready),
        .dout128(dout128), .dout(16'd0),
        .fetch_active(fetch_active));

    // DDR3 model: 3-cycle latency, returns 8 consecutive words from addr
    reg [AW-1:0] raddr_l; integer dly; integer mi;
    always @(posedge pclk) begin
        data_ready <= 1'b0;
        if (rd) begin raddr_l <= addr; dly <= 3; busy <= 1'b1; end
        else if (dly > 0) begin
            dly <= dly - 1;
            if (dly == 1) begin
                // Model the REAL DDR3-800 dout128 packing: ROTATED BY 4 (HW-verified
                // by the ddr3burst probe). word k (=pat(raddr+k)) sits at lane
                // (k+4)%8, where lane L = bits [127 - L*16 -: 16]. The reader's
                // rot-4 remap (word k = lane (k+4)%8) reconstructs it.
                for (mi=0; mi<8; mi=mi+1)
                    dout128[127 - ((mi+4)%8)*16 -: 16] <= pat(raddr_l + mi[25:0]);
                data_ready <= 1'b1; busy <= 1'b0;
            end
        end
    end

    // ---- free-running raster, exactly like video_timing_gen ----
    // h: 0..HTOTAL-1 (active 0..W-1, then back porch). line_start pulses at h==0,
    // frame_start at (h==0 && v==0). de high during active. This drives the DUT
    // with real timing (a full blanking gap before each line_start), so there is
    // no artificial back-to-back line boundary.
    // raw raster line vraw: 0..VTOTAL-1. Vertical blank is the first VB lines;
    // active video is vraw in [VB, VB+H). The DUT's vcount input is the ACTIVE
    // line index (vraw - VB), matching the bank tags (0..H-1). During vblank the
    // fetch preloads the first lines. line_start pulses every line (so the fetch
    // is paced per line); frame_start at the very top (vraw==0).
    localparam VB = VTOTAL - H;          // = 4 vblank lines at top
    reg [15:0] vraw = 0;
    reg run_raster = 0;
    wire active_line = (vraw >= VB);
    always @(posedge pix_clk) begin
        if (run_raster) begin
            if (hcount == HTOTAL-1) begin
                hcount <= 0;
                vraw   <= (vraw == VTOTAL-1) ? 0 : vraw + 1;
            end else hcount <= hcount + 1;
        end
    end
    // DUT inputs
    always @(*) begin
        vcount      = active_line ? (vraw - VB) : 16'd0;
        de          = run_raster && active_line && (hcount < W);
        line_start  = run_raster && (hcount == 0) && active_line;
        frame_start = run_raster && (hcount == 0) && (vraw == 0);
    end

    // checker: push the EXPECTED pixel + a valid flag down a shift register the
    // same depth as the DUT read pipeline, so comparison auto-aligns regardless
    // of exact latency. PIPE = DUT hcount->pix_rgb565 latency in pix_clk.
    localparam PIPE = 1;
    reg [16:0] exp_pipe [0:PIPE];   // {valid, 16b expected}
    reg [15:0] exp_col_pipe [0:PIPE];
    reg [15:0] exp_lin_pipe [0:PIPE];
    integer p;
    always @(posedge pix_clk) begin
        exp_pipe[0]     <= { (de && hcount < W), pat(vcount*W + hcount) };
        exp_col_pipe[0] <= hcount;
        exp_lin_pipe[0] <= vcount;
        for (p = 1; p <= PIPE; p = p + 1) begin
            exp_pipe[p]     <= exp_pipe[p-1];
            exp_col_pipe[p] <= exp_col_pipe[p-1];
            exp_lin_pipe[p] <= exp_lin_pipe[p-1];
        end
    end
    integer checked = 0;
    always @(posedge pix_clk) begin
        if (run_raster && exp_pipe[PIPE][16]) begin   // valid pixel at pipe end
            if (pix_rgb !== exp_pipe[PIPE][15:0]) begin
                $display("FAIL v=%0d col=%0d: got %h exp %h",
                         exp_lin_pipe[PIPE], exp_col_pipe[PIPE], pix_rgb, exp_pipe[PIPE][15:0]);
                errors = errors + 1;
            end
            checked = checked + 1;
        end
    end

    initial begin
        repeat (4) @(negedge pclk); pclk_rst=0; pix_rst=0;
        repeat (4) @(negedge pix_clk);
        run_raster = 1;                       // start the raster + fetch
        // run for ~3 full frames so banks recycle many times
        repeat (3*VTOTAL*HTOTAL + 50) @(negedge pix_clk);
        run_raster = 0;

        if (errors==0 && checked > 2*W*(H-1))
            $display("PASS: groovy_linebuf_reader_tb (%0d pixels checked)", checked);
        else begin
            $display("FAIL: groovy_linebuf_reader_tb (%0d errors, %0d checked)", errors, checked);
            $fatal(1);
        end
        $finish;
    end

    initial begin #2000000; $display("FAIL: timeout"); $fatal(1); end
endmodule
