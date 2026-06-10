// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - mode-change sequencer (spec section 5.5, Phase 4).
//
// Reproduces in pure FPGA logic the HPS-orchestrated reconfiguration sequence:
//   solve PLL -> wait vblank -> blank pipeline -> load PLL -> wait LOCK
//   -> reload timing counters -> unblank.
// Driven by CMD_SWITCHRES (switchres_valid) and the solver/rPLL handshakes.
`default_nettype none

module groovy_mode_change_fsm (
    input  wire        clk,
    input  wire        rst,

    input  wire        switchres_valid,   // new modeline arrived
    input  wire        in_vblank,         // current timing is in vertical blank

    // PLL solver handshake (groovy_pll_solver)
    output reg         solver_start,
    input  wire        solver_done,
    input  wire        solver_ok,

    // rPLL reconfig handshake (rpll_gowin)
    output reg         pll_load,
    input  wire        pll_lock,

    output reg         video_blank,       // force blanking during the switch
    output reg         timing_load,       // latch new modeline into video_timing_gen
    output reg         ready,             // idle, safe to receive pixels
    output reg         error              // solver could not lock the requested pclk
);
    localparam [2:0]
        S_IDLE       = 3'd0,
        S_SOLVE      = 3'd1,
        S_WAIT_VBLK  = 3'd2,
        S_LOAD_PLL   = 3'd3,
        S_WAIT_LOCK  = 3'd4,
        S_RELOAD     = 3'd5,
        S_UNBLANK    = 3'd6,
        S_ERROR      = 3'd7;

    reg [2:0] state;

    always @(posedge clk) begin
        // default single-cycle strobes
        solver_start <= 1'b0;
        pll_load     <= 1'b0;
        timing_load  <= 1'b0;

        if (rst) begin
            state       <= S_IDLE;
            video_blank <= 1'b0;
            ready       <= 1'b1;
            error       <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    ready <= 1'b1;
                    if (switchres_valid) begin
                        ready        <= 1'b0;
                        error        <= 1'b0;
                        solver_start <= 1'b1;
                        state        <= S_SOLVE;
                    end
                end
                S_SOLVE: begin
                    if (solver_done) begin
                        if (solver_ok) state <= S_WAIT_VBLK;
                        else           state <= S_ERROR;
                    end
                end
                S_WAIT_VBLK: begin
                    if (in_vblank) begin
                        video_blank <= 1'b1;   // blank before touching the PLL
                        state       <= S_LOAD_PLL;
                    end
                end
                S_LOAD_PLL: begin
                    pll_load <= 1'b1;
                    state    <= S_WAIT_LOCK;
                end
                S_WAIT_LOCK: begin
                    if (pll_lock) begin
                        timing_load <= 1'b1;   // load new htotal/vtotal/etc.
                        state       <= S_RELOAD;
                    end
                end
                S_RELOAD: begin
                    state <= S_UNBLANK;
                end
                S_UNBLANK: begin
                    video_blank <= 1'b0;
                    ready       <= 1'b1;
                    state       <= S_IDLE;
                end
                S_ERROR: begin
                    error <= 1'b1;
                    ready <= 1'b1;             // accept a new SWITCHRES to retry
                    if (switchres_valid) begin
                        ready        <= 1'b0;
                        error        <= 1'b0;
                        solver_start <= 1'b1;
                        state        <= S_SOLVE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
