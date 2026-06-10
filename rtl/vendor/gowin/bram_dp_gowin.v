// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - vendor wrapper: dual-port BRAM.
// Roadmap: used by line buffers, LZ4 window, sound buffer. Spec section 6.2.
//
// This generic-style inference synthesises to Gowin B-SRAM and also simulates,
// so it is the one "vendor" file that is functional today. If timing/packing on
// the GW2A needs the explicit `DPB`/`SDPB` primitive, swap the body for an IP
// instance behind this same port list.
`default_nettype none

module bram_dp_gowin #(
    parameter DATA_W = 8,
    parameter ADDR_W = 10
) (
    input  wire               clk_a,
    input  wire               we_a,
    input  wire [ADDR_W-1:0]  addr_a,
    input  wire [DATA_W-1:0]  din_a,
    output reg  [DATA_W-1:0]  dout_a,

    input  wire               clk_b,
    input  wire               we_b,
    input  wire [ADDR_W-1:0]  addr_b,
    input  wire [DATA_W-1:0]  din_b,
    output reg  [DATA_W-1:0]  dout_b
);
    (* ram_style = "block" *)
    reg [DATA_W-1:0] mem [0:(1<<ADDR_W)-1];

    always @(posedge clk_a) begin
        if (we_a) mem[addr_a] <= din_a;
        dout_a <= mem[addr_a];
    end
    always @(posedge clk_b) begin
        if (we_b) mem[addr_b] <= din_b;
        dout_b <= mem[addr_b];
    end
endmodule

`default_nettype wire
