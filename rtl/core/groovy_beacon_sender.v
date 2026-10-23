// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - raster beacon (Groovy_Tang protocol extension, CMD_SET_BEACON).
//
// Once the host enables it, the receiver PUSHES one datagram per video frame at the
// start of vertical blanking instead of waiting to be polled. Polling forced the host
// to guess how old each reply was: an ACK left over from a BLIT header (same 13-byte
// format as the status reply) shifted every phase resync by ~1 ms. The arrival time of
// a beacon is a direct raster phase reference (one-way latency ~25 us, nearly constant),
// and it carries the per-frame picture health that otherwise only the debug UART shows.
//
// 16 bytes, little-endian; the magic and the length tell it apart from the 13-byte ACK:
//   off 0  : "GTB1"
//   off 4  : uint32 video_frame   (video frames since reset, wraps)
//   off 8  : uint16 raster_line   (raster source line when the beacon was built)
//   off 10 : uint16 good_lines    (valid output lines of the last complete video frame)
//   off 12 : uint16 lead_top      (writer line when the raster last crossed source line 0)
//   off 14 : uint8  status_bits   (same bits as the ACK)
//   off 15 : uint8  seq           (beacons sent, wraps: the host sees lost beacons)
//
// Same valid/ready byte stream as groovy_ack_sender. A trigger that arrives while the
// previous beacon is still streaming is dropped (and seq does not advance).
`default_nettype none

module groovy_beacon_sender (
    input  wire        clk,
    input  wire        rst,

    input  wire        trigger,          // pulse: capture the fields and send
    input  wire [31:0] video_frame,
    input  wire [15:0] raster_line,
    input  wire [15:0] good_lines,
    input  wire [15:0] lead_top,
    input  wire [7:0]  status_bits,

    output reg         out_valid,
    output reg  [7:0]  out_data,
    output reg         out_last,         // high with the 16th byte
    input  wire        out_ready,
    output wire        busy
);
    localparam N = 16;

    reg [7:0] b [0:N-1];
    reg [3:0] idx;
    reg       sending;
    reg [7:0] seq;

    assign busy = sending;

    always @(posedge clk) begin
        if (rst) begin
            sending   <= 1'b0;
            idx       <= 4'd0;
            seq       <= 8'd0;
            out_valid <= 1'b0;
            out_last  <= 1'b0;
        end else begin
            if (trigger && !sending) begin
                b[0]  <= "G";
                b[1]  <= "T";
                b[2]  <= "B";
                b[3]  <= "1";
                b[4]  <= video_frame[7:0];
                b[5]  <= video_frame[15:8];
                b[6]  <= video_frame[23:16];
                b[7]  <= video_frame[31:24];
                b[8]  <= raster_line[7:0];
                b[9]  <= raster_line[15:8];
                b[10] <= good_lines[7:0];
                b[11] <= good_lines[15:8];
                b[12] <= lead_top[7:0];
                b[13] <= lead_top[15:8];
                b[14] <= status_bits;
                b[15] <= seq;
                seq      <= seq + 8'd1;
                idx      <= 4'd0;
                sending  <= 1'b1;
                out_valid<= 1'b1;
                out_data <= "G";
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
