// SPDX-License-Identifier: GPL-2.0-or-later
// FULL-SCALE reproduction of the 2026-07-18/19 HW puzzle: at REAL geometry (320x240,
// NLINES=32, MARGIN=16, V_REPL=3, real 720p timing, 4096-deep FIFO) with the writer
// paced at the sender's real per-line rate (~69.4us/line, 2 lines/datagram, matching
// tools/gm_test_sender.py's minimal busy-spin sender), does a FIFO overflow occur -
// and if so, at what write_line? HW showed WO=0x41(65) and WO=0x8A(138) at two
// DIFFERENT overall pacing rates (1x and 3x slower) yet BOTH non-zero and each
// individually reproducible across repeats - suggesting a structural cause (a periodic
// interaction between the writer's per-line arrival and the reader's lap-guard/MARGIN
// release), not random network jitter. This tb runs the exact real-world parameters in
// zero-guesswork RTL sim instead of guessing further from HW UART.
`timescale 1ns/1ps
module groovy_lineram_realscale_tb;
    localparam NLINES=32, LINE_W=512, DATA_W=16, LNSEL_W=5, COL_W=9;
    localparam H_REPL=4, H_SH=2, V_REPL=3;
    localparam integer SRC_W=320, SRC_H=240;
    localparam integer OUT_W=SRC_W*H_REPL, OUT_H=SRC_H*V_REPL;
    localparam integer MARGIN=16;

    // clk50m (network/write side) and pix_clk (74.25MHz, real HDMI 720p pixel clock)
    reg wclk=0; always #10.0  wclk=~wclk;    // 50 MHz
    reg pclk=0; always #6.734 pclk=~pclk;    // 74.25 MHz
    reg wrst=1, prst=1;

    function [15:0] pix; input integer l; input integer c;
        pix = ((l*256 + c) & 16'hFFFF) ^ 16'hC33C; endfunction

    reg          in_we=0; reg [15:0] in_data=0;
    wire         fifo_full, fifo_empty, fifo_ovf, mapper_pop;
    wire [15:0]  fifo_head;
    wire [12:0]  fifo_level;
    groovy_sync_fifo #(.DATA_W(DATA_W),.ADDR_W(12)) u_fifo (   // 4096-deep, matches the HW fix
        .clk(wclk),.rst(wrst),
        .wr_en(in_we),.wr_data(in_data),.full(fifo_full),
        .rd_en(mapper_pop),.rd_data(fifo_head),.empty(fifo_empty),.overflow(fifo_ovf),
        .fifo_level(fifo_level));

    wire         we; wire [LNSEL_W-1:0] w_slot; wire [COL_W-1:0] w_col; wire [15:0] w_data;
    wire [15:0]  write_line; wire wr_stall;
    reg  [15:0]  read_line_50=0;
    reg          blit_valid=0;
    wire sl_we; wire [LNSEL_W-1:0] sl_slot; wire [15:0] sl_line;
    wire [LNSEL_W-1:0] target_slot_at_write; wire [12:0] fifo_level_at_write;
    groovy_lineram_wr #(.NLINES(NLINES),.LNSEL_W(LNSEL_W),.COL_W(COL_W),.DATA_W(DATA_W),
                        .MARGIN(MARGIN),.ADDR_W_FIFO(12)) u_wr (
        .clk(wclk),.rst(wrst),.frame_start(blit_valid),
        .in_valid(~fifo_empty),.in_data(fifo_head),.pop(mapper_pop),.native_w(SRC_W[15:0]),
        .fifo_overflow(fifo_ovf),.fifo_level(fifo_level),
        .read_line(read_line_50),.guard_en(hf_50[1]),
        .we(we),.w_slot(w_slot),.w_col(w_col),.w_data(w_data),
        .write_line(write_line),.stall(wr_stall),
        .target_slot_at_write(target_slot_at_write),
        .fifo_level_at_write(fifo_level_at_write),
        .sl_we(sl_we),.sl_slot(sl_slot),.sl_line(sl_line));

    wire [LNSEL_W-1:0] r_slot; wire [COL_W-1:0] r_col; wire [15:0] r_data;
    groovy_lineram #(.NLINES(NLINES),.LINE_W(LINE_W),.DATA_W(DATA_W),
                     .LNSEL_W(LNSEL_W),.COL_W(COL_W)) u_ring (
        .wr_clk(wclk),.we(we),.w_slot(w_slot),.w_col(w_col),.w_data(w_data),
        .rd_clk(pclk),.r_slot(r_slot),.r_col(r_col),.r_data(r_data));

    wire slot_actual_line_valid; wire [15:0] slot_actual_line;
    groovy_slotline_ram #(.NLINES(NLINES),.LNSEL_W(LNSEL_W)) u_slotline (
        .wr_clk(wclk),.we(sl_we),.w_slot(sl_slot),.w_line(sl_line),
        .rd_clk(pclk),.r_slot(r_slot),.r_line(slot_actual_line));

    // ---- real 720p timing (matches gwline_top.sv's video_timing_gen instantiation) ----
    wire [15:0] hcount, vcount; wire de, hs, vs, line_start, vframe_start;
    video_timing_gen u_timing (
        .clk(pclk), .rst(prst), .en(1'b1),
        .h_total(16'd1650), .h_active(OUT_W[15:0]), .h_sync_begin(16'd1390), .h_sync_end(16'd1430),
        .v_total(16'd750),  .v_active(OUT_H[15:0]), .v_sync_begin(16'd725),  .v_sync_end(16'd730),
        .h_sync_pos(1'b1), .v_sync_pos(1'b1),
        .hcount(hcount), .vcount(vcount),
        .hsync(hs), .vsync(vs), .de(de),
        .line_start(line_start), .frame_start(vframe_start));

    wire [15:0] pix_out; wire de_o, hs_o, vs_o; wire [15:0] scan_srcline, scan_readguard;
    reg [15:0] wline_px=0;
    always @(posedge pclk) wline_px <= write_line;

    // SYNC/FILL two-stage gate (2026-07-19 fix, matches gwline_top.sv): wait for BOTH the
    // fill threshold AND the next real vframe_start pulse after it, so disp_line's own
    // reset-to-0 (which happens exactly at frame_start) is what read_line starts from -
    // not whatever arbitrary position the free-running raster happens to be at when the
    // fill threshold is crossed.
    reg primed=0;
    always @(posedge pclk or posedge prst)
        if (prst) primed <= 1'b0;
        else if (wline_px >= MARGIN[15:0]) primed <= 1'b1;
    reg have_frame=0;
    always @(posedge pclk or posedge prst)
        if (prst) have_frame <= 1'b0;
        else if (primed && vframe_start) have_frame <= 1'b1;

    // CDC blit_valid -> pix_clk as a net_frame_start pulse (matches the 2026-07-18 fix)
    reg blit_valid_tgl=0;
    always @(posedge wclk or posedge wrst)
        if (wrst) blit_valid_tgl <= 1'b0;
        else if (blit_valid) blit_valid_tgl <= ~blit_valid_tgl;
    reg [2:0] blit_valid_tgl_px=0;
    always @(posedge pclk) blit_valid_tgl_px <= {blit_valid_tgl_px[1:0], blit_valid_tgl};
    wire net_frame_start = blit_valid_tgl_px[2] ^ blit_valid_tgl_px[1];

    groovy_lineram_scan #(.NLINES(NLINES),.LINE_W(LINE_W),.DATA_W(DATA_W),
                          .LNSEL_W(LNSEL_W),.COL_W(COL_W),.H_REPL(H_REPL),.H_SH(H_SH),
                          .V_REPL(V_REPL),.SRC_H(SRC_H)) u_scan (
        .pix_clk(pclk),.pix_rst(prst | ~have_frame),
        .hcount(hcount),.vcount(vcount),.de(de),.hsync(hs),.vsync(vs),
        .frame_start(vframe_start | net_frame_start),
        .max_line(wline_px),
        .r_slot(r_slot),.r_col(r_col),.r_data(r_data),
        .slot_actual_line(slot_actual_line),
        .pix_rgb565(pix_out),.de_o(de_o),.hs_o(hs_o),.vs_o(vs_o),
        .src_line(scan_srcline),.read_guard(scan_readguard));

    // CDC read_guard back to clk50m, gated by have_frame (matches top's read_line_50 mux)
    reg [1:0] hf_50=0;
    always @(posedge wclk) begin
        hf_50 <= {hf_50[0], have_frame};
        read_line_50 <= hf_50[1] ? scan_readguard : 16'd0;
    end

    // ---- WRITER: real per-line pacing matching gm_test_sender's minimal sender:
    // ~69.4us/line, 2 lines burst-sent per "datagram" (all pixels of 2 lines back to
    // back), then wait for the rest of the 2-line period - THE EXACT temporal pattern
    // used on HW for this test.
    integer wl, wc;
    real line_period_ns = 69444.0;         // 1/(60*240) in ns
    integer lines_per_dgram = 2;
    localparam integer FRAME_COUNT = 2;
    integer fr;
    real t_next_dgram;
    initial begin
        in_we=0; blit_valid=0;
        repeat(3) @(negedge wclk); wrst=0;
        repeat(3) @(negedge wclk); prst=0;
        for (fr=0; fr<FRAME_COUNT; fr=fr+1) begin
            @(negedge wclk); blit_valid=1; @(negedge wclk); blit_valid=0;
            t_next_dgram = $realtime;
            for (wl=0; wl<SRC_H; wl=wl+lines_per_dgram) begin
                // send lines_per_dgram lines back-to-back (pixels only, no gap)
                for (wc=0; wc<SRC_W*lines_per_dgram; wc=wc+1) begin
                    in_data <= pix(wl + wc/SRC_W, wc%SRC_W); in_we <= 1'b1;
                    @(negedge wclk);
                end
                in_we <= 1'b0;
                t_next_dgram = t_next_dgram + line_period_ns*lines_per_dgram;
                // busy-wait-equivalent: just advance sim time to the target instant
                if ($realtime < t_next_dgram)
                    #(t_next_dgram - $realtime);
            end
            $display("WRITER: frame %0d/%0d sent (paced ~%.1fus/line)", fr+1, FRAME_COUNT, line_period_ns/1000.0);
        end
        $display("WRITER: all %0d frames done", FRAME_COUNT);
    end

    // ---- instrumentation ----
    integer ovf_count = 0;
    reg [15:0] wo_line = 16'hFFFF;
    always @(posedge wclk) begin
        if (blit_valid) wo_line <= 16'hFFFF;
        else if (fifo_ovf) begin
            ovf_count = ovf_count + 1;
            if (ovf_count <= 5)
                $display("  OVF #%0d t=%0t write_line=%0d read_line_50=%0d have_frame=%0d fifo_full=%0d wr_stall=%0d",
                          ovf_count, $time, write_line, read_line_50, have_frame, fifo_full, wr_stall);
            if (wo_line == 16'hFFFF) wo_line <= write_line;
        end
    end

    integer max_wl_this_frame = 0;
    integer frame_num = 0;
    reg [15:0] wl_at_frame_end [0:7];
    reg [15:0] wo_at_frame_end [0:7];
    always @(posedge wclk) begin
        if (blit_valid) begin
            if (frame_num > 0) begin
                wl_at_frame_end[frame_num-1] = max_wl_this_frame;
            end
            frame_num = frame_num + 1;
            max_wl_this_frame = 0;
        end else if (write_line > max_wl_this_frame) begin
            max_wl_this_frame = write_line;
        end
    end

    initial begin
        #(240.0*2*69444.0*(FRAME_COUNT+1));  // generous margin
        wl_at_frame_end[frame_num-1] = max_wl_this_frame;
        $display("=== RESULT ===");
        $display("total overflow count = %0d", ovf_count);
        $display("write_line at FIRST overflow = %0d (0xFFFF=none)", wo_line);
        for (fr=0; fr<FRAME_COUNT; fr=fr+1)
            $display("frame %0d final write_line = %0d/%0d", fr+1, wl_at_frame_end[fr], SRC_H);
        $finish;
    end
endmodule
