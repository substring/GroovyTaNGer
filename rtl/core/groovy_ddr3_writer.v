// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - DDR3 write drainer with 8-pixel burst coalescing.
//
// Sits on the DDR3 user/fetch clock (pclk). Pops {addr,data} entries the network
// side pushed into a groovy_async_fifo (RGB565 pixels in STRICT sequential address
// order: 0,1,2,... = y*SRC_W+x). The Gowin DDR3 IP works in BL8 bursts of eight
// 16-bit words; a per-pixel masked write costs ONE full BL8 transaction PER PIXEL
// (8x traffic + a read-modify-write for the mask) - far too slow, it overflowed the
// FIFO (~20k dropped px/frame -> screen-wide flicker).
//
// Fix: COALESCE. Pixels arrive in sequential order, so words 0..7 of a burst share
// addr[25:3] and form one aligned 128-bit beat. We pack eight consecutive pixels and
// issue ONE full, unmasked BL8 write per eight (groovy_gwddr3_adapter.wr_beat). 8x
// fewer DDR3 transactions -> the writer easily outruns the RX burst rate.
//
// FIFO read discipline: groovy_async_fifo is first-word-fall-through but its head
// only advances the cycle AFTER rd_en, and rd_data is valid the cycle after that.
// So we never evaluate the head the same cycle we pop it: GRAB latches the current
// head and pops; SETTLE is a one-cycle bubble for the new head to appear; then we
// process. This removes the pop-latency race (which previously re-saw the same pixel
// and mis-fired the discontinuity path).
//
// Robustness: a non-contiguous address (gap, or a partial final burst that doesn't
// fill all 8 slots) flushes the accumulated words via per-slot masked single-word
// writes (slow path) so no pixel is mis-placed. For 320x240 (76800 = 9600*8) every
// burst is full -> the fast path always runs.
`default_nettype none

module groovy_ddr3_writer #(
    parameter integer AW   = 26,   // DDR3 word-address width (adapter side)
    parameter integer FIFO_AW = 9  // (unused; kept for interface stability)
) (
    input  wire             clk,        // pclk (DDR3 user clock)
    input  wire             rst,        // active-high

    // async FIFO read side (pclk domain): {addr[AW-1:0], data[15:0]}
    input  wire             fifo_empty,
    input  wire [AW+15:0]   fifo_rdata,
    output reg              fifo_rd_en, // 1-cycle pop pulse

    // adapter write port (full-beat fast path + masked single-word slow path)
    output reg              wr,         // single masked word
    output reg              wr_beat,    // full 128-bit beat
    output reg  [AW-1:0]    addr,       // burst-aligned for wr_beat; exact for wr
    output reg  [15:0]      din,        // single-word data (slow path)
    output reg  [127:0]     din_beat,   // packed 8-word beat (fast path)
    input  wire             busy,       // adapter busy (command accepted -> rises)

    output wire             active      // draining (diagnostic / arbitration)
);
    // ---- accumulator: build up to one 128-bit beat ----
    reg [127:0]   acc;          // packed words
    reg [7:0]     acc_mask;     // which of the 8 slots are filled (slot k -> bit k)
    reg [AW-4:0]  acc_burst;    // burst index the acc belongs to
    reg           acc_vld;      // acc holds >=1 word
    reg [2:0]     exp_sel;      // next slot expected (acc fills 0,1,2,... in order)

    // ---- latched FIFO head (captured at GRAB; valid through processing) ----
    reg [AW-1:0]  h_addr;
    reg [15:0]    h_data;
    wire [2:0]    h_sel   = h_addr[2:0];
    wire [AW-4:0] h_burst = h_addr[AW-1:3];

    localparam S_GRAB=3'd0, S_SETTLE=3'd1, S_PROC=3'd2,
               S_BEAT=3'd3, S_FLUSH=3'd4, S_WAIT=3'd5;
    reg [2:0] st = S_GRAB;
    reg [2:0] fl_sel;           // next slot to flush (slow path)

    wire same_burst = acc_vld && (h_burst == acc_burst);

    assign active = acc_vld || (st != S_GRAB);

    // PROVEN issue idiom (from the gwddr3video boot writer, HW-verified): pulse the
    // request for ONE cycle only when the adapter is idle (!busy), then set `pending`
    // and DON'T pulse again until busy has actually risen = the command was accepted.
    // This is robust to the top gating the request off for a cycle: if the pulse was
    // suppressed (busy never rose), `pending` is cleared on a timeout and we re-pulse.
    // (busy rises the cycle AFTER the adapter latches at A_IDLE.)
    reg pending;
    reg [3:0] pend_to;   // timeout: if busy never rises (request was gated), re-issue

    always @(posedge clk) begin
        wr <= 1'b0; wr_beat <= 1'b0; fifo_rd_en <= 1'b0;
        if (rst) begin
            st <= S_GRAB; acc <= 128'd0; acc_mask <= 8'd0; acc_vld <= 1'b0;
            acc_burst <= {(AW-3){1'b0}}; exp_sel <= 3'd0; fl_sel <= 3'd0;
            addr <= {AW{1'b0}}; din <= 16'd0; din_beat <= 128'd0;
            h_addr <= {AW{1'b0}}; h_data <= 16'd0; pending <= 1'b0; pend_to <= 4'd0;
        end else case (st)
            // latch the current FIFO head and pop it; wait one cycle for the next.
            S_GRAB: if (!fifo_empty) begin
                h_addr     <= fifo_rdata[AW+15:16];
                h_data     <= fifo_rdata[15:0];
                fifo_rd_en <= 1'b1;
                st         <= S_SETTLE;
            end
            S_SETTLE: st <= S_PROC;     // bubble: head advances, rd_data settles

            // process the latched head against the accumulator.
            S_PROC: begin
                if (!acc_vld) begin
                    if (h_sel == 3'd0) begin
                        acc <= {112'd0, h_data};
                        acc_mask <= 8'b0000_0001;
                        acc_burst <= h_burst;
                        acc_vld <= 1'b1;
                        exp_sel <= 3'd1;
                        st <= S_GRAB;
                    end else begin
                        // unaligned lone pixel -> masked single-word write
                        addr <= h_addr; din <= h_data; wr <= 1'b1; st <= S_WAIT;
                    end
                end else if (same_burst && h_sel == exp_sel) begin
                    acc[h_sel*16 +: 16] <= h_data;
                    acc_mask <= acc_mask | (8'd1 << h_sel);
                    if (h_sel == 3'd7) st <= S_BEAT;     // beat complete
                    else begin exp_sel <= h_sel + 3'd1; st <= S_GRAB; end
                end else begin
                    // discontinuity: flush the partial acc, THEN this head is retried
                    // (it's still latched in h_*; flush leaves it for the new beat).
                    fl_sel <= 3'd0; st <= S_FLUSH;
                end
            end

            // full beat ready: issue ONE BL8 write via the pending idiom.
            S_BEAT: begin
                addr     <= {acc_burst, 3'b000};
                din_beat <= acc;          // all 8 slots packed (slot 7 set in S_PROC)
                if (!pending && !busy) begin
                    wr_beat <= 1'b1; pending <= 1'b1; pend_to <= 4'd10;   // issue
                end else if (pending && busy) begin
                    pending <= 1'b0;                                       // accepted
                    acc_vld <= 1'b0; acc_mask <= 8'd0; exp_sel <= 3'd0;
                    st <= S_WAIT;
                end else if (pending) begin
                    // request may have been gated off (busy never rose) -> retry on timeout
                    pend_to <= pend_to - 4'd1;
                    if (pend_to == 4'd0) pending <= 1'b0;
                end
            end

            // slow path: flush partial acc as masked single words, slot by slot.
            S_FLUSH: begin
                addr <= {acc_burst, fl_sel};
                din  <= acc[fl_sel*16 +: 16];
                if (acc_mask == 8'd0) begin
                    acc_vld <= 1'b0; exp_sel <= 3'd0; st <= S_PROC;
                end else if (!acc_mask[fl_sel]) begin
                    fl_sel <= fl_sel + 3'd1;                               // skip empty slots
                end else if (!pending && !busy) begin
                    wr <= 1'b1; pending <= 1'b1; pend_to <= 4'd10;         // issue this slot
                end else if (pending && busy) begin
                    pending <= 1'b0; acc_mask[fl_sel] <= 1'b0; st <= S_WAIT;  // accepted
                end else if (pending) begin
                    pend_to <= pend_to - 4'd1;
                    if (pend_to == 4'd0) pending <= 1'b0;                  // gated -> retry
                end
            end

            // wait for the adapter transaction to complete (busy falls), then resume.
            S_WAIT: if (!busy) begin
                st <= (acc_vld && acc_mask != 8'd0) ? S_FLUSH : S_GRAB;
            end
            default: st <= S_GRAB;
        endcase
    end
endmodule

`default_nettype wire
