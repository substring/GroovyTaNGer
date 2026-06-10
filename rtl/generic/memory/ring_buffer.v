// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - frame ring buffer over DDR3 (generic). Roadmap: Phase 7.
// Spec section 6.2. Decouples UDP RX writes from the TMDS read pipeline.
//
// STUB. Manages N fixed-size frame regions in DDR3 (regions partitioned at
// synthesis, no dynamic alloc - spec section 6.1), with produce/consume indices
// and vram_ready / vram_queue status feeding the ACK status_bits.
// TODO(Phase7): region addressing, write/read arbitration to ddr3_gowin, flags.
`default_nettype none

module ring_buffer #(
    parameter NUM_FRAMES = 3,
    parameter ADDR_W     = 25
) (
    input  wire        clk,
    input  wire        rst,
    // producer (RX / LZ4 output)
    input  wire        wr_valid,
    input  wire [7:0]  wr_data,
    input  wire        wr_frame_start,
    input  wire        wr_frame_end,
    // consumer (TMDS pipeline)
    input  wire        rd_req,
    output wire [7:0]  rd_data,
    output wire        rd_valid,
    // status
    output wire        vram_ready,
    output wire [7:0]  queue_depth
);
    assign rd_data=8'd0; assign rd_valid=1'b0;
    assign vram_ready=1'b0; assign queue_depth=8'd0;
endmodule

`default_nettype wire
