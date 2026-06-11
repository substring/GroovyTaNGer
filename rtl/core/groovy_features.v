// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - CMD_GET_FEATURES reply (protocol v2.0.0 extension).
//
// New, backward-compatible command (a v1.0.0 client never sends it). On `start`
// (driven by groovy_packet_parser.get_features_valid), streams a 12-byte
// self-describing capabilities descriptor over a valid/ready byte interface
// (same handshake as groovy_ack_sender), to be sent back via the UDP TX path.
//
// Reply layout (little-endian), see docs/protocol_v2_features.md:
//   [0..3] magic 'G','T','F','1' (0x47 0x54 0x46 0x31) - identifies this reply
//   [4]    proto_major
//   [5]    proto_minor
//   [6]    proto_patch
//   [7]    compression bitfield: b0 RAW, b1 LZ4, b2 RLE, b3 QOI
//   [8]    rgb_modes  bitfield: b0 RGB888, b1 RGBA888, b2 RGB565
//   [9..11] reserved (0)
//
// The capability fields are PARAMETERS: the integrator (board top) sets them to
// what the FPGA actually implements. Defaults are conservative (RAW only) so we
// never advertise a codec that isn't built — flip bits as each lands.
`default_nettype none

module groovy_features #(
    parameter [7:0] PROTO_MAJOR = 8'd2,
    parameter [7:0] PROTO_MINOR = 8'd0,
    parameter [7:0] PROTO_PATCH = 8'd0,
    // compression: b0 RAW, b1 LZ4, b2 RLE, b3 QOI
    parameter [7:0] COMPRESSION = 8'b0000_0001,   // RAW only by default
    // rgb modes: b0 RGB888, b1 RGBA888, b2 RGB565
    parameter [7:0] RGB_MODES   = 8'b0000_0101    // RGB888 + RGB565
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,        // pulse: begin streaming the descriptor

    output reg         out_valid,
    output reg  [7:0]  out_data,
    output reg         out_last,     // high with the last byte
    input  wire        out_ready,
    output wire        busy
);
    localparam N = 12;

    reg [7:0] b [0:N-1];
    reg [3:0] idx;
    reg       sending;
    integer   k;

    assign busy = sending;

    // static descriptor (function of parameters)
    wire [7:0] desc [0:N-1];
    assign desc[0]  = 8'h47;          // 'G'
    assign desc[1]  = 8'h54;          // 'T'
    assign desc[2]  = 8'h46;          // 'F'
    assign desc[3]  = 8'h31;          // '1'
    assign desc[4]  = PROTO_MAJOR;
    assign desc[5]  = PROTO_MINOR;
    assign desc[6]  = PROTO_PATCH;
    assign desc[7]  = COMPRESSION;
    assign desc[8]  = RGB_MODES;
    assign desc[9]  = 8'd0;
    assign desc[10] = 8'd0;
    assign desc[11] = 8'd0;

    always @(posedge clk) begin
        if (rst) begin
            sending   <= 1'b0;
            idx       <= 4'd0;
            out_valid <= 1'b0;
            out_last  <= 1'b0;
        end else begin
            if (start && !sending) begin
                for (k = 0; k < N; k = k + 1) b[k] <= desc[k];
                idx       <= 4'd0;
                sending   <= 1'b1;
                out_valid <= 1'b1;
                out_data  <= desc[0];
                out_last  <= 1'b0;
            end else if (sending && out_valid && out_ready) begin
                if (idx == N-1) begin
                    sending   <= 1'b0;
                    out_valid <= 1'b0;
                    out_last  <= 1'b0;
                end else begin
                    idx      <= idx + 4'd1;
                    out_data <= b[idx + 4'd1];
                    out_last <= (idx + 4'd1 == N-1);
                end
            end
        end
    end
endmodule

`default_nettype wire
