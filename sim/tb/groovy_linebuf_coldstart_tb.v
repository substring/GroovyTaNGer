// SPDX-License-Identifier: GPL-2.0-or-later
// COLD-START tb: scanout begins before the fetch can preload, with SLOW DDR3,
// so the fetch is behind at the frame top. Verifies the buffer-ready HOLD logic:
// a displayed pixel must NEVER be an UNINITIALIZED buffer value (the 8px white
// left column on HW). We pre-poison all line buffers with a sentinel (0xDEAD)
// and assert the scanout NEVER outputs the sentinel during active video - it
// must either show the correct pixel or HOLD a previously-valid line.
`timescale 1ns/1ps
module groovy_linebuf_coldstart_tb;
    localparam SRC_W=32, SRC_H=6, HREP=4, VREP=3, HSH=2;
    localparam OUT_W=SRC_W*HREP, OUT_H=SRC_H*VREP;          // 128 x 18
    localparam HTOTAL=OUT_W+20, VTOTAL=OUT_H+3, LINE_W=128, LW=7, AW=26;
    localparam READ_LAT=14;   // SLOW reads so the fetch starts behind

    reg pix_clk=0; always #3365 pix_clk=~pix_clk;
    reg pclk=0;    always #2513 pclk=~pclk;
    reg pix_rst=1, pclk_rst=1;
    reg [15:0] hcount=0, vcount=0;
    reg de=0, line_start=0, frame_start=0;
    wire [15:0] pix_rgb;
    wire rd; wire [AW-1:0] addr; reg busy=0, data_ready=0; reg [127:0] d128=0; reg [15:0] dout=0;
    wire fetch_active; integer errors=0, sentinel_hits=0;

    localparam [15:0] SENT = 16'hDEAD;   // poison / uninitialized sentinel
    function [15:0] spix; input [15:0] x,y; spix = y*SRC_W + x + 16'd1; endfunction

    groovy_linebuf_reader #(.LINE_W(LINE_W), .LW_ADDR(LW), .DDR_AW(AW),
        .SINGLE_WORD(0), .H_REPL(HREP), .V_REPL(VREP), .H_SH(HSH)) dut (
        .pix_clk(pix_clk), .pix_rst(pix_rst), .h_active(SRC_W[15:0]), .v_active(SRC_H[15:0]),
        .hcount(hcount), .vcount(vcount), .de(de),
        .line_start(line_start), .frame_start(frame_start), .pix_rgb565(pix_rgb),
        .pclk(pclk), .pclk_rst(pclk_rst), .base_addr(26'd0),
        .rd(rd), .addr(addr), .busy(busy), .data_ready(data_ready),
        .dout128(d128), .dout(dout), .fetch_active(fetch_active));

    // poison all 3 line buffers with the sentinel at t=0 (model uninitialised BRAM)
    integer j;
    initial begin
        for (j=0;j<LINE_W;j=j+1) begin
            dut.lbuf0[j]=SENT; dut.lbuf1[j]=SENT; dut.lbuf2[j]=SENT;
        end
    end

    // slow burst DDR3 model, rot-4 packed
    function [15:0] memval; input [AW-1:0] a; memval = a[15:0] + 16'd1; endfunction
    reg [AW-1:0] ral; integer dly, lane; reg [127:0] dn;
    always @(posedge pclk) begin
        data_ready <= 1'b0;
        if (rd && !busy) begin ral<=addr; dly<=READ_LAT; busy<=1'b1; end
        else if (busy) begin
            if (dly>1) dly<=dly-1;
            else begin
                for (lane=0;lane<8;lane=lane+1)
                    dn[127-((lane+4)%8)*16 -:16] = memval(ral+lane);
                d128<=dn; dout<=memval(ral); data_ready<=1'b1; busy<=1'b0;
            end
        end
    end

    // raster - NO preload wait: scanout runs from the very start (cold)
    localparam VB = VTOTAL - OUT_H;
    reg [15:0] vraw=0; reg run=0; wire active_line=(vraw>=VB);
    always @(posedge pix_clk) if (run) begin
        if (hcount==HTOTAL-1) begin hcount<=0; vraw<=(vraw==VTOTAL-1)?0:vraw+1; end
        else hcount<=hcount+1;
    end
    always @(*) begin
        vcount = active_line ? (vraw-VB) : 16'd0;
        de = run && active_line && (hcount < OUT_W);
        line_start = run && (hcount==0) && active_line;
        frame_start = run && (hcount==0) && (vraw==0);
    end

    // checker: during active video the output must NEVER be the sentinel
    // (uninitialised buffer). It may be the correct pixel OR a held prior line,
    // but never the poison value. PIPE=1 alignment.
    reg [15:0] eh, ev; reg eact;
    always @(posedge pix_clk) begin eh<=hcount; ev<=vcount; eact<=(de && hcount<OUT_W); end
    integer checked=0;
    always @(posedge pix_clk) if (run && eact && eh>=1) begin
        if (pix_rgb === SENT) begin
            if (sentinel_hits < 8)
                $display("FAIL out(%0d,%0d) showed UNINITIALISED (white) sentinel", eh, ev);
            sentinel_hits = sentinel_hits + 1; errors = errors + 1;
        end
        checked = checked + 1;
    end

    initial begin
        repeat (4) @(negedge pclk); pclk_rst=0; pix_rst=0;
        repeat (4) @(negedge pix_clk);
        run = 1;                       // start scanout IMMEDIATELY (cold)
        repeat (3*VTOTAL*HTOTAL) @(negedge pix_clk);
        run = 0;
        $display("COLDSTART: %0d sentinel(white) hits / %0d checked", sentinel_hits, checked);
        if (errors==0) $display("PASS: groovy_linebuf_coldstart_tb (no uninitialised pixels displayed)");
        else $display("FAIL: groovy_linebuf_coldstart_tb (displayed %0d white/uninit pixels)", sentinel_hits);
        $finish;
    end
    initial begin #2000000000; $display("timeout"); $finish; end
endmodule
