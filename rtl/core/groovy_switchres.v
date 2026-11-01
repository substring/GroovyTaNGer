// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - SWITCHRES compute + report (Rung 4a).
//
// On CMD_SWITCHRES: pclk(double) -> kHz -> super-res N -> PLL solver, latching
// the result. On a query (CMD_GET_SWITCHRES_RESULT) it streams a 25-byte GTSR
// descriptor so the PC can verify the mode-change math over the network, BEFORE
// we touch the real rPLL (Rung 4b). The latched idiv/fbdiv/odiv also feed that
// future reconfig.
//
// TWO CLOCK DOMAINS:
//   clk      (fast, ~50 MHz) - parser interface + the descriptor streamer.
//   clk_slow (~1 MHz)        - the PLL solver. Its search does several chained
//                              32-bit integer DIVISIONS per cycle, which can't
//                              meet 50 MHz timing (confirmed on hardware: garbage
//                              achieved_khz). The solver runs once per mode change,
//                              so a slow clock is free and gives the dividers time.
// The CMD_SWITCHRES trigger crosses clk->clk_slow via a toggle synchronizer; the
// latched results are stable long before the streamer reads them (no further CDC).
//
// Descriptor (little-endian):
//   [0..3]  'G','T','S','R'   [4..7] pclk_khz   [8] superres_n
//   [9..12] pclk_out_khz   [13] idiv [14] fbdiv [15] odiv
//   [16..19] achieved_khz  [20] ok   [21..22] h_total  [23..24] v_total
`default_nettype none

module groovy_switchres (
    input  wire        clk,        // fast: parser + streamer
    input  wire        clk_slow,   // ~1 MHz: PLL solver
    input  wire        rst,

    input  wire        switchres_valid,
    input  wire [63:0] sr_pclk,
    input  wire [15:0] sr_h_total,
    input  wire [15:0] sr_v_total,

    input  wire        send,
    output reg         out_valid,
    output reg  [7:0]  out_data,
    output reg         out_last,
    input  wire        out_ready,
    output wire        busy,

    output reg         result_valid,   // pulse (clk_slow) when a switch is solved
    output reg  [6:0]  idiv,
    output reg  [6:0]  fbdiv,
    output reg  [7:0]  odiv,
    output reg  [3:0]  superres_n,     // horizontal super-res factor used
    output reg  [31:0] achieved_khz,
    output wire [31:0] target_khz,     // wanted pixel clock = pclk * superres_n
    output reg         ok
);
    // ---- compute chain (combinational on the held sr_pclk) ----
    wire [31:0] pclk_khz_c, pclk_out_c;
    wire [3:0]  n_c;
    pclk_double_to_khz u_dec (.pclk_dbl(sr_pclk), .pclk_khz(pclk_khz_c), .valid());
    superres_factor #(.MIN_KHZ(25000), .MAX_N(6)) u_sr (
        .pclk_src_khz(pclk_khz_c), .n(n_c), .pclk_out_khz(pclk_out_c));

    // ---- CDC: switchres_valid (clk) -> start pulse (clk_slow) ----
    reg sw_tgl;
    always @(posedge clk) if (rst) sw_tgl <= 1'b0; else if (switchres_valid) sw_tgl <= ~sw_tgl;
    reg [2:0] sw_s;
    always @(posedge clk_slow) if (rst) sw_s <= 3'd0; else sw_s <= {sw_s[1:0], sw_tgl};
    wire start_slow = sw_s[2] ^ sw_s[1];

    // ---- PLL solver (slow clock) ----
    // The Gowin rPLL feeds DVI_TX's 5x serial clock (CLKDIV/5 -> pixel), so the
    // solver target is pclk_out * 5. idiv/fbdiv/odiv are the rPLL coefficients;
    // the achieved PIXEL clock = (FREF*fbdiv/idiv) / 5.
    wire [31:0] serial_target = pclk_out_c * 32'd5;
    wire        solver_done, solver_ok;
    wire [6:0]  s_idiv, s_fbdiv;
    wire [7:0]  s_odiv;
    wire [31:0] s_ach;                       // achieved CLKOUT (serial)
    groovy_pll_solver u_solver (
        .clk(clk_slow), .rst(rst), .start(start_slow), .fout_khz(serial_target),
        .done(solver_done), .busy(), .ok(solver_ok),
        .idiv(s_idiv), .fbdiv(s_fbdiv), .odiv(s_odiv),
        .achieved_khz(s_ach), .error_khz());

    // ---- latch modeline-derived values + solver result (clk_slow) ----
    reg [31:0] l_pclk, l_pout;
    reg [3:0]  l_n;
    reg [15:0] l_ht, l_vt;
    assign target_khz = l_pout;
    always @(posedge clk_slow) begin
        result_valid <= 1'b0;
        if (rst) begin
            l_pclk<=0; l_pout<=0; l_n<=0; l_ht<=0; l_vt<=0;
            idiv<=0; fbdiv<=0; odiv<=0; superres_n<=0; achieved_khz<=0; ok<=0;
        end else begin
            if (start_slow) begin
                l_pclk <= pclk_khz_c; l_pout <= pclk_out_c; l_n <= n_c;
                l_ht   <= sr_h_total; l_vt  <= sr_v_total;
            end
            if (solver_done) begin
                idiv <= s_idiv; fbdiv <= s_fbdiv; odiv <= s_odiv;
                superres_n <= l_n;
                achieved_khz <= s_ach / 32'd5;   // report achieved PIXEL clock
                ok <= solver_ok; result_valid <= 1'b1;
            end
        end
    end

    // ---- 25-byte descriptor streamer (clk; reads the stable clk_slow latches) ----
    localparam N = 25;
    reg [7:0] b [0:N-1];
    reg [4:0] idx;
    reg       sending;
    assign busy = sending;

    always @(posedge clk) begin
        if (rst) begin
            sending<=1'b0; idx<=5'd0; out_valid<=1'b0; out_last<=1'b0;
        end else if (send && !sending) begin
            b[0]<=8'h47; b[1]<=8'h54; b[2]<=8'h53; b[3]<=8'h52;          // 'GTSR'
            b[4]<=l_pclk[7:0];  b[5]<=l_pclk[15:8];  b[6]<=l_pclk[23:16];  b[7]<=l_pclk[31:24];
            b[8]<={4'd0,l_n};
            b[9]<=l_pout[7:0];  b[10]<=l_pout[15:8]; b[11]<=l_pout[23:16]; b[12]<=l_pout[31:24];
            b[13]<={1'b0,idiv}; b[14]<={1'b0,fbdiv}; b[15]<=odiv;
            b[16]<=achieved_khz[7:0]; b[17]<=achieved_khz[15:8];
            b[18]<=achieved_khz[23:16]; b[19]<=achieved_khz[31:24];
            b[20]<={7'd0,ok};
            b[21]<=l_ht[7:0]; b[22]<=l_ht[15:8];
            b[23]<=l_vt[7:0]; b[24]<=l_vt[15:8];
            idx<=5'd0; sending<=1'b1; out_valid<=1'b1; out_data<=8'h47; out_last<=1'b0;
        end else if (sending && out_valid && out_ready) begin
            if (idx == N-1) begin
                sending<=1'b0; out_valid<=1'b0; out_last<=1'b0;
            end else begin
                idx<=idx+5'd1; out_data<=b[idx+5'd1]; out_last<=(idx+5'd1==N-1);
            end
        end
    end
endmodule

`default_nettype wire
