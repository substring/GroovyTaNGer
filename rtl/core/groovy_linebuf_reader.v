// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - DDR3 -> line-buffer scanout engine (DDR3 step 3).
//
// Bridges the DDR3 controller (pclk domain, ~99.5 MHz) to the video scanout
// (pix_clk domain, up to 74.25 MHz for 720p) via a PING-PONG line buffer in
// BRAM. The pixel clock only ever reads a ONE-LINE BRAM (small/fast), so the
// output resolution is decoupled from the ~40 MHz BRAM-read ceiling that caps a
// full-frame BRAM framebuffer. See docs/ddr3.md.
//
// Architecture:
//   - THREE line buffers, each LINE_W x 16-bit RGB565. While the pixel side
//     reads the displayed line, the DDR3 fetch FSM fills the next lines ahead.
//   - The DDR3 read uses single-word `dout` (SINGLE_WORD=1) - the calibration-
//     proven path; the dout128 burst lane->address mapping proved unreliable.
//   - Address in DDR3 (word space): base + line * h_active + col.
//
// Clock-domain crossing is the line buffer itself: write port on pclk (fetch),
// read port on pix_clk (scanout). The scanout picks the buffer by TAG MATCH
// (which buffer currently holds the line being displayed), so it is robust to
// the fetch/scan phase drifting - it never assumes a fixed buffer = line%3.
`default_nettype none

module groovy_linebuf_reader #(
    parameter integer LINE_W   = 1280,   // max pixels per line (buffer depth)
    parameter integer LW_ADDR  = 11,     // clog2(LINE_W) ; 2^11 = 2048 >= 1280
    parameter integer DDR_AW   = 26,     // DDR3 word-address width
    // SINGLE_WORD=1: read ONE pixel per DDR3 read via `dout` (the calibration-
    // proven single-word path the memtest validated), instead of the 8-word
    // `dout128` burst (whose lane->address mapping proved unreliable on HW).
    parameter integer SINGLE_WORD = 1,
    // Integer nearest-neighbour upscale: the framebuffer is h_active x v_active
    // (SOURCE) and each source pixel is shown H_REPL x V_REPL times to fill the
    // output raster. The 3-buffer fetch/scanout core operates in the SOURCE-line
    // domain: a "source line_start" = every V_REPL-th output line_start. Horizontal
    // repl is just the scanout column index = hcount / H_REPL. H_SH = log2(H_REPL).
    parameter integer H_REPL = 1,
    parameter integer V_REPL = 1,
    parameter integer H_SH   = 0       // log2(H_REPL); 0 -> no horizontal scaling
) (
    // ---- pixel (scanout) domain ----
    input  wire              pix_clk,
    input  wire              pix_rst,      // sync, active high
    input  wire [15:0]       h_active,     // visible pixels per line (runtime)
    input  wire [15:0]       v_active,     // visible lines per frame (runtime)
    input  wire [15:0]       hcount,       // from video_timing_gen
    input  wire [15:0]       vcount,
    input  wire              de,           // data enable (active region)
    input  wire              line_start,   // pulse: first pixel of each line
    input  wire              frame_start,  // pulse: first pixel of each frame
    output reg  [15:0]       pix_rgb565,   // current pixel (valid when de)

    // ---- DDR3 (fetch) domain ----
    input  wire              pclk,
    input  wire              pclk_rst,
    input  wire [DDR_AW-1:0] base_addr,    // word address of frame line 0, col 0
    // simple DDR3 read port (nand2mario controller)
    output reg               rd,           // read-command pulse
    output reg  [DDR_AW-1:0] addr,
    input  wire              busy,         // controller busy (0 = ready)
    input  wire              data_ready,   // read data valid
    input  wire [127:0]      dout128,      // 8 x 16-bit words (burst mode)
    input  wire [15:0]       dout,         // single word (SINGLE_WORD mode)
    output wire              fetch_active, // 1 while a line fetch is in progress
    // light debug taps (single registers): the data written INTO the line buffer
    // (= DDR3 read result), its valid pulse, and which SOURCE line is being filled.
    // Lets the top verify the DDR3 read data BEFORE the scaler.
    output wire              dbg_lbwe,
    output wire [15:0]       dbg_lbdata,
    output wire [15:0]       dbg_fillline,
    output wire [15:0]       dbg_col,
    output wire [2:0]        dbg_fstate,
    output wire [15:0]       dbg_fe,      // fs_edge count (cumulative)
    output wire [15:0]       dbg_pr,      // pclk_rst cycles (cumulative)
    output wire [15:0]       dbg_dr       // data_ready pulses (cumulative)
);
    // THREE line buffers (each a single scanline, LINE_W x 16-bit RGB565).
    reg [15:0] lbuf0 [0:LINE_W-1];
    reg [15:0] lbuf1 [0:LINE_W-1];
    reg [15:0] lbuf2 [0:LINE_W-1];

    // ===================== VERTICAL REPLICATION =========================
    // Only every V_REPL-th output line advances the source line. vrep_cnt counts
    // output lines within a source line; src_de_fell fires on the LAST copy.
    reg       de_q;
    always @(posedge pix_clk) de_q <= de;
    wire de_fell = de_q & ~de;        // entering back porch of the current line

    reg [7:0] vrep_cnt = 8'd0;
    wire      last_rep = (vrep_cnt == V_REPL[7:0] - 8'd1);
    always @(posedge pix_clk) begin
        if (pix_rst || frame_start) vrep_cnt <= 8'd0;
        else if (de_fell)           vrep_cnt <= last_rep ? 8'd0 : vrep_cnt + 8'd1;
    end
    wire src_de_fell = de_fell & last_rep;

    // ===================== SCANOUT (pix_clk) =============================
    // TAG-MATCH buffer selection: pick whichever buffer currently holds the source
    // line being displayed. HW proved a free mod-3 counter wrong (the fetch does
    // NOT stay in a fixed phase with the beam), so we publish a per-buffer line tag
    // and match it. Tags change only once per source line (~66 us) and are double-
    // registered into pix_clk, so the multi-bit CDC is safe (stable for the whole
    // line they label). disp_line = the source line being displayed.
    reg [15:0] disp_line = 16'd0;
    always @(posedge pix_clk) begin
        if (pix_rst || frame_start) disp_line <= 16'd0;
        else if (src_de_fell)       disp_line <= disp_line + 16'd1;
    end

    reg [15:0] bl0_m, bl1_m, bl2_m, bl0_s, bl1_s, bl2_s;
    always @(posedge pix_clk) begin
        bl0_m<=buf_line0; bl1_m<=buf_line1; bl2_m<=buf_line2;
        bl0_s<=bl0_m;     bl1_s<=bl1_m;     bl2_s<=bl2_m;
    end
    wire [15:0] want_line = disp_line;
    wire hit0 = (bl0_s == want_line), hit1 = (bl1_s == want_line), hit2 = (bl2_s == want_line);
    wire        sel_valid = hit0 | hit1 | hit2;
    wire [1:0]  sel_idx   = hit0 ? 2'd0 : hit1 ? 2'd1 : 2'd2;

    // 2-stage read: registered BRAM read off hcount, then a tag-matched 3:1 mux.
    // If no buffer holds the wanted line yet, HOLD the previous output pixel
    // (a brief freeze beats showing the wrong/unfilled buffer).
    wire [15:0] src_col = hcount >> H_SH;
    reg [15:0] q0, q1, q2;
    reg [1:0]  sidx_q; reg svalid_q;
    always @(posedge pix_clk) begin
        q0       <= lbuf0[src_col[LW_ADDR-1:0]];
        q1       <= lbuf1[src_col[LW_ADDR-1:0]];
        q2       <= lbuf2[src_col[LW_ADDR-1:0]];
        sidx_q   <= sel_idx;
        svalid_q <= sel_valid;
    end
    always @(posedge pix_clk)
        if (svalid_q)
            pix_rgb565 <= (sidx_q == 2'd0) ? q0 : (sidx_q == 2'd1) ? q1 : q2;
        // else: hold pix_rgb565 (no buffer ready for this line yet)

    // ===================== FETCH (pclk) =================================
    // frame_start crossed to pclk. RISING-edge-only detector: a both-edge detector
    // fired twice per pulse (a pix_clk pulse is caught in up to 2 pclk samples),
    // resetting the fetch mid-line. Rising-only = exactly one reset per frame.
    // (frame_start itself is REGISTERED in video_timing_gen so it doesn't glitch.)
    reg [3:0] fs_s = 4'd0;
    always @(posedge pclk) fs_s <= {fs_s[2:0], frame_start};
    wire fs_edge = (fs_s[3] == 1'b0) && (fs_s[2] == 1'b1);
    // h_active / v_active crossed to pclk (stable; change only on mode switch)
    reg [15:0] hact_s = 16'd0, vact_s = 16'd0;
    always @(posedge pclk) begin hact_s <= h_active; vact_s <= v_active; end

    localparam FIDLE=3'd0, FSETTLE=3'd1, FREAD=3'd2, FWAIT=3'd3, FDRAIN=3'd4, FDONE=3'd5;
    reg [2:0]  fstate = FIDLE;
    reg [15:0] next_line = 16'd0;   // next frame line to load
    reg [1:0]  fill_idx  = 2'd0;    // buffer to fill (= next_line % 3)
    reg [15:0] col;                 // current column (word index)
    reg [DDR_AW-1:0] line_base;     // base_addr + line*h_active (multiply, once/line)
    reg [DDR_AW-1:0] read_ptr;      // STABLE registered DDR3 read address
    reg [2:0]  sub;                 // which of the 8 latched words to store next
    reg [15:0] wcol;                // write column into the line buffer
    reg [127:0] burst;              // latched dout128 (valid 1 cycle, drained over 8)
    // FWAIT watchdog. ROOT CAUSE of the read-phase stall (HW: reader stuck in FWAIT
    // ~611k cyc/frame, ST=IDLE): the arbiter can inject a refresh in the SAME cycle
    // the reader (seeing !busy) decides to read. Because the reader's `rd` is a
    // REGISTERED output (high one cycle later), the refresh (gated on the still-low
    // r_rd) wins the controller's IDLE slot -> the reader's rd is sampled while the
    // controller is in REFRESH, NOT IDLE -> the read is SWALLOWED -> data_ready never
    // comes -> FWAIT hangs until frame_start resets it. Fix: if data_ready doesn't
    // arrive within WD_MAX cycles (a read is ~9 cyc; refresh+read ~ <40), assume the
    // rd was swallowed and RE-ISSUE the same read_ptr (col not advanced). Self-resyncs.
    localparam [7:0] WD_MAX = 8'd60;
    reg [7:0]  wd;                  // FWAIT watchdog counter

    assign fetch_active = (fstate != FIDLE);

    // Per-buffer line tag: which SOURCE line each buffer holds (FFFF = empty).
    // Published on FDONE; consumed by the scanout tag-match above.
    reg [15:0] buf_line0 = 16'hFFFF, buf_line1 = 16'hFFFF, buf_line2 = 16'hFFFF;

    // line buffer write (pclk side) -> buffer fill_idx
    reg        lb_we;
    reg [15:0] lb_wdata;
    reg [LW_ADDR-1:0] lb_waddr;
    assign dbg_lbwe   = lb_we;
    assign dbg_lbdata = lb_wdata;
    assign dbg_fillline = next_line;
    assign dbg_col      = col;
    assign dbg_fstate   = fstate;

    // cumulative diagnostic counters: fs_edge (fetch resets), pclk_rst, data_ready.
    reg [15:0] fe_c=0, pr_c=0, dr_c=0;
    always @(posedge pclk) begin
        if (fs_edge)    fe_c <= fe_c + 1'b1;
        if (pclk_rst)   pr_c <= pr_c + 1'b1;
        if (data_ready) dr_c <= dr_c + 1'b1;
    end
    assign dbg_fe = fe_c;
    assign dbg_pr = pr_c;
    assign dbg_dr = dr_c;
    always @(posedge pclk) begin
        if (lb_we) begin
            case (fill_idx)
                2'd0: lbuf0[lb_waddr] <= lb_wdata;
                2'd1: lbuf1[lb_waddr] <= lb_wdata;
                default: lbuf2[lb_waddr] <= lb_wdata;
            endcase
        end
    end

    // pick word `sub` (0..7) out of the latched burst (rotation-by-4 lane order,
    // HW-verified). Only used in burst mode (SINGLE_WORD=0).
    wire [2:0]  lane     = sub + 3'd4;
    wire [2:0]  lane_asc = 3'd7 - lane;
    wire [15:0] word_sel = burst[ lane_asc*16 +: 16 ];

    // Credit-based pacing: keep the fetch >=1 and <=LEAD source lines ahead of the
    // beam (3 buffers, LEAD=2 -> the displayed buffer is never overwritten).
    localparam [15:0] LEAD = 16'd2;
    reg [15:0] consumed_pix = 16'd0;
    always @(posedge pix_clk) begin
        if (pix_rst || frame_start) consumed_pix <= 16'd0;
        else if (src_de_fell)       consumed_pix <= consumed_pix + 16'd1;
    end
    reg [15:0] consumed_s = 16'd0;
    always @(posedge pclk) consumed_s <= consumed_pix;   // CDC (slow-moving)

    wire more_lines = (next_line < vact_s);
    wire in_credit  = (next_line <= consumed_s + LEAD);
    wire can_fetch  = more_lines && in_credit;

    always @(posedge pclk) begin
        rd    <= 1'b0;
        lb_we <= 1'b0;

        if (fs_edge) begin
            // new frame: restart from the top, mark all buffers EMPTY.
            next_line <= 16'd0;
            fill_idx  <= 2'd0;
            fstate    <= FIDLE;
            buf_line0 <= 16'hFFFF; buf_line1 <= 16'hFFFF; buf_line2 <= 16'hFFFF;
        end else case (fstate)
            FIDLE: if (can_fetch) begin
                line_base <= base_addr + next_line * hact_s;
                col       <= 16'd0;
                wcol      <= 16'd0;
                fstate    <= FSETTLE;     // let line_base (a multiply) settle 1 cyc
            end

            // FSETTLE: seed read_ptr from line_base. The DDR3 `addr` must be a STABLE
            // REGISTER output, never a fresh combinational sum (a combinational
            // line_base+col into the controller doesn't settle -> byte-lane-skewed
            // reads, HW-confirmed). We pre-register read_ptr and drive `addr` from it.
            FSETTLE: begin read_ptr <= line_base; fstate <= FREAD; end

            FREAD: if (!busy) begin
                rd      <= 1'b1;
                addr    <= read_ptr;           // STABLE registered address
                sub     <= 3'd0;
                wd      <= 8'd0;               // arm the FWAIT watchdog
                fstate  <= FWAIT;
            end

            // SINGLE_WORD: capture `dout`, advance col + the registered read pointer,
            // return to FREAD (gates next read on !busy). This is the known-good cadence
            // that completed full lines on HW before the calibration/1066 changes.
            FWAIT: if (data_ready) begin
                if (SINGLE_WORD != 0) begin
                    lb_we    <= 1'b1;
                    lb_wdata <= dout;
                    lb_waddr <= col[LW_ADDR-1:0];
                    if (col + 16'd1 >= hact_s) begin
                        fstate <= FDONE;
                    end else begin
                        col      <= col + 16'd1;
                        read_ptr <= read_ptr + 1'b1;
                        fstate   <= FREAD;
                    end
                end else begin
                    burst  <= dout128;
                    fstate <= FDRAIN;
                end
            end else begin
                // No data_ready yet: tick the watchdog. If the rd was swallowed (a
                // refresh stole the IDLE slot the same cycle we committed), data_ready
                // never comes. On timeout, go re-issue the SAME read (col unchanged).
                wd <= wd + 8'd1;
                if (wd == WD_MAX) fstate <= FREAD;
            end

            FDRAIN: begin   // burst mode only
                lb_we    <= 1'b1;
                lb_wdata <= word_sel;
                lb_waddr <= wcol[LW_ADDR-1:0];
                wcol     <= wcol + 16'd1;
                if (sub == 3'd7) begin
                    col <= col + 16'd8;
                    read_ptr <= read_ptr + 16'd8;
                    if (col + 16'd8 >= hact_s) fstate <= FDONE;
                    else                       fstate <= FREAD;
                end else sub <= sub + 3'd1;
            end

            // The last word's lb_we is scheduled this edge (uses the CURRENT
            // fill_idx). Only AFTER it commits do we advance fill_idx/next_line.
            FDONE: begin
                case (fill_idx)
                    2'd0: buf_line0 <= next_line;
                    2'd1: buf_line1 <= next_line;
                    default: buf_line2 <= next_line;
                endcase
                next_line <= next_line + 16'd1;
                fill_idx  <= (fill_idx == 2'd2) ? 2'd0 : fill_idx + 2'd1;
                fstate    <= FIDLE;
            end
        endcase

        if (pclk_rst) begin
            fstate <= FIDLE; sub <= 3'd0; rd <= 1'b0; lb_we <= 1'b0;
            next_line <= 16'd0; fill_idx <= 2'd0;
        end
    end
endmodule

`default_nettype wire
