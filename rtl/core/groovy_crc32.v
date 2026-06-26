// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - streaming CRC-32 (IEEE 802.3, poly 0x04C11DB7), 16 bits/clock.
//
// Purpose: DDR3 round-trip self-verification and (later) network integrity. On an
// FPGA this is fully combinational per word - 1 clock, zero added latency, a few
// dozen LUTs - so it runs in PARALLEL with the read/write datapath at no cycle cost.
//
// Usage: hold `init` high for one cycle to preset the CRC, then pulse `valid` with
// each 16-bit word. `crc` is the running CRC after all valid words. To compare two
// streams (e.g. the write stream vs the DDR3 read-back stream) instantiate twice and
// compare the final `crc` values.
//
// Convention: this is the common Ethernet/zlib CRC-32 *core* update (reflected I/O
// and final XOR are NOT applied here - they don't matter for a self-consistent
// write-vs-read comparison, where both streams use the identical core). If we ever
// need to match a specific host-side CRC-32 (e.g. zlib crc32()), add input bit-
// reflection, output bit-reflection, and the final XOR 0xFFFFFFFF at the boundary.
`default_nettype none

module groovy_crc32 (
    input  wire        clk,
    input  wire        rst,        // sync reset -> CRC = 0xFFFFFFFF
    input  wire        init,       // 1-cycle: preset CRC to 0xFFFFFFFF (start of line)
    input  wire        valid,      // 1 = consume `data` this cycle
    input  wire [15:0] data,       // 16-bit word (one DDR3 word / one pixel RGB565)
    output reg  [31:0] crc,        // running CRC-32 (registered)
    output wire [31:0] crc_next    // combinational CRC AFTER consuming `data` this
                                   // cycle - lets the caller store/compare on the
                                   // SAME cycle as the last word of a line.
);
    // Bit-parallel CRC-32 step for 16 input bits. Derived from the standard
    // serial update crc = (crc<<1) ^ (poly & -(bit ^ crc[31])) applied 16x. We
    // express it as a function of the current crc and the 16 data bits.
    function [31:0] crc32_16;
        input [31:0] c;
        input [15:0] d;
        integer i;
        reg [31:0] cc;
        reg        top;
        begin
            cc = c;
            for (i = 15; i >= 0; i = i - 1) begin
                top = cc[31] ^ d[i];
                cc  = {cc[30:0], 1'b0};
                if (top) cc = cc ^ 32'h04C11DB7;
            end
            crc32_16 = cc;
        end
    endfunction

    assign crc_next = crc32_16(crc, data);

    always @(posedge clk) begin
        if (rst)        crc <= 32'hFFFF_FFFF;
        else if (init)  crc <= 32'hFFFF_FFFF;
        else if (valid) crc <= crc_next;
    end
endmodule

`default_nettype wire
