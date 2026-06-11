// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - Gowin rPLL coefficient solver (spec section 7; Rung 4b).
//
// Solves for the ACTUAL Gowin GW2A rPLL model (verified against the example
// TMDS_rPLL: 27*(54+1)/(3+1)=371.25 MHz, ODIV=2 -> VCO=742.5):
//   fPFD   = FCLKIN / IDIV                       IDIV  = IDIV_SEL+1   (1..64)
//   CLKOUT = FCLKIN * FBDIV / IDIV               FBDIV = FBDIV_SEL+1  (1..64)
//   fVCO   = CLKOUT * ODIV  in [VCO_MIN,VCO_MAX]  ODIV in the discrete set
// NOTE ODIV does NOT divide CLKOUT - it only places the VCO in range. (The
// previous version used fout=FREF*fbdiv/(idiv*odiv), which was wrong for Gowin.)
//
// Caller passes the desired CLKOUT in `fout_khz`. For DVI/HDMI that is the TMDS
// SERIAL clock = pixel_clock * 5 (a CLKDIV /5 recovers the pixel clock).
//
// Runs on a SLOW clock (groovy_switchres feeds clk_slow ~1 MHz): the integer
// divisions don't meet 50 MHz timing. ~IDIV_MAX cycles, once per mode change.
//
// [A VERIFIER] VCO range and fPFD_min vs Gowin UG290E. Defaults are the working
// assumptions (example fits: VCO 742.5, fPFD 6.75 MHz).
`default_nettype none

module groovy_pll_solver #(
    parameter integer FREF_KHZ      = 27000,     // FCLKIN
    parameter integer VCO_MIN_KHZ   = 400000,
    parameter integer VCO_MAX_KHZ   = 1200000,
    parameter integer PFD_MIN_KHZ   = 3000,      // [VERIFY] min phase-detector freq
    parameter integer IDIV_MAX      = 64,
    parameter integer FBDIV_MAX     = 64,
    parameter integer THRESHOLD_KHZ = 5000       // CLKOUT tolerance (serial domain)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] fout_khz,        // desired CLKOUT (e.g. pixel*5)

    output reg         done,
    output reg         busy,
    output reg         ok,
    output reg  [6:0]  idiv,            // 1..64  (IDIV_SEL = idiv-1)
    output reg  [6:0]  fbdiv,           // 1..64  (FBDIV_SEL = fbdiv-1)
    output reg  [7:0]  odiv,            // value from the discrete set
    output reg  [31:0] achieved_khz,    // achieved CLKOUT
    output reg  [31:0] error_khz
);
    reg  [6:0]  cur_idiv;
    reg  [31:0] best_err;
    reg  [6:0]  best_idiv, best_fbdiv;
    reg  [7:0]  best_odiv;
    reg  [31:0] best_clk;

    // ---- combinational candidate for cur_idiv ----
    wire [31:0] fpfd       = FREF_KHZ / cur_idiv;
    wire [31:0] num        = fout_khz * cur_idiv;
    wire [31:0] fbdiv_cand = (num + (FREF_KHZ/2)) / FREF_KHZ;             // rounded
    wire        fbdiv_ok   = (fbdiv_cand >= 1) && (fbdiv_cand <= FBDIV_MAX);
    wire [6:0]  fbdiv_c    = fbdiv_ok ? fbdiv_cand[6:0] : 7'd1;
    wire [31:0] clkout     = (FREF_KHZ * fbdiv_c) / cur_idiv;

    // smallest ODIV from the discrete Gowin set {2,4,8,16,32,48,64,80,96,112,128}
    // that puts VCO = clkout*ODIV in range (explicit priority - synthesis-clean).
    reg [7:0] odiv_sel;
    always @(*) begin
        if      (clkout*2   >= VCO_MIN_KHZ && clkout*2   <= VCO_MAX_KHZ) odiv_sel = 8'd2;
        else if (clkout*4   >= VCO_MIN_KHZ && clkout*4   <= VCO_MAX_KHZ) odiv_sel = 8'd4;
        else if (clkout*8   >= VCO_MIN_KHZ && clkout*8   <= VCO_MAX_KHZ) odiv_sel = 8'd8;
        else if (clkout*16  >= VCO_MIN_KHZ && clkout*16  <= VCO_MAX_KHZ) odiv_sel = 8'd16;
        else if (clkout*32  >= VCO_MIN_KHZ && clkout*32  <= VCO_MAX_KHZ) odiv_sel = 8'd32;
        else if (clkout*48  >= VCO_MIN_KHZ && clkout*48  <= VCO_MAX_KHZ) odiv_sel = 8'd48;
        else if (clkout*64  >= VCO_MIN_KHZ && clkout*64  <= VCO_MAX_KHZ) odiv_sel = 8'd64;
        else if (clkout*80  >= VCO_MIN_KHZ && clkout*80  <= VCO_MAX_KHZ) odiv_sel = 8'd80;
        else if (clkout*96  >= VCO_MIN_KHZ && clkout*96  <= VCO_MAX_KHZ) odiv_sel = 8'd96;
        else if (clkout*112 >= VCO_MIN_KHZ && clkout*112 <= VCO_MAX_KHZ) odiv_sel = 8'd112;
        else if (clkout*128 >= VCO_MIN_KHZ && clkout*128 <= VCO_MAX_KHZ) odiv_sel = 8'd128;
        else odiv_sel = 8'd0;                    // none valid
    end

    wire        cand_valid = (fpfd >= PFD_MIN_KHZ) && fbdiv_ok && (odiv_sel != 8'd0);
    wire [31:0] err        = (clkout >= fout_khz) ? (clkout - fout_khz)
                                                  : (fout_khz - clkout);

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0; ok <= 1'b0;
        end else if (start && !busy) begin
            busy <= 1'b1; cur_idiv <= 7'd1;
            best_err <= 32'hFFFFFFFF;
            best_idiv <= 7'd1; best_fbdiv <= 7'd1; best_odiv <= 8'd2; best_clk <= 32'd0;
        end else if (busy) begin
            if (cand_valid && (err < best_err)) begin
                best_err <= err; best_idiv <= cur_idiv; best_fbdiv <= fbdiv_c;
                best_odiv <= odiv_sel; best_clk <= clkout;
            end
            if (cur_idiv == IDIV_MAX[6:0]) begin
                busy <= 1'b0; done <= 1'b1;
                if (cand_valid && (err < best_err)) begin   // include the last candidate
                    idiv <= cur_idiv; fbdiv <= fbdiv_c; odiv <= odiv_sel;
                    achieved_khz <= clkout; error_khz <= err;
                    ok <= (err <= THRESHOLD_KHZ);
                end else begin
                    idiv <= best_idiv; fbdiv <= best_fbdiv; odiv <= best_odiv;
                    achieved_khz <= best_clk; error_khz <= best_err;
                    ok <= (best_err <= THRESHOLD_KHZ);
                end
            end else begin
                cur_idiv <= cur_idiv + 7'd1;
            end
        end
    end
endmodule

`default_nettype wire
