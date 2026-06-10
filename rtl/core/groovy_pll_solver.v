// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - Gowin rPLL coefficient solver (spec section 7, Phase 4/7).
//
// Replaces pll.cpp (Cyclone V, HPS) with the bounded hardware search of spec
// section 7 "Option C": constrain IDIV to a small range so the whole space is
// ~44 candidates, evaluated one per clock. Integer math in kHz (no float).
//
//   fout = fref * FBDIV / (IDIV * ODIV)
//   fvco = fref * FBDIV / IDIV               must be in [VCO_MIN, VCO_MAX]
//   FBDIV in [1,64], IDIV in [1,IDIV_MAX], ODIV in the discrete Gowin set.
//
// [A VERIFIER] VCO range / divider limits against Gowin UG290E (spec section 7).
// Defaults below use the spec's working assumptions.
//
// PRECISION NOTE: with a 27 MHz reference and integer IDIV/FBDIV/ODIV, many
// arcade/VGA pixel clocks are only reachable to ~0.1-0.4 MHz (e.g. 25.175 MHz
// -> 25.312, err 137 kHz). The 1 MHz default tolerance reflects that. Exact
// clocks need FRACTIONAL-N (the Gowin rPLL fractional divider, or a different
// reference) - tracked as the V1.x improvement behind spec Q1/Q5. For super-res
// HDMI output a sub-1% pixel-clock error shifts refresh slightly but is fine for
// V1 bring-up (the sink locks to the produced TMDS clock).
`default_nettype none

module groovy_pll_solver #(
    parameter integer FREF_KHZ      = 27000,     // 27 MHz onboard oscillator
    parameter integer VCO_MIN_KHZ   = 400000,
    parameter integer VCO_MAX_KHZ   = 1200000,
    parameter integer IDIV_MAX      = 4,
    parameter integer THRESHOLD_KHZ = 1000       // realistic integer-PLL tolerance
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] fout_khz,        // target pixel clock (kHz)

    output reg         done,            // pulse when search completes
    output reg         busy,
    output reg         ok,              // best error <= THRESHOLD_KHZ
    output reg  [6:0]  idiv,            // 1..IDIV_MAX
    output reg  [6:0]  fbdiv,           // 1..64
    output reg  [7:0]  odiv,            // value from the discrete set
    output reg  [31:0] achieved_khz,
    output reg  [31:0] error_khz
);
    // Discrete Gowin ODIV set (spec section 7)
    localparam integer NODIV = 11;
    reg [7:0] odiv_lut [0:NODIV-1];
    initial begin
        odiv_lut[0]=8'd2;   odiv_lut[1]=8'd4;   odiv_lut[2]=8'd8;
        odiv_lut[3]=8'd16;  odiv_lut[4]=8'd32;  odiv_lut[5]=8'd48;
        odiv_lut[6]=8'd64;  odiv_lut[7]=8'd80;  odiv_lut[8]=8'd96;
        odiv_lut[9]=8'd112; odiv_lut[10]=8'd128;
    end

    // search cursor
    reg [6:0]  cur_idiv;
    reg [3:0]  oidx;
    reg [31:0] best_err;
    reg [6:0]  best_idiv, best_fbdiv;
    reg [7:0]  best_odiv;
    reg [31:0] best_fout;

    // combinational candidate for (cur_idiv, odiv_lut[oidx])
    wire [7:0]  odiv_cur   = odiv_lut[oidx];
    wire [31:0] num        = fout_khz * cur_idiv * odiv_cur;
    wire [31:0] fbdiv_cand = (num + (FREF_KHZ/2)) / FREF_KHZ;          // rounded
    wire [31:0] fvco       = (FREF_KHZ * fbdiv_cand) / cur_idiv;
    wire [31:0] achieved   = (odiv_cur == 0) ? 32'd0 : fvco / odiv_cur;
    wire [31:0] err        = (achieved >= fout_khz) ? (achieved - fout_khz)
                                                    : (fout_khz - achieved);
    wire cand_valid = (fbdiv_cand >= 1) && (fbdiv_cand <= 64) &&
                      (fvco >= VCO_MIN_KHZ) && (fvco <= VCO_MAX_KHZ);

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            ok   <= 1'b0;
        end else if (start && !busy) begin
            busy      <= 1'b1;
            cur_idiv  <= 7'd1;
            oidx      <= 4'd0;
            best_err  <= 32'hFFFFFFFF;
            best_idiv <= 7'd1;
            best_fbdiv<= 7'd1;
            best_odiv <= 8'd2;
            best_fout <= 32'd0;
        end else if (busy) begin
            // evaluate current candidate
            if (cand_valid && (err < best_err)) begin
                best_err   <= err;
                best_idiv  <= cur_idiv;
                best_fbdiv <= fbdiv_cand[6:0];
                best_odiv  <= odiv_cur;
                best_fout  <= achieved;
            end
            // advance cursor
            if (oidx == NODIV-1) begin
                oidx <= 4'd0;
                if (cur_idiv == IDIV_MAX) begin
                    // finished: latch results
                    busy         <= 1'b0;
                    done         <= 1'b1;
                    // include the just-evaluated candidate in the comparison
                    if (cand_valid && (err < best_err)) begin
                        idiv         <= cur_idiv;
                        fbdiv        <= fbdiv_cand[6:0];
                        odiv         <= odiv_cur;
                        achieved_khz <= achieved;
                        error_khz    <= err;
                        ok           <= (err <= THRESHOLD_KHZ);
                    end else begin
                        idiv         <= best_idiv;
                        fbdiv        <= best_fbdiv;
                        odiv         <= best_odiv;
                        achieved_khz <= best_fout;
                        error_khz    <= best_err;
                        ok           <= (best_err <= THRESHOLD_KHZ);
                    end
                end else begin
                    cur_idiv <= cur_idiv + 7'd1;
                end
            end else begin
                oidx <= oidx + 4'd1;
            end
        end
    end
endmodule

`default_nettype wire
