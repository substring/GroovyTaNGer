// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - vendor wrapper: Gowin DDR3 memory controller (128 MB on board).
// Roadmap: Phase 7. Spec: section 6.3 (replaces MiSTer ddram.sv).
//
// STUB. Wraps the Gowin DDR3 Memory Interface IP (DDR3_MemoryInterface_Top).
// Presents a simple synchronous read/write port to ring_buffer / VRAM logic.
//
// TODO(Phase7):
//   - Generate the DDR3 controller with Gowin IP wizard for GW2A-LV18 + onboard
//     DDR3 part; import its user interface (cmd/addr/wdata/rdata/valid).
//   - Adapt the simple port below to the controller's native (often DfI-like)
//     handshake, or front it with a small command FIFO.
`default_nettype none

module ddr3_gowin #(
    parameter ADDR_W = 25,           // byte address space (placeholder)
    parameter DATA_W = 128
) (
    input  wire              clk,
    input  wire              rst,
    output wire              init_done,
    // simple user port
    input  wire              cmd_valid,
    input  wire              cmd_we,   // 1=write 0=read
    input  wire [ADDR_W-1:0] cmd_addr,
    input  wire [DATA_W-1:0] wdata,
    output wire              rdata_valid,
    output wire [DATA_W-1:0] rdata
);
    // TODO(Phase7): instantiate real Gowin DDR3 IP.
    assign init_done   = 1'b0;
    assign rdata_valid = 1'b0;
    assign rdata       = {DATA_W{1'b0}};
endmodule

`default_nettype wire
