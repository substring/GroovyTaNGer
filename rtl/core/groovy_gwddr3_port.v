// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - TWO-CLIENT port onto the GOWIN DDR3 Memory Interface IP (native
// interface, BL8 = eight 16-bit words = one 128-bit user beat per command).
//
// One reader (scanout line fetch) and one writer (network fill) share the IP. Each has
// its OWN request latch and its OWN busy, and the arbiter alternates between them one
// transaction at a time.
//
// WHY THIS REPLACES groovy_gwddr3_adapter + the mux in gwddr3net_top (audit 2026-10):
// the two clients used to share one adapter through a combinational mux and one common
// `busy`. A client pulsed its request and took "busy rose" as "my request was
// accepted". While the reader was fetching, the mux silently dropped the writer's
// pulses - and the busy raised by the READER's next read then confirmed them. Every
// beat the writer offered during a line fetch was thrown away with no error anywhere
// (FIFO drop counter 0): patches of the old picture under the new one. Measured in
// sim/tb/gwddr3net_top_e2e_tb.sv before this change: 12 beats of a single static frame
// lost (its tail, the moment the reader started), 105 per 4 streamed frames.
// The reader had priority for a whole line because of a "never write inside a fetch,
// it desyncs the DQS byte lanes" rule; that was a property of the first, untrained
// controller. The Gowin IP sequences and trains the PHY itself; interleaving its
// commands is its normal use.
//
// CLIENT PROTOCOL (the same pulse/busy shape both clients already spoke, but private):
//   pulse rd / wr / wr_beat for one cycle while your busy is low. The request is
//   latched on that edge - it cannot be lost - and your busy is high from the next
//   cycle until it is done (write: handed to the IP; read: data delivered with a
//   one-cycle r_data_ready and all eight words on r_dout128, word k = bits [16k+15:16k]).
//
// IP HANDSHAKE: cmd_en is asserted only in a cycle where cmd_ready is high, and a write
// presents its data beat in that same cycle, so it also requires wr_data_rdy. The
// strobes are combinational from the readies, which is correct whether the IP samples
// "en and ready in the same cycle" or tolerates a late strobe - the encrypted IP does
// not say, and the older registered strobes relied on the tolerant reading. Command and
// data together is the pattern the HW self-test (gwddr3test_top.v, 76800 words clean)
// uses.
`default_nettype none

module groovy_gwddr3_port (
    input  wire         uclk,           // IP user clock (clk_out)
    input  wire         urst,           // IP user reset (ddr_rst, active high)
    input  wire         init_calib_complete,

    // ---- read client: one BL8 beat per request ----
    input  wire         r_rd,           // pulse (only while !r_busy)
    input  wire [25:0]  r_addr,         // word address; the beat containing it is read
    output wire         r_busy,
    output reg          r_data_ready,   // 1 cycle
    output reg  [127:0] r_dout128,

    // ---- write client ----
    input  wire         w_wr,           // pulse: ONE word at w_addr (masked beat)
    input  wire         w_wr_beat,      // pulse: full beat at w_addr (burst aligned)
    input  wire [25:0]  w_addr,
    input  wire [15:0]  w_din,
    input  wire [127:0] w_din_beat,
    output wire         w_busy,

    // ---- Gowin DDR3 IP native side ----
    output wire [2:0]   cmd,            // 0 = write, 1 = read
    output wire         cmd_en,
    input  wire         cmd_ready,
    output wire [26:0]  ip_addr,
    output wire [127:0] wr_data,
    output wire         wr_data_en,
    output wire         wr_data_end,
    output wire [15:0]  wr_data_mask,   // bit = 1: that byte is NOT written
    input  wire         wr_data_rdy,
    input  wire [127:0] rd_data,
    input  wire         rd_data_valid,

    // ---- health (uclk; cumulative, wrap) ----
    output reg  [15:0]  stat_rd,        // read beats delivered
    output reg  [15:0]  stat_wr,        // write beats handed to the IP
    output reg  [15:0]  stat_wait_max   // longest a request waited for the IP, cycles
);
    reg         r_pend, r_fly;          // read: waiting to be issued / issued, data due
    reg [26:0]  r_baddr;
    reg         w_pend;                 // write: waiting to be issued
    reg [26:0]  w_baddr;
    reg [127:0] w_data;
    reg [15:0]  w_mask;
    reg         last_rd;                // last command issued was a read (alternation)
    reg [15:0]  wait_cnt;

    assign r_busy = r_pend | r_fly | ~init_calib_complete;
    assign w_busy = w_pend | ~init_calib_complete;

    wire can_rd = r_pend & cmd_ready;
    wire can_wr = w_pend & cmd_ready & wr_data_rdy;
    wire do_rd  = can_rd & (~can_wr | ~last_rd);
    wire do_wr  = can_wr & ~do_rd;

    assign cmd          = do_rd ? 3'd1 : 3'd0;
    assign cmd_en       = do_rd | do_wr;
    assign ip_addr      = do_rd ? r_baddr : w_baddr;
    assign wr_data      = w_data;
    assign wr_data_mask = w_mask;
    assign wr_data_en   = do_wr;
    assign wr_data_end  = do_wr;

    always @(posedge uclk or posedge urst) begin
        if (urst) begin
            r_pend <= 1'b0; r_fly <= 1'b0; w_pend <= 1'b0; last_rd <= 1'b0;
            r_baddr <= 27'd0; w_baddr <= 27'd0; w_data <= 128'd0; w_mask <= 16'd0;
            r_data_ready <= 1'b0; r_dout128 <= 128'd0;
            stat_rd <= 16'd0; stat_wr <= 16'd0; stat_wait_max <= 16'd0; wait_cnt <= 16'd0;
        end else begin
            r_data_ready <= 1'b0;

            // ---- latch requests (a pulse while busy is a client bug; it is ignored) ----
            if (r_rd && !r_busy) begin
                r_pend  <= 1'b1;
                r_baddr <= {1'b0, r_addr[25:3], 3'b000};
            end
            if (w_wr_beat && !w_busy) begin
                w_pend  <= 1'b1;
                w_baddr <= {1'b0, w_addr[25:3], 3'b000};
                w_data  <= w_din_beat;
                w_mask  <= 16'd0;
            end else if (w_wr && !w_busy) begin
                w_pend  <= 1'b1;
                w_baddr <= {1'b0, w_addr[25:3], 3'b000};
                w_data  <= {8{w_din}};
                w_mask  <= ~(16'h0003 << {w_addr[2:0], 1'b0});
            end

            // ---- issue ----
            if (do_rd) begin r_pend <= 1'b0; r_fly <= 1'b1; last_rd <= 1'b1; end
            if (do_wr) begin w_pend <= 1'b0; last_rd <= 1'b0; stat_wr <= stat_wr + 16'd1; end

            // ---- read data ----
            if (rd_data_valid && r_fly) begin
                r_fly        <= 1'b0;
                r_dout128    <= rd_data;
                r_data_ready <= 1'b1;
                stat_rd      <= stat_rd + 16'd1;
            end

            // ---- how long the IP keeps a request waiting ----
            if (wait_cnt > stat_wait_max) stat_wait_max <= wait_cnt;   // live: a hang shows
            if ((r_pend | w_pend) && !(do_rd | do_wr)) begin
                if (wait_cnt != 16'hFFFF) wait_cnt <= wait_cnt + 16'd1;
            end else wait_cnt <= 16'd0;
        end
    end
endmodule

`default_nettype wire
