// SPDX-License-Identifier: GPL-2.0-or-later
// Beam-race chain tb with a REALISTIC, UNCOOPERATIVE raster: the reader (vcount) is a
// free-running video timing generator that NEVER waits for the writer - exactly like
// real HDMI/CRT hardware, which cannot pause the pixel clock. groovy_lineram_chain_tb
// (the OTHER chain tb) has a raster that explicitly HOLDS at start-of-line until the
// writer is far enough ahead - that cooperative behaviour does not exist on real
// hardware and was masking a bug that only shows up when the reader runs free (matches
// the 2026-07-10 HW observation: line-varying patterns like hbars break, column-varying
// patterns like vertical bars don't - see memory next-session-beamrace).
//
// The writer here also does NOT wait for the reader (models blit_rx: it drains the
// network as fast as datagrams arrive, no host-side per-line handshake in this simple
// model) - it only backs off on the FIFO-full / ring lap-guard, exactly like HW.
//
// Goal: reproduce "only a small window of lines ever gets written / displayed" in
// simulation, where it's cheap to instrument, instead of guessing from HW UART.
`timescale 1ns/1ps
module groovy_lineram_freeraster_tb;
    localparam NLINES=32, LINE_W=64, DATA_W=16, LNSEL_W=5, COL_W=6;
    localparam H_REPL=4, H_SH=2, V_REPL=3;
    localparam integer SRC_W=32, SRC_H=240;              // 240 lines, like the real target
    localparam integer OUT_W=SRC_W*H_REPL, OUT_H=SRC_H*V_REPL;

    reg wclk=0; always #10 wclk=~wclk;   // ~50MHz network/write clock
    reg pclk=0; always #7  pclk=~pclk;   // ~71MHz pixel clock (720p-ish ratio)
    reg wrst=1, prst=1;

    function [15:0] pix; input integer l; input integer c;
        pix = ((l*256 + c) & 16'hFFFF) ^ 16'hC33C; endfunction

    // ---- elastic FIFO (blit_rx -> mapper) ----
    reg          in_we=0; reg [15:0] in_data=0;
    wire         fifo_full, fifo_empty, fifo_ovf, mapper_pop;
    wire [15:0]  fifo_head;
    wire [9:0]   fifo_level;
    groovy_sync_fifo #(.DATA_W(DATA_W),.ADDR_W(9)) u_fifo (
        .clk(wclk),.rst(wrst),
        .wr_en(in_we),.wr_data(in_data),.full(fifo_full),
        .rd_en(mapper_pop),.rd_data(fifo_head),.empty(fifo_empty),.overflow(fifo_ovf),
        .fifo_level(fifo_level));

    // ---- write mapper ----
    wire         we; wire [LNSEL_W-1:0] w_slot; wire [COL_W-1:0] w_col; wire [15:0] w_data;
    wire [15:0]  write_line; wire wr_stall;
    reg  [15:0]  read_line_cdc=0;
    reg          frame_start=0;
    wire sl_we; wire [LNSEL_W-1:0] sl_slot; wire [15:0] sl_line;
    wire [LNSEL_W-1:0] target_slot_at_write; wire [9:0] fifo_level_at_write;
    groovy_lineram_wr #(.NLINES(NLINES),.LNSEL_W(LNSEL_W),.COL_W(COL_W),.DATA_W(DATA_W),
                        .ADDR_W_FIFO(9)) u_wr (
        .clk(wclk),.rst(wrst),.frame_start(frame_start),
        .in_valid(~fifo_empty),.in_data(fifo_head),.pop(mapper_pop),.native_w(SRC_W[15:0]),
        .fifo_overflow(fifo_ovf),.fifo_level(fifo_level),
        .read_line(read_line_cdc),.guard_en(1'b1),
        .target_slot_at_write(target_slot_at_write),
        .fifo_level_at_write(fifo_level_at_write),
        .we(we),.w_slot(w_slot),.w_col(w_col),.w_data(w_data),
        .write_line(write_line),.stall(wr_stall),
        .sl_we(sl_we),.sl_slot(sl_slot),.sl_line(sl_line));

    // ---- ring ----
    wire [LNSEL_W-1:0] r_slot; wire [COL_W-1:0] r_col; wire [15:0] r_data;
    groovy_lineram #(.NLINES(NLINES),.LINE_W(LINE_W),.DATA_W(DATA_W),
                     .LNSEL_W(LNSEL_W),.COL_W(COL_W)) u_ring (
        .wr_clk(wclk),.we(we),.w_slot(w_slot),.w_col(w_col),.w_data(w_data),
        .rd_clk(pclk),.r_slot(r_slot),.r_col(r_col),.r_data(r_data));

    wire slot_actual_line_valid; wire [15:0] slot_actual_line;
    groovy_slotline_ram #(.NLINES(NLINES),.LNSEL_W(LNSEL_W)) u_slotline (
        .wr_clk(wclk),.we(sl_we),.w_slot(sl_slot),.w_line(sl_line),
        .rd_clk(pclk),.r_slot(r_slot),.r_line(slot_actual_line));

    // ---- scan reader ----
    reg [15:0] hcount=0, vcount=0; reg de=0, hs=0, vs=0, sframe=0;
    wire [15:0] pix_out; wire de_o, hs_o, vs_o; wire [15:0] scan_srcline, scan_readguard;
    groovy_lineram_scan #(.NLINES(NLINES),.LINE_W(LINE_W),.DATA_W(DATA_W),
                          .LNSEL_W(LNSEL_W),.COL_W(COL_W),.H_REPL(H_REPL),.H_SH(H_SH),
                          .V_REPL(V_REPL),.SRC_H(SRC_H)) u_scan (
        .pix_clk(pclk),.pix_rst(prst),.hcount(hcount),.vcount(vcount),.de(de),.hsync(hs),.vsync(vs),
        .frame_start(sframe),.max_line(write_line),
        .r_slot(r_slot),.r_col(r_col),.r_data(r_data),
        .slot_actual_line(slot_actual_line),
        .pix_rgb565(pix_out),.de_o(de_o),.hs_o(hs_o),.vs_o(vs_o),
        .src_line(scan_srcline),.read_guard(scan_readguard));

    // CDC read_guard (the CLAMPED line, matches HW's read_line_50 <= read_guard wiring)
    always @(posedge wclk) read_line_cdc <= scan_readguard;

    // ---- WRITER: sends a FULL FRAME in a burst, like a UDP blast, NEVER waiting for
    // the reader (only backs off on FIFO-full or the ring lap-guard - i.e. purely
    // reactive back-pressure, no cooperative pacing). Models blit_rx draining datagrams
    // as fast as they land.
    integer wl, wc;
    integer lines_written = 0;
    // Realistic per-line pacing: at 100Mb/s a 320px RGB565 line (+UDP/IP/eth overhead)
    // takes ~55us on the wire. wclk here is ~50MHz (period 20ns), so ~55us = ~2750
    // wclk cycles per line - insert that gap between lines (not between every pixel;
    // datagrams carry multiple pixels back-to-back). This is MUCH slower than the
    // previous version (3 cycles/pixel, no inter-line gap), which let the writer race
    // far ahead of realism. FRAME_COUNT frames are sent back-to-back via repeated
    // frame_start pulses, like the real host sending one blit per video frame.
    localparam integer LINE_GAP_CYCLES = 2750;
    localparam integer FRAME_COUNT = 4;
    integer fr;
    initial begin
        in_we=0; frame_start=0;
        repeat(3) @(negedge wclk); wrst=0;
        for (fr=0; fr<FRAME_COUNT; fr=fr+1) begin
            @(negedge wclk); frame_start=1; @(negedge wclk); frame_start=0;
            for (wl=0; wl<SRC_H; wl=wl+1) begin
                for (wc=0; wc<SRC_W; wc=wc+1) begin
                    in_data <= pix(wl,wc); in_we <= 1'b1;
                    @(negedge wclk);
                    while (fifo_full) begin in_we <= 1'b0; @(negedge wclk); in_we <= 1'b1; @(negedge wclk); end
                    in_we <= 1'b0; @(negedge wclk);
                end
                lines_written = wl + 1;
                repeat(LINE_GAP_CYCLES) @(negedge wclk);   // realistic inter-line gap
            end
            $display("WRITER: frame %0d/%0d done (attempted %0d lines)", fr+1, FRAME_COUNT, SRC_H);
        end
        in_we<=0;
        $display("WRITER: all %0d frames done", FRAME_COUNT);
    end

    // ---- RASTER: FREE-RUNNING, NEVER HOLDS. This is the realistic HDMI/CRT behaviour -
    // the pixel clock cannot be paused for any reason.
    localparam HTOT=OUT_W+8, VTOT=OUT_H+4;
    reg run=0;
    initial begin repeat(6) @(negedge pclk); prst=0; repeat(2) @(negedge pclk); run=1; end
    always @(posedge pclk) if (run) begin
        if (hcount==HTOT-1) begin
            hcount<=0;
            if (vcount==VTOT-1) vcount<=0;   // loop forever, like real HDMI (no stop)
            else vcount<=vcount+1;
        end else hcount<=hcount+1;
    end
    always @(*) begin
        de = run && (vcount<OUT_H) && (hcount<OUT_W);
        hs = run && (hcount>=OUT_W+2);
        vs = run && (vcount>=OUT_H+1);
    end

    // ---- INSTRUMENTATION: track the HIGHEST write_line ever reached, and whether it
    // ever reaches SRC_H (a full frame actually written), independent of display checks.
    integer max_write_line = 0;
    always @(posedge wclk) if (write_line > max_write_line) max_write_line = write_line;

    // distinct ring slots actually written (bitmap) - reveals "only ~N lines ever land"
    reg [NLINES-1:0] slot_written = 0;
    always @(posedge wclk) if (we) slot_written[w_slot] = 1'b1;

    // Per-frame peak write_line: reset the "max reached this frame" on each frame_start,
    // so we can see if EACH frame reaches SRC_H, or only the first one (matching the HW
    // symptom: RD stuck at 1, WL frozen well under SRC_H on the SECOND+ frame).
    integer max_wl_this_frame = 0;
    integer frame_num = 0;
    always @(posedge wclk) begin
        if (frame_start) begin
            frame_num = frame_num + 1;
            $display("  --- frame_start #%0d at t=%0t, PREVIOUS frame peaked at write_line=%0d/%0d ---",
                      frame_num, $time, max_wl_this_frame, SRC_H);
            max_wl_this_frame = 0;
        end else if (write_line > max_wl_this_frame) begin
            max_wl_this_frame = write_line;
        end
    end

    initial begin
        // enough time for FRAME_COUNT frames at the realistic per-line pacing, plus margin
        #((LINE_GAP_CYCLES+SRC_W*3+50)*20*SRC_H*FRAME_COUNT*3/2);
        $display("=== RESULT ===");
        $display("last frame peaked at write_line=%0d/%0d", max_wl_this_frame, SRC_H);
        $display("max_write_line ever reached = %0d", max_write_line);
        $display("distinct ring slots ever written = %0d / %0d (NLINES)",
                  $countones(slot_written), NLINES);
        $display("fifo overflow ever seen = %0d (count=%0d)", fifo_ovf_seen, ovf_count);
        if (max_wl_this_frame >= SRC_H-1)
            $display("PASS-ish: the LAST frame reached full height");
        else
            $display("REPRODUCED THE BUG: last frame stalled at %0d/%0d with a free raster + multi-frame stream",
                      max_wl_this_frame, SRC_H);
        $finish;
    end
    reg fifo_ovf_seen = 0;
    integer ovf_count = 0;
    always @(posedge wclk) if (fifo_ovf) begin
        fifo_ovf_seen <= 1'b1;
        ovf_count = ovf_count + 1;
        if (ovf_count <= 5)
            $display("  FIFO OVERFLOW #%0d at t=%0t, write_line=%0d, wl(writer idx)=%0d, read_line_cdc=%0d, gap=%0d, stall=%0d, disp_line=%0d, sline_raster=%0d",
                      ovf_count, $time, write_line, wl, read_line_cdc, write_line-read_line_cdc, wr_stall,
                      u_scan.disp_line, u_scan.sline_raster);
    end
    // periodic trace of disp_line vs write_line to see the actual dynamics
    integer trace_n = 0;
    always @(posedge pclk) if (run && hcount==0 && vcount==0) begin
        trace_n = trace_n + 1;
        if (trace_n <= 15)
            $display("  [video loop %0d] t=%0t write_line=%0d disp_line=%0d",
                      trace_n, $time, write_line, u_scan.disp_line);
    end
    // trace write_line stalling: print whenever it stops changing for a while
    integer last_wl_change = 0, prev_write_line = -1;
    always @(posedge wclk) begin
        if (write_line !== prev_write_line) begin
            prev_write_line = write_line;
            last_wl_change = $time;
        end
    end
endmodule
