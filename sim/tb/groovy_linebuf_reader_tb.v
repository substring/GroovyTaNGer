// SPDX-License-Identifier: GPL-2.0-or-later
// Self-checking tb for rtl/core/groovy_linebuf_reader.v
// Models a small DDR3 (8-word reads) holding mem[a] = a + 1, drives the real
// video_timing_gen with fetch_fs made exactly like the real tops, and checks scanout
// pixels match the stored line for several frames.
`timescale 1ns/1ps
module groovy_linebuf_reader_tb;
    // LINE_W > W (active) and HTOTAL > W, like the real design (buffer depth
    // exceeds h_active so the last column's read pipeline never wraps the index).
    // VTOTAL > H gives vertical blanking, during which the fetch PRELOADS the
    // first lines of the next frame (fetch_fs restarts it at vblank start).
    localparam W = 16, H = 6, HTOTAL = 40, VTOTAL = 10, LINE_W = 32, LW = 5, AW = 26;

    reg pix_clk=0; always #7 pix_clk=~pix_clk;
    reg pclk=0;    always #5 pclk=~pclk;

    reg pix_rst=1, pclk_rst=1;
    reg run_raster = 0;
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
        .line_start(line_start), .frame_start(frame_start), .fetch_fs(fetch_fs),
        .pix_rgb565(pix_rgb),
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

    // ---- raster: the real video_timing_gen, wired like gwddr3video/gwddr3net_top ----
    // Active video first (vcount 0..H-1), blanking after. frame_start is the registered
    // pulse WITH the first active pixel; fetch_fs is the tops' registered pulse at the
    // start of vertical blanking (vcount == H, hcount == 0). The raster starts at (0,0)
    // when run_raster rises, so frame 0 is a cold start with no vblank pre-fill; `warm`
    // rises at the first fetch_fs and the check starts from the next frame.
    wire [15:0] hcount, vcount;
    wire        de, line_start, frame_start;
    video_timing_gen u_vtg (
        .clk(pix_clk), .rst(pix_rst), .en(run_raster),
        .h_total(HTOTAL[15:0]), .h_active(W[15:0]),
        .h_sync_begin(W[15:0] + 16'd2), .h_sync_end(W[15:0] + 16'd4),
        .v_total(VTOTAL[15:0]), .v_active(H[15:0]),
        .v_sync_begin(H[15:0] + 16'd1), .v_sync_end(H[15:0] + 16'd2),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),
        .hcount(hcount), .vcount(vcount), .hsync(), .vsync(), .de(de),
        .line_start(line_start), .frame_start(frame_start));
    reg fetch_fs = 1'b0, warm = 1'b0;
    always @(posedge pix_clk) begin
        fetch_fs <= (vcount == H) && (hcount == 16'd0);
        if (fetch_fs) warm <= 1'b1;
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
        if (run_raster && warm && exp_pipe[PIPE][16]) begin   // valid pixel at pipe end
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
        // cold frame 0, then 3 checked frames so banks recycle many times
        repeat (4*VTOTAL*HTOTAL + 50) @(negedge pix_clk);
        run_raster = 0;

        if (errors==0 && checked >= 3*W*H)
            $display("PASS: groovy_linebuf_reader_tb (%0d pixels checked)", checked);
        else begin
            $display("FAIL: groovy_linebuf_reader_tb (%0d errors, %0d checked)", errors, checked);
            $fatal(1);
        end
        $finish;
    end

    initial begin #2000000; $display("FAIL: timeout"); $fatal(1); end
endmodule
