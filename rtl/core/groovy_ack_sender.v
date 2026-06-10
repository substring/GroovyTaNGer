// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - Groovy_MiSTer ACK builder (spec section 5.4, Phase 6/11).
//
// Emits the 13-byte status ACK that the receiver returns after CMD_INIT,
// CMD_GET_STATUS and CMD_BLIT_*. Byte order is little-endian, matching the
// packed struct sent by the x86 host (strict protocol compatibility).
//
//   off 0  : uint32 frame_echo       (echo of BLIT frame#)
//   off 4  : uint16 vsync_echo       (echo of BLIT vSync)
//   off 6  : uint32 fpga_vga_frame   (FPGA frame counter)
//   off 10 : uint16 fpga_vga_vcount  (current raster line)
//   off 12 : uint8  status_bits      (see spec section 5.4 bitfield)
//
// Streams one byte per accepted cycle on a valid/ready handshake into the UDP
// TX builder (rtl/generic/ethernet/eth_udp_tx.v).
`default_nettype none

module groovy_ack_sender (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,            // pulse: capture inputs and begin
    input  wire [31:0] frame_echo,
    input  wire [15:0] vsync_echo,
    input  wire [31:0] fpga_vga_frame,
    input  wire [15:0] fpga_vga_vcount,
    input  wire [7:0]  status_bits,

    output reg         out_valid,
    output reg  [7:0]  out_data,
    output reg         out_last,         // high with the 13th byte
    input  wire        out_ready,
    output wire        busy
);
    localparam N = 13;

    reg [7:0] b [0:N-1];
    reg [3:0] idx;
    reg       sending;

    assign busy = sending;

    always @(posedge clk) begin
        if (rst) begin
            sending   <= 1'b0;
            idx       <= 4'd0;
            out_valid <= 1'b0;
            out_last  <= 1'b0;
        end else begin
            if (start && !sending) begin
                // little-endian field packing
                b[0]  <= frame_echo[7:0];
                b[1]  <= frame_echo[15:8];
                b[2]  <= frame_echo[23:16];
                b[3]  <= frame_echo[31:24];
                b[4]  <= vsync_echo[7:0];
                b[5]  <= vsync_echo[15:8];
                b[6]  <= fpga_vga_frame[7:0];
                b[7]  <= fpga_vga_frame[15:8];
                b[8]  <= fpga_vga_frame[23:16];
                b[9]  <= fpga_vga_frame[31:24];
                b[10] <= fpga_vga_vcount[7:0];
                b[11] <= fpga_vga_vcount[15:8];
                b[12] <= status_bits;
                idx      <= 4'd0;
                sending  <= 1'b1;
                out_valid<= 1'b1;
                out_data <= frame_echo[7:0];
                out_last <= 1'b0;
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
