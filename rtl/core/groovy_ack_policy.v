// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - ACK policy (when and with what to reply). Rung 1. Spec section 5.4.
//
// Encodes the receiver's ACK rules verified in docs/protocol_verified.md
// (groovy.cpp): an ACK is emitted after CMD_INIT, CMD_GET_STATUS and
// CMD_BLIT_FIELD_VSYNC. INIT/GET_STATUS echo (frame,vCount)=(0,0); BLIT echoes
// the blit's frame and vSync. SWITCHRES / AUDIO / CLOSE / GET_VERSION do NOT ACK
// (GET_VERSION has its own 1-byte reply, handled elsewhere).
//
// Drives groovy_ack_sender with the current FPGA raster status latched at the
// moment of the triggering command.
`default_nettype none

module groovy_ack_policy (
    input  wire        clk,
    input  wire        rst,

    // parser command strobes (1 cycle, coincident with cmd_valid)
    input  wire        init_valid,
    input  wire        get_status_valid,
    input  wire        blit_valid,
    input  wire [31:0] blit_frame,
    input  wire [15:0] blit_vsync,

    // live FPGA raster status (sampled at trigger)
    input  wire [31:0] fpga_frame,
    input  wire [15:0] fpga_vcount,
    input  wire [7:0]  status_bits,

    // handshake with groovy_ack_sender
    input  wire        ack_busy,
    output reg         ack_start,
    output reg [31:0]  ack_frame_echo,
    output reg [15:0]  ack_vsync_echo,
    output reg [31:0]  ack_fpga_frame,
    output reg [15:0]  ack_fpga_vcount,
    output reg [7:0]   ack_status
);
    wire trigger = init_valid | get_status_valid | blit_valid;

    always @(posedge clk) begin
        ack_start <= 1'b0;
        if (rst) begin
            // outputs idle
        end else if (trigger && !ack_busy) begin
            ack_start       <= 1'b1;
            ack_frame_echo  <= blit_valid ? blit_frame : 32'd0;
            ack_vsync_echo  <= blit_valid ? blit_vsync : 16'd0;
            ack_fpga_frame  <= fpga_frame;
            ack_fpga_vcount <= fpga_vcount;
            ack_status      <= status_bits;
        end
    end
endmodule

`default_nettype wire
