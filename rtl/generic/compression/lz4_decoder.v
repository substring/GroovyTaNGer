// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - LZ4 block decoder (generic). Roadmap: Phase 8. Spec sections 4, 6.3.
//
// STUB / PORT TARGET. To be ported ~80% from Psakhis Groovy_MiSTer rtl/lz4.v
// (8 KB window, low-memory variant), replacing its 64-bit RAMs with
// bram_dp_gowin. Strict protocol: must decode exactly the byte stream
// GroovyMAME produces with `mister_compression lz4`.
//
// Input: compressed byte stream (cSize bytes from CMD_BLIT lz4 variant).
// Output: decompressed pixel byte stream into VRAM.
// TODO(Phase8): port token parse (literal length / match length / offset),
// history-window copy via bram_dp_gowin, end-of-block on cSize.
`default_nettype none

module lz4_decoder #(
    parameter WINDOW_LOG = 13   // 8 KB window
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] c_size,        // compressed size (from blit_csize)
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    output wire        in_ready,
    output wire        out_valid,
    output wire [7:0]  out_data,
    output wire        done
);
    // TODO(Phase8): port from psakhis/Groovy_MiSTer rtl/lz4.v.
    assign in_ready=1'b1; assign out_valid=1'b0; assign out_data=8'd0; assign done=1'b0;
endmodule

`default_nettype wire
