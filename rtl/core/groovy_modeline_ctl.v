// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - raster from the CMD_SWITCHRES modeline (gwline VIDEO_MODE 4).
//
// Turns a Groovy_MiSTer modeline (source pixels: hactive/hbegin/hend/htotal, lines:
// vactive/vbegin/vend/vtotal, interlace) plus the PLL solution of groovy_switchres into
// the raster that video_timing_gen_il runs at pix_clk, and sequences the change:
//
//   pix_clk = source pclk * N (super-resolution N = groovy_switchres superres_n, the
//   smallest with pclk * N >= 25 MHz, the HDMI floor). Horizontal values are the
//   modeline's times N, EXCEPT h_total: the integer rPLL misses most pixel clocks by up
//   to ~0.8 % (27 MHz reference, see memory pll-27mhz-precision), so h_total is
//   recomputed on the clock really obtained,
//       h_total = round(htotal * N * achieved / target),
//   which puts the line rate (and the refresh rate GroovyMAME runs the game at) within
//   one pix_clk per line of the modeline (~0.05 %). The picture keeps its N-pixel
//   columns; the difference lands in the back porch.
//   Vertical values are per FIELD when interlaced: vactive/2, vbegin/2, vend/2,
//   vtotal/2 (rounded down: 525 -> 262, the generator adds the top field's extra line).
//
// Two ways to apply, chosen per change:
//   - SAME rPLL coefficients (e.g. 320x240p <-> 320x448i at one pclk): no reset. The
//     shadow registers are updated, then apply_tgl toggles; the pixel domain loads them
//     on its next frame_start and toggles applied_tgl back. The raster never stops, so
//     an HDMI sink does not even resync.
//   - NEW coefficients: pll_hold holds the whole pixel domain in reset (and blanks the
//     output), the rPLL selects change, and the hold lasts SETTLE_CYCLES (the dynamic
//     rPLL's LOCK does not assert, measured on HW, see
//     rtl/board/tang_primer_20k/video/README.md, so this is a fixed delay). The pixel domain reloads the
//     shadows while held.
// A modeline the solver could not reach, or that is not self-consistent, is refused
// (err stays set until the next accepted one); the current raster keeps running.
//
// All outputs are clk-domain registers that only change while the pixel domain is not
// sampling them (in reset, or before an apply toggle it has not seen yet).
`default_nettype none

module groovy_modeline_ctl #(
    // boot raster = gwline VIDEO_MODE 3: 15.734 kHz 240p, 4x 6.75 MHz = 27 MHz
    parameter [15:0] B_HTOT = 16'd1716, B_HACT = 16'd1280, B_HSB = 16'd1360, B_HSE = 16'd1488,
    parameter [15:0] B_VTOT = 16'd262,  B_VACT = 16'd240,  B_VSB = 16'd243,  B_VSE = 16'd246,
    parameter [3:0]  B_REP  = 4'd4,
    parameter [6:0]  B_IDIV = 7'd1, B_FBDIV = 7'd5,
    parameter [7:0]  B_ODIV = 8'd4,
    parameter integer SETTLE_CYCLES = 125_000          // 2.5 ms @ 50 MHz
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        switchres_valid,                 // CMD_SWITCHRES parsed (clk)
    input  wire [15:0] sr_ha, sr_hb, sr_he, sr_ht,
    input  wire [15:0] sr_va, sr_vb, sr_ve, sr_vt,
    input  wire [7:0]  sr_il,

    // groovy_switchres result (its clk_slow domain; the values are held from the pulse on)
    input  wire        clk_slow,
    input  wire        sol_valid,                       // 1-cycle pulse in clk_slow
    input  wire        sol_ok,
    input  wire [6:0]  sol_idiv, sol_fbdiv,
    input  wire [7:0]  sol_odiv,
    input  wire [3:0]  sol_n,
    input  wire [31:0] sol_ach_khz,                     // achieved pixel clock (x N)
    input  wire [31:0] sol_tgt_khz,                     // wanted pixel clock (pclk * N)

    // handshake with the pixel domain
    output reg         apply_tgl,
    input  wire        applied_tgl,                     // from pix_clk (synchronised here)
    output reg         pll_hold,                        // 1: pixel domain held in reset

    // the raster (stable while sampled, see header)
    output reg  [15:0] m_htot, m_hact, m_hsb, m_hse,
    output reg  [15:0] m_vtot, m_vact, m_vsb, m_vse,
    output reg         m_il,
    output reg  [3:0]  m_rep,
    output reg  [6:0]  m_idiv, m_fbdiv,
    output reg  [7:0]  m_odiv,
    output reg         err,
    output reg  [7:0]  n_applied,                       // debug: changes applied (wraps)
    output reg  [7:0]  n_pll                            // debug: of which with a new PLL
);
    // ---- solver pulse clk_slow -> clk (toggle synchroniser)
    reg sv_tgl;
    always @(posedge clk_slow) if (rst) sv_tgl <= 1'b0; else if (sol_valid) sv_tgl <= ~sv_tgl;
    reg [2:0] sv_s;
    always @(posedge clk) sv_s <= {sv_s[1:0], sv_tgl};
    wire sol_pulse = sv_s[2] ^ sv_s[1];

    reg [1:0] ap_s;
    always @(posedge clk) ap_s <= {ap_s[0], applied_tgl};
    wire applied = (ap_s[1] == apply_tgl);              // last apply has been taken

    // ---- the modeline being processed (latched at CMD_SWITCHRES)
    reg [15:0] l_ha, l_hb, l_he, l_ht, l_va, l_vb, l_ve, l_vt;  reg l_il;
    always @(posedge clk)
        if (switchres_valid) begin
            l_ha <= sr_ha; l_hb <= sr_hb; l_he <= sr_he; l_ht <= sr_ht;
            l_va <= sr_va; l_vb <= sr_vb; l_ve <= sr_ve; l_vt <= sr_vt;
            l_il <= (sr_il != 8'd0);
        end

    // ---- next raster, computed from the latches + the solver result
    reg  [3:0]  n;  reg [31:0] ach, tgt;  reg [6:0] c_idiv, c_fbdiv;  reg [7:0] c_odiv;
    wire [19:0] ha_n = l_ha * n, hb_n = l_hb * n, he_n = l_he * n, ht_n = l_ht * n;
    wire sane = (n != 4'd0) && (l_ha != 16'd0) && (l_va != 16'd0) &&
                (l_ha <= l_hb) && (l_hb < l_he) && (l_he <= l_ht) && (ht_n[19:16] == 4'd0) &&
                (l_va <= l_vb) && (l_vb < l_ve) && (l_ve <= l_vt) && (tgt != 32'd0) &&
                (!l_il || l_vt >= 16'd3);

    // h_total = round(ht_n * ach / tgt): 40-bit restoring division, one bit per cycle
    reg  [39:0] dv_num, dv_rem;  reg [39:0] dv_q;  reg [5:0] dv_i;
    wire [40:0] dv_try = {dv_rem[38:0], dv_num[39]} - {9'd0, tgt};

    localparam [2:0] S_IDLE = 3'd0, S_DIV = 3'd1, S_DECIDE = 3'd2, S_WAIT_APPLY = 3'd3,
                     S_HOLD = 3'd4, S_SETTLE = 3'd5;
    reg [2:0]  st;
    reg [31:0] cnt;
    reg [15:0] h_tot;

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE;  apply_tgl <= 1'b0;  pll_hold <= 1'b1;  err <= 1'b0;  cnt <= 32'd0;
            n_applied <= 8'd0;  n_pll <= 8'd0;
            m_htot <= B_HTOT; m_hact <= B_HACT; m_hsb <= B_HSB; m_hse <= B_HSE;
            m_vtot <= B_VTOT; m_vact <= B_VACT; m_vsb <= B_VSB; m_vse <= B_VSE;
            m_il <= 1'b0;  m_rep <= B_REP;
            m_idiv <= B_IDIV;  m_fbdiv <= B_FBDIV;  m_odiv <= B_ODIV;
        end else begin
            case (st)
            S_IDLE: begin
                // the boot hold (pll_hold = 1 out of reset) also needs its settle time
                if (pll_hold) begin cnt <= 32'd0; st <= S_SETTLE; end
                else if (sol_pulse) begin
                    n <= sol_n;  ach <= sol_ach_khz;  tgt <= sol_tgt_khz;
                    c_idiv <= sol_idiv;  c_fbdiv <= sol_fbdiv;  c_odiv <= sol_odiv;
                    if (!sol_ok) err <= 1'b1;
                    else begin
                        // numerator = ht*N*ach + tgt/2 (rounding), set up next cycle
                        dv_i <= 6'd0;  st <= S_DIV;  cnt <= 32'd0;
                    end
                end
            end
            S_DIV: begin
                if (cnt == 32'd0) begin
                    dv_num <= {20'd0, ht_n} * {8'd0, ach} + {9'd0, tgt[31:1]};
                    dv_rem <= 40'd0;  dv_q <= 40'd0;  cnt <= 32'd1;
                end else if (dv_i == 6'd40) begin
                    h_tot <= (dv_q[39:16] != 24'd0) ? 16'hFFFF : dv_q[15:0];
                    st <= S_DECIDE;
                end else begin
                    if (!dv_try[40]) begin dv_rem <= dv_try[39:0]; dv_q <= {dv_q[38:0], 1'b1}; end
                    else begin dv_rem <= {dv_rem[38:0], dv_num[39]}; dv_q <= {dv_q[38:0], 1'b0}; end
                    dv_num <= {dv_num[38:0], 1'b0};
                    dv_i <= dv_i + 6'd1;
                end
            end
            S_DECIDE: begin
                if (!sane) begin err <= 1'b1;  st <= S_IDLE; end
                else if (c_idiv != m_idiv || c_fbdiv != m_fbdiv || c_odiv != m_odiv) begin
                    pll_hold <= 1'b1;  cnt <= 32'd0;  st <= S_HOLD;
                end else st <= S_WAIT_APPLY;
            end
            S_WAIT_APPLY: if (applied) begin      // never touch the shadows mid-sample
                load_next();
                apply_tgl <= ~apply_tgl;
                n_applied <= n_applied + 8'd1;
                st <= S_IDLE;
            end
            S_HOLD: begin                          // pixel domain is in reset from here
                cnt <= cnt + 32'd1;
                if (cnt == 32'd64) begin
                    load_next();
                    m_idiv <= c_idiv;  m_fbdiv <= c_fbdiv;  m_odiv <= c_odiv;
                    n_applied <= n_applied + 8'd1;  n_pll <= n_pll + 8'd1;
                    cnt <= 32'd0;  st <= S_SETTLE;
                end
            end
            S_SETTLE: begin
                cnt <= cnt + 32'd1;
                if (cnt >= SETTLE_CYCLES) begin pll_hold <= 1'b0;  st <= S_IDLE; end
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    // h_total at least one pixel past the end of HSYNC
    wire [15:0] h_tot_ok = (h_tot > he_n[15:0]) ? h_tot : he_n[15:0] + 16'd1;
    task load_next;
    begin
        m_hact <= ha_n[15:0];  m_hsb <= hb_n[15:0];  m_hse <= he_n[15:0];  m_htot <= h_tot_ok;
        m_vact <= l_il ? {1'b0, l_va[15:1]} : l_va;
        m_vsb  <= l_il ? {1'b0, l_vb[15:1]} : l_vb;
        m_vse  <= l_il ? {1'b0, l_ve[15:1]} : l_ve;
        m_vtot <= l_il ? {1'b0, l_vt[15:1]} : l_vt;
        m_il   <= l_il;  m_rep <= n;  err <= 1'b0;
    end
    endtask
endmodule

`default_nettype wire
