// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - vendor wrapper: 10:1 TMDS serializer + ELVDS output buffer.
// Roadmap: Phase 2. Spec sections 6.5, 8.
//
// STUB. The real serialization comes from the vendored tangcore hdmi2
// `serializer.sv` (OSER10 in DDR, clk = pixel*5). This wrapper exists only if we
// need a standalone Gowin OSER10/ELVDS_OBUF path outside that module.
//
// TODO(Phase2): if used, instantiate OSER10 (DDR, 10-bit load @ pixel clock,
// shift @ pixel*5) feeding ELVDS_OBUF for the differential TMDS pair. Otherwise
// prefer hdmi2/serializer.sv and delete this wrapper.
`default_nettype none

module tmds_serializer_gowin (
    input  wire        clk_pixel,
    input  wire        clk_pixel_x5,
    input  wire        reset,
    input  wire [9:0]  tmds_data,    // 10-bit encoded symbol
    output wire        tmds_p,
    output wire        tmds_n
);
    // TODO(Phase2): OSER10 + ELVDS_OBUF.
    assign tmds_p = 1'b0;
    assign tmds_n = 1'b1;
endmodule

`default_nettype wire
