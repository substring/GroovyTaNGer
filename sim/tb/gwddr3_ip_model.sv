// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - behavioural stand-in for the Gowin DDR3 Memory Interface IP (native
// interface, BL8, 128-bit user data) and its memory PLL, so the REAL gwddr3net_top.sv can
// be simulated unmodified. This is NOT the Gowin IP: it models only the user-side
// contract, and it is deliberately instrumented to show how the design USES that
// contract.
//
// What is modelled:
//   - clk_out (75.6 MHz), ddr_rst, init_calib_complete after a short delay.
//   - a command queue and a separate write-data queue (a write command is paired with
//     the next data beat, whichever arrives first), one command executed at a time,
//     RD_LAT / WR_LAT cycles each, rd_data_valid = one pulse per BL8 read.
//   - an internal auto-refresh every REF_PERIOD cycles that takes REF_LEN cycles and
//     drops cmd_ready while it runs - also when the user has just sampled it high.
//   - wr_data_mask: bit = 1 leaves that byte unwritten.
//
// What is NOT known about the real IP (it is encrypted), and is therefore a switch:
//   +STRICT=1  a command / data beat is taken only in a cycle where cmd_ready /
//              wr_data_rdy is high (the textbook reading of the user guide).
//   +STRICT=0  (default) it is also taken one cycle after the ready was high. The
//              HW-proven gwddr3test self-test registers cmd_en one cycle behind
//              cmd_ready and reads back 76800 words clean, so the real IP tolerates at
//              least that.
// Either way `viol_cmd` / `viol_dat` count every strobe presented with its ready low:
// that number is how much the design leans on the IP being tolerant.
`timescale 1ns/1ps
`default_nettype none

module mem_pll (output wire clkout, output reg lock, output wire clkoutd3,
                input wire reset, input wire clkin);
    assign clkout = 1'b0;  assign clkoutd3 = 1'b0;     // the model makes its own clk_out
    initial begin lock = 0; #2000 lock = 1; end
endmodule

module DDR3_Memory_Interface_Top #(
    parameter integer RD_LAT     = 22,     // cmd accepted -> rd_data_valid, cycles
    parameter integer WR_LAT     = 10,
    parameter integer REF_PERIOD = 590,    // tREFI 7.8 us at 75.6 MHz
    parameter integer REF_LEN    = 28,
    parameter integer MEM_AW     = 18      // words modelled (2^18 > 76800)
) (
    input  wire         clk,
    input  wire         memory_clk,
    input  wire         pll_lock,
    input  wire         rst_n,
    output wire         clk_out,
    output reg          ddr_rst,
    output reg          init_calib_complete,
    output wire         cmd_ready,
    input  wire [2:0]   cmd,
    input  wire         cmd_en,
    input  wire [26:0]  addr,
    output wire         wr_data_rdy,
    input  wire [127:0] wr_data,
    input  wire         wr_data_en,
    input  wire         wr_data_end,
    input  wire [15:0]  wr_data_mask,
    output reg  [127:0] rd_data,
    output reg          rd_data_valid,
    output reg          rd_data_end,
    input  wire         sr_req,
    input  wire         ref_req,
    output wire         sr_ack,
    output wire         ref_ack,
    input  wire         burst,
    output wire [12:0]  O_ddr_addr,
    output wire [2:0]   O_ddr_ba,
    output wire         O_ddr_cs_n,
    output wire         O_ddr_ras_n,
    output wire         O_ddr_cas_n,
    output wire         O_ddr_we_n,
    output wire         O_ddr_clk,
    output wire         O_ddr_clk_n,
    output wire         O_ddr_cke,
    output wire         O_ddr_odt,
    output wire         O_ddr_reset_n,
    output wire [1:0]   O_ddr_dqm,
    inout  wire [15:0]  IO_ddr_dq,
    inout  wire [1:0]   IO_ddr_dqs,
    inout  wire [1:0]   IO_ddr_dqs_n
);
    assign {sr_ack, ref_ack} = 2'b00;
    assign O_ddr_addr = 13'd0;  assign O_ddr_ba = 3'd0;
    assign {O_ddr_cs_n, O_ddr_ras_n, O_ddr_cas_n, O_ddr_we_n} = 4'hF;
    assign O_ddr_clk = 1'b0;  assign O_ddr_clk_n = 1'b1;  assign O_ddr_cke = 1'b1;
    assign O_ddr_odt = 1'b0;  assign O_ddr_reset_n = 1'b1;  assign O_ddr_dqm = 2'b00;

    reg c = 0;  always #6.6138 c = ~c;      // 75.6 MHz user clock
    assign clk_out = c;

    integer strict = 0;
    initial void'($value$plusargs("STRICT=%d", strict));

    integer boot = 0;
    always @(posedge c) begin
        if (!rst_n || !pll_lock) begin boot <= 0; ddr_rst <= 1'b1; init_calib_complete <= 1'b0; end
        else begin
            if (boot < 400) boot <= boot + 1;
            ddr_rst <= (boot < 50);
            init_calib_complete <= (boot >= 400);
        end
    end

    // ------------------------------------------------------------------ storage
    reg [15:0] mem [0:(1<<MEM_AW)-1];
    integer mi;
    initial for (mi = 0; mi < (1<<MEM_AW); mi = mi + 1) mem[mi] = 16'hDEAD;

    // ------------------------------------------------------------------ queues
    localparam integer QD = 4;
    reg [2:0]   cq_cmd  [0:QD-1];  reg [26:0] cq_addr [0:QD-1];
    reg [127:0] dq_data [0:QD-1];  reg [15:0] dq_mask [0:QD-1];
    integer cq_n = 0, dq_n = 0, k;

    integer ref_tmr = 0, ref_left = 0;      // refresh timer / cycles left in a refresh
    reg     ref_due = 0;
    integer ex_left = 0;                    // cycles left in the command being executed
    reg [2:0]   ex_cmd;  reg [26:0] ex_addr;  reg ex_busy = 0;

    wire refreshing = (ref_left != 0);
    assign cmd_ready   = init_calib_complete && (cq_n < QD - 1) && !refreshing && !ref_due;
    assign wr_data_rdy = init_calib_complete && (dq_n < QD - 1);
    reg cmd_ready_q = 0, wr_data_rdy_q = 0;

    // ------------------------------------------------------------------ instrumentation
    integer n_rd = 0, n_wr = 0, viol_cmd = 0, viol_dat = 0, lost_cmd = 0, lost_dat = 0;
    reg         ev_wr = 0;                  // one write beat committed this cycle
    reg [26:0]  ev_addr;  reg [127:0] ev_data;  reg [15:0] ev_mask;

    wire take_cmd = cmd_en     && (cmd_ready   || (strict == 0 && cmd_ready_q   && cq_n < QD));
    wire take_dat = wr_data_en && (wr_data_rdy || (strict == 0 && wr_data_rdy_q && dq_n < QD));

    always @(posedge c) begin
        rd_data_valid <= 1'b0;  rd_data_end <= 1'b0;  ev_wr <= 1'b0;
        cmd_ready_q <= cmd_ready;  wr_data_rdy_q <= wr_data_rdy;

        if (!init_calib_complete) begin
            cq_n = 0; dq_n = 0; ex_busy <= 0; ex_left <= 0; ref_tmr <= 0; ref_left <= 0; ref_due <= 0;
        end else begin
            // ---- user strobes ----
            if (cmd_en && !cmd_ready)       viol_cmd = viol_cmd + 1;
            if (wr_data_en && !wr_data_rdy) viol_dat = viol_dat + 1;
            if (cmd_en && !take_cmd)        lost_cmd = lost_cmd + 1;
            if (wr_data_en && !take_dat)    lost_dat = lost_dat + 1;
            if (take_cmd) begin cq_cmd[cq_n] = cmd; cq_addr[cq_n] = addr; cq_n = cq_n + 1; end
            if (take_dat) begin dq_data[dq_n] = wr_data; dq_mask[dq_n] = wr_data_mask; dq_n = dq_n + 1; end

            // ---- refresh timer ----
            if (ref_tmr == REF_PERIOD - 1) begin ref_tmr <= 0; ref_due <= 1'b1; end
            else ref_tmr <= ref_tmr + 1;

            // ---- executor: refresh has priority between commands ----
            if (ref_left != 0) ref_left <= ref_left - 1;
            else if (ex_busy) begin
                if (ex_left != 0) ex_left <= ex_left - 1;
                else begin
                    ex_busy <= 1'b0;
                    if (ex_cmd == 3'd1) begin
                        for (k = 0; k < 8; k = k + 1)
                            rd_data[k*16 +: 16] <= mem[(ex_addr[MEM_AW-1:0] & ~7) + k];
                        rd_data_valid <= 1'b1;  rd_data_end <= 1'b1;  n_rd = n_rd + 1;
                    end
                end
            end else if (ref_due) begin
                ref_due <= 1'b0;  ref_left <= REF_LEN;
            end else if (cq_n != 0 && (cq_cmd[0] != 3'd0 || dq_n != 0)) begin
                ex_cmd <= cq_cmd[0];  ex_addr <= cq_addr[0];  ex_busy <= 1'b1;
                ex_left <= (cq_cmd[0] == 3'd1) ? RD_LAT : WR_LAT;
                if (cq_cmd[0] == 3'd0) begin            // commit the write with its beat
                    for (k = 0; k < 8; k = k + 1) begin
                        if (!dq_mask[0][2*k])   mem[(cq_addr[0][MEM_AW-1:0] & ~7) + k][7:0]  = dq_data[0][k*16 +: 8];
                        if (!dq_mask[0][2*k+1]) mem[(cq_addr[0][MEM_AW-1:0] & ~7) + k][15:8] = dq_data[0][k*16+8 +: 8];
                    end
                    ev_wr <= 1'b1;  ev_addr <= cq_addr[0];  ev_data <= dq_data[0];  ev_mask <= dq_mask[0];
                    n_wr = n_wr + 1;
                    for (k = 0; k < QD - 1; k = k + 1) begin dq_data[k] = dq_data[k+1]; dq_mask[k] = dq_mask[k+1]; end
                    dq_n = dq_n - 1;
                end
                for (k = 0; k < QD - 1; k = k + 1) begin cq_cmd[k] = cq_cmd[k+1]; cq_addr[k] = cq_addr[k+1]; end
                cq_n = cq_n - 1;
            end
        end
    end
endmodule

`default_nettype wire
