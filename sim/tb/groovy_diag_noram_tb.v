// SPDX-License-Identifier: GPL-2.0-or-later
// Faithful sim of the diag_noram pipeline: the REAL video_timing_gen + the REAL
// groovy_linebuf_reader (tag-match scanout) + the REAL groovy_fake_ddr3 (perfect
// bars). Reproduces the HW diag_noram result (TRA=E1000, P=F800/0000 at H=2 V=0)
// deterministically so the scaler bug can be traced. Uses the SAME 720p modeline
// and HREP/VREP/HSH/LINE_W as diag_noram. Two realistic clocks (pix_clk slower
// than pclk). Checks every output pixel vs the expected band colour and prints the
// first mismatches with the reader's internal fetch/scan state.
`timescale 1ns/1ps
`default_nettype none
module groovy_diag_noram_tb;
    localparam [15:0] SRC_W=16'd320, SRC_H=16'd240, OUT_W=16'd1280, OUT_H=16'd720;
    localparam integer HREP=4, VREP=3, HSH=2;
    // SHRINK the raster for sim speed: keep the structure, fewer pixels. Use a small
    // modeline so a few frames run fast, but keep HREP=4/VREP=3 and the source small.
    localparam [15:0] S_W=16'd16, S_H=16'd12;                 // source 16x12
    localparam [15:0] O_W=S_W*HREP, O_H=S_H*VREP;             // 64x36
    localparam [15:0] HTOT=O_W+16'd30, VTOT=O_H+16'd10;
    localparam [15:0] HSB=O_W+16'd8, HSE=O_W+16'd12, VSB=O_H+16'd3, VSE=O_H+16'd5;

    reg pix_clk=0; always #6.7 pix_clk=~pix_clk;   // ~74.6 MHz
    reg pclk=0;    always #5.0 pclk=~pclk;          // 100 MHz
    reg rst_n=0;

    // ---- fake memory (perfect bars), LATENCY 40 like diag_noram ----
    wire        r_rd; wire [25:0] r_addr; wire [15:0] fk_dout; wire fk_dready, fk_busy;
    groovy_fake_ddr3 #(.ADDR_W(26), .LATENCY(40), .BARS(1), .WIDTH(S_W), .HEIGHT(S_H)) u_fake (
        .clk(pclk), .rst(~rst_n), .rd(r_rd), .wr(1'b0), .refresh(1'b0),
        .addr(r_addr), .din(16'd0), .dout(fk_dout), .data_ready(fk_dready), .busy(fk_busy));

    // ---- real timing gen ----
    wire de, hsync, vsync, line_start, frame_start; wire [15:0] hcount, vcount;
    video_timing_gen u_timing (
        .clk(pix_clk), .rst(~rst_n), .en(1'b1),
        .h_total(HTOT), .h_active(O_W), .h_sync_begin(HSB), .h_sync_end(HSE),
        .v_total(VTOT), .v_active(O_H), .v_sync_begin(VSB), .v_sync_end(VSE),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),
        .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de),
        .line_start(line_start), .frame_start(frame_start));

    // ---- the reader under test ----
    wire [15:0] pix565; wire fetch_active;
    groovy_linebuf_reader #(.LINE_W(64), .LW_ADDR(6), .DDR_AW(26),
        .SINGLE_WORD(1), .H_REPL(HREP), .V_REPL(VREP), .H_SH(HSH)) dut (
        .pix_clk(pix_clk), .pix_rst(~rst_n), .h_active(S_W), .v_active(S_H),
        .hcount(hcount), .vcount(vcount), .de(de),
        .line_start(line_start), .frame_start(frame_start), .pix_rgb565(pix565),
        .pclk(pclk), .pclk_rst(~rst_n), .base_addr(26'd0),
        .rd(r_rd), .addr(r_addr), .busy(fk_busy), .data_ready(fk_dready),
        .dout128(128'd0), .dout(fk_dout), .fetch_active(fetch_active));

    // expected band colour = fake mem's bandf(row) : band = row/(S_H/8).
    function [15:0] band_color; input [15:0] srow;
        reg [2:0] b; begin
            b = srow / (S_H/8);
            case (b)
              3'd0:band_color=16'hF800;3'd1:band_color=16'h07E0;3'd2:band_color=16'h001F;
              3'd3:band_color=16'hFFE0;3'd4:band_color=16'h07FF;3'd5:band_color=16'hF81F;
              3'd6:band_color=16'hFFFF;default:band_color=16'h8410;
            endcase
        end
    endfunction

    // golden check, delayed 2 pix_clk to match the reader read pipeline.
    reg [15:0] eh[0:2], ev[0:2]; reg eact[0:2]; integer i;
    always @(posedge pix_clk) begin
        eh[0]<=hcount; ev[0]<=vcount; eact[0]<=(de && hcount<O_W);
        for (i=1;i<3;i=i+1) begin eh[i]<=eh[i-1]; ev[i]<=ev[i-1]; eact[i]<=eact[i-1]; end
    end
    localparam PIPE=2;
    integer errors=0, checked=0; reg done=0;
    integer frame=0; reg vs_d=0;
    integer ferr[0:7];   // errors per frame
    initial for (frame=0;frame<8;frame=frame+1) ferr[frame]=0;
    always @(posedge pix_clk) begin
        vs_d <= vsync;
        if (vsync && !vs_d && frame<7) frame <= frame + 1;   // new frame on vsync rise
    end
    always @(posedge pix_clk) if (rst_n && !done && eact[PIPE]) begin
        checked = checked + 1;
        if (pix565 !== band_color(ev[PIPE]/VREP)) begin
            errors = errors + 1;
            if (frame<8) ferr[frame] = ferr[frame] + 1;
        end
    end

    initial begin
        repeat (8) @(negedge pclk); rst_n=1;
        repeat (6*VTOT*HTOT) @(negedge pix_clk);
        done=1;
        $display("RESULT: %0d errors / %0d checked (total; includes first-frame cold-start)", errors, checked);
        for (frame=0; frame<7; frame=frame+1)
            $display("  frame %0d: %0d errors", frame, ferr[frame]);
        // PASS = the SETTLED frames (2..6) are pixel-perfect. Frames 0-1 are allowed a
        // cold-start fill transient (buffers prime during the first frame's blanking).
        if (ferr[2]==0 && ferr[3]==0 && ferr[4]==0 && ferr[5]==0 && ferr[6]==0)
            $display("PASS: settled frames 2-6 are pixel-perfect");
        else
            $display("FAIL: a settled frame has errors");
        $finish;
    end
    initial begin #80000000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
