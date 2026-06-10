// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - vendor wrapper: async (dual-clock) FIFO.
// Roadmap: Phase 5/7/10 (RX->processing, DDR3 CDC, audio CDC).
// Replaces MiSTer fifo_vga.v / fifo_sound.v. Spec section 6.3.
//
// STUB. Use Gowin's FIFO IP (Async) or a Gray-coded pointer CDC FIFO over
// bram_dp_gowin. TODO: implement Gray pointer CDC + full/empty flags.
`default_nettype none

module async_fifo_gowin #(
    parameter DATA_W = 8,
    parameter ADDR_W = 9
) (
    input  wire              wr_clk,
    input  wire              wr_rst,
    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data,
    output wire              full,

    input  wire              rd_clk,
    input  wire              rd_rst,
    input  wire              rd_en,
    output wire [DATA_W-1:0] rd_data,
    output wire              empty
);
    // TODO: Gray-coded async FIFO over bram_dp_gowin.
    assign full    = 1'b0;
    assign empty   = 1'b1;
    assign rd_data = {DATA_W{1'b0}};
endmodule

`default_nettype wire
