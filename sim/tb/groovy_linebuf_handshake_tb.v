// SPDX-License-Identifier: GPL-2.0-or-later
// Handshake tb: connects the REAL groovy_linebuf_reader (SINGLE_WORD=1, the HW
// config) to a CYCLE-ACCURATE behavioral model of the nand2mario ddr3_controller
// rd/busy/data_ready timing (NOT the PHY). Reproduces the HW symptom: the reader
// gets stuck in FWAIT (never sees data_ready) while the controller returns to IDLE.
//
// Controller timing modelled (from ddr3_controller.v IDLE/READ states):
//   - IDLE: when it samples rd|wr high -> busy<=1, leaves IDLE next cycle.
//   - READ: data_ready pulses 1 cycle at cycle 7; busy<=0 + back to IDLE at cycle 8.
//   - A read is ONLY accepted while the model is in IDLE. An rd asserted when the
//     model is NOT in IDLE is IGNORED (mirrors casex {IDLE,...}: if(rd|wr)).
// We also (optionally) inject refresh to occupy IDLE for a few cycles, to probe
// whether the reader's rd lands during a busy window and gets swallowed.
`timescale 1ns/1ps
module groovy_linebuf_handshake_tb;
    localparam W = 16, H = 6, HTOTAL = 60, VTOTAL = 12, LINE_W = 32, LW = 5, AW = 26;

    reg pix_clk=0; always #7 pix_clk=~pix_clk;
    reg pclk=0;    always #5 pclk=~pclk;

    reg pix_rst=1, pclk_rst=1;
    reg run_raster = 0;
    wire [15:0] pix_rgb;

    wire        rd;
    wire [AW-1:0] addr;
    reg         busy=1, data_ready=0;
    wire [15:0] dout;
    wire fetch_active;
    wire [2:0]  dbg_fstate;

    function [15:0] pat; input [25:0] a; pat = a[15:0] + 16'd1; endfunction

    groovy_linebuf_reader #(.LINE_W(LINE_W), .LW_ADDR(LW), .DDR_AW(AW), .SINGLE_WORD(1)) dut (
        .pix_clk(pix_clk), .pix_rst(pix_rst), .h_active(W[15:0]), .v_active(H[15:0]),
        .hcount(hcount), .vcount(vcount), .de(de),
        .line_start(line_start), .frame_start(frame_start), .fetch_fs(fetch_fs),
        .pix_rgb565(pix_rgb),
        .pclk(pclk), .pclk_rst(pclk_rst), .base_addr(26'd0),
        .rd(rd), .addr(addr), .busy(busy), .data_ready(data_ready),
        .dout128(128'd0), .dout(dout),
        .fetch_active(fetch_active),
        .dbg_lbwe(), .dbg_lbdata(), .dbg_fillline(), .dbg_col(),
        .dbg_fstate(dbg_fstate), .dbg_fe(), .dbg_pr(), .dbg_dr());

    // ---- cycle-accurate controller model (mirrors ddr3_controller IDLE/READ/REFRESH) ----
    // cstate: 0=IDLE, 1..8=READ (data_ready@7, busy<=0+IDLE@8), 20..(20+REF_LEN)=REFRESH.
    // busy is REGISTERED: it rises the cycle AFTER a command is accepted (matches the
    // real controller's `busy<=1` in IDLE), so it is still 0 the cycle the command issues.
    localparam C_IDLE=0, C_RD1=1, C_REF=20;
    reg [5:0] cstate = C_IDLE;
    reg [25:0] raddr_l;
    assign dout = pat(raddr_l);
    integer ref_timer = 0;
    localparam REF_PERIOD = 11;    // AGGRESSIVE: fire refresh often to hit the race
    localparam REF_LEN    = 6;

    integer accepted = 0, ignored_rd = 0;
    reg booted_ctl = 0;
    always @(posedge pclk) begin
        data_ready <= 1'b0;
        if (pclk_rst) begin cstate <= C_IDLE; busy <= 1'b1; ref_timer<=0; booted_ctl<=0; end
        else begin
            if (!booted_ctl) begin booted_ctl<=1; busy<=1'b0; cstate<=C_IDLE; end
            else begin
                ref_timer <= ref_timer + 1;
                case (1'b1)
                  (cstate==C_IDLE): begin
                    // RACE: refresh is decided on the arbiter's view of rd = the reader's
                    // REGISTERED output, which is still LOW the cycle the reader commits
                    // (it saw busy==0 and will raise rd next cycle). So a due refresh with
                    // rd-low-this-cycle WINS the IDLE slot; busy rises next cycle; the
                    // reader's rd then lands in REFRESH -> SWALLOWED.
                    // TOP-FIX UNDER TEST: block refresh when the reader is ABOUT to read
                    // (FREAD=fstate 2 with busy low) - it WILL assert rd next cycle.
                    if (ref_timer >= REF_PERIOD && !rd &&
                        !((dbg_fstate==3'd2) && !busy)) begin    // reader_will_read gate
                        cstate <= C_REF; busy <= 1'b1; ref_timer <= 0;
                    end else if (rd) begin
                        raddr_l <= addr; cstate <= C_RD1; busy <= 1'b1; accepted = accepted + 1;
                    end
                  end
                  (cstate>=C_RD1 && cstate<C_REF): begin
                    if (rd) ignored_rd = ignored_rd + 1;   // rd while in READ = swallowed
                    cstate <= cstate + 1'b1;
                    if (cstate == 7) data_ready <= 1'b1;
                    if (cstate == 8) begin busy <= 1'b0; cstate <= C_IDLE; end
                  end
                  (cstate>=C_REF): begin
                    if (rd) ignored_rd = ignored_rd + 1;   // rd while in REFRESH = swallowed
                    cstate <= cstate + 1'b1;
                    if (cstate == C_REF+REF_LEN) begin busy <= 1'b0; cstate <= C_IDLE; end
                  end
                endcase
            end
        end
    end

    // ---- raster: the real video_timing_gen, wired like gwddr3video/gwddr3net_top ----
    // Active video first (vcount 0..H-1), blanking after. frame_start is the registered
    // pulse WITH the first active pixel; fetch_fs is the tops' registered pulse at the
    // start of vertical blanking (vcount == H, hcount == 0). The raster starts at (0,0)
    // when run_raster rises, so frame 0 is a cold start with no vblank pre-fill; `warm` rises
    // at the first fetch_fs.
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

    // track time the reader spends in FWAIT (fstate 3) consecutively
    integer fwait_run = 0, fwait_max = 0;
    always @(posedge pclk) begin
        if (dbg_fstate == 3'd3) begin
            fwait_run = fwait_run + 1;
            if (fwait_run > fwait_max) fwait_max = fwait_run;
        end else fwait_run = 0;
    end

    // INJECT a 1-cycle pclk_rst pulse mid-handshake: pulse pclk_rst for 1 pclk
    // exactly when the reader is in FWAIT (rd already issued, waiting data_ready)
    // and the controller is mid-READ. This mimics fs_edge/frame_start landing
    // between rd and data_ready on HW (the reader resets every frame).
    reg booted = 0, inject_armed = 0, inject_done = 0;
    always @(posedge pclk) begin
        if (!booted) pclk_rst <= 1'b1;          // hold reset until booted
        else if (inject_armed && !inject_done && dbg_fstate==3'd3 && cstate==3) begin
            pclk_rst <= 1'b1; inject_done <= 1'b1;   // 1-cycle mid-handshake reset
        end else pclk_rst <= 1'b0;
    end

    initial begin
        pix_rst=1;
        repeat (6) @(negedge pclk); booted=1; pix_rst=0;
        repeat (6) @(negedge pix_clk);
        run_raster = 1;
        repeat (VTOTAL*HTOTAL) @(negedge pix_clk);  // let one frame fetch normally
        inject_armed = 1;                            // then inject the mid-handshake reset
        repeat (3*VTOTAL*HTOTAL + 100) @(negedge pix_clk);
        run_raster = 0;
        $display("RESULT: accepted=%0d ignored_rd(swallowed)=%0d fwait_max=%0d",
                 accepted, ignored_rd, fwait_max);
        if (ignored_rd > 0)
            $display(">>> BUG REPRODUCED: %0d rd pulses swallowed (reader -> FWAIT, controller ignored rd)", ignored_rd);
        if (fwait_max > 100)
            $display(">>> FWAIT STALL: reader stuck in FWAIT up to %0d cycles (HW saw ~65535)", fwait_max);
        // every frame must be fetched again (fetch_fs restarts it): >= 3 frames of words
        if (ignored_rd == 0 && fwait_max <= 100 && accepted >= 3*W*H)
            $display("PASS: groovy_linebuf_handshake_tb");
        else
            $display("FAIL: groovy_linebuf_handshake_tb");
        $finish;
    end
    initial begin #5000000; $display("timeout"); $finish; end
endmodule
