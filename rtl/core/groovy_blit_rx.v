// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - BLIT pixel receiver (Rung 5). Strict to the Groovy_MiSTer model.
//
// Reference (github.com/psakhis/Groovy_MiSTer, hps_linux .../groovy.cpp): CMD_BLIT is a header-only
// packet; the pixel data arrives in SEPARATE following datagrams and is
// accumulated by byte count until bytes_recv >= bytes_len (= hactive*vactive*bpp).
// While blitting, datagrams are DATA, not commands. We mirror that exactly: the
// top routes RX bytes here (in_valid) only while blitting; this block assembles
// `bytespp` bytes into a pixel, writes it to VRAM at the running pixel index, and
// pulses frame_done when the whole frame has been received.
//
// Pixels are stored as RGB565 (16-bit) to fit BRAM. bytespp from INIT rgbMode:
//   2 = RGB565 (wire: little-endian, byte0=low)   [first-picture path]
//   3 = RGB888, wire byte order B,G,R -> packed to 565. Checked 2026-10-30: the MiSTer
//       core unpacks {r,g,b} <= word64[23:0] (byte0 = blue, Groovy.sv), and GroovyMAME
//       copies MAME's little-endian ARGB32 bytes 0..2 = B,G,R (drawnogpu.cpp).
// (rgbMode 1 = 4-byte RGBA is a later add.)
//
// TIMEOUT (ROOT-CAUSE FIX, 2026-07-03): a single lost UDP pixel datagram means
// bytes_recv never reaches bytes_len -> blitting would stay 1 FOREVER -> the top
// gates the parser off while blitting -> the next CMD_BLIT header is never seen ->
// permanent freeze (see memory udp-rx-bottleneck). Fix: if blitting is stuck with no
// incoming byte for TIMEOUT_CYCLES, abort the frame and re-arm. A loss then costs one
// frame, not the whole session. TIMEOUT_CYCLES defaults to 1ms @50MHz - far above the
// normal inter-datagram gap (~51us/line at 100Mb/s) but short enough not to hang the
// display for long.
`default_nettype none

module groovy_blit_rx #(
    parameter integer ADDR_W = 17,          // pixels per framebuffer (<=131072)
    parameter integer TIMEOUT_CYCLES = 50000 // ~1ms @ 50MHz: abort a stalled blit
) (
    input  wire                clk,
    input  wire                rst,
    input  wire                start,        // pulse: CMD_BLIT parsed -> begin
    input  wire [31:0]         bytes_len,    // expected total bytes for the frame
    input  wire [2:0]          bytespp,      // 2 or 3
    input  wire                in_valid,     // a pixel byte (gated by top: blitting only)
    input  wire [7:0]          in_data,

    output reg                 blitting,
    output reg                 frame_done,   // 1-cycle pulse at end of frame
    output reg  [31:0]         bytes_recv,
    output reg                 timed_out,    // 1-cycle pulse: aborted on a stalled blit

    output reg                 wr_en,        // 1-cycle per assembled pixel
    output reg  [ADDR_W-1:0]   wr_addr,      // pixel index
    output reg  [15:0]         wr_data       // RGB565
);
    reg [1:0]        bcnt;        // byte within the current pixel (0..bytespp-1)
    reg [7:0]        b0, b1;      // gathered bytes
    reg [ADDR_W-1:0] pix_idx;     // running pixel index
    reg [31:0]       idle_cnt;    // cycles since the last accepted byte, while blitting

    // pack the just-completed pixel to RGB565
    function [15:0] pack565;
        input [2:0] bpp; input [7:0] x0, x1, x2;
    begin
        if (bpp == 3'd2) pack565 = {x1, x0};                       // RGB565 LE
        else             pack565 = {x2[7:3], x1[7:2], x0[7:3]};    // B,G,R -> 565
    end
    endfunction

    // bytes still expected, counted down: the end test compares against a constant
    // instead of a 32-bit add + compare against bytes_len (that carry chain from the
    // frame-size multiplier missed 50 MHz once the size came from CMD_SWITCHRES)
    reg [31:0] remain;

    always @(posedge clk) begin
        wr_en      <= 1'b0;
        frame_done <= 1'b0;
        timed_out  <= 1'b0;
        if (rst) begin
            blitting<=1'b0; bytes_recv<=32'd0; bcnt<=2'd0; pix_idx<={ADDR_W{1'b0}};
            idle_cnt<=32'd0;
        end else if (start) begin
            blitting<=1'b1; bytes_recv<=32'd0; bcnt<=2'd0; pix_idx<={ADDR_W{1'b0}};
            idle_cnt<=32'd0; remain<=bytes_len;
        end else if (blitting && in_valid) begin
            bytes_recv <= bytes_recv + 32'd1;
            remain     <= remain - 32'd1;
            idle_cnt   <= 32'd0;                     // byte arrived: reset the watchdog

            // gather bytes into a pixel
            if (bcnt == 2'd0)      b0 <= in_data;
            else if (bcnt == 2'd1) b1 <= in_data;

            if (bcnt == bytespp - 3'd1) begin       // last byte of this pixel
                bcnt    <= 2'd0;
                wr_en   <= 1'b1;
                wr_addr <= pix_idx;                  // write at current index, then ++
                wr_data <= (bytespp==3'd2) ? pack565(3'd2, b0, in_data, 8'd0)
                                           : pack565(3'd3, b0, b1, in_data);
                pix_idx <= pix_idx + {{(ADDR_W-1){1'b0}},1'b1};
            end else begin
                bcnt <= bcnt + 2'd1;
            end

            // end of frame (count includes this byte)
            if (remain[31:1] == 31'd0) begin        // remain <= 1: this was the last byte
                blitting   <= 1'b0;
                frame_done <= 1'b1;
            end
        end else if (blitting) begin
            // no byte this cycle while still blitting: count idle time, abort on timeout
            if (idle_cnt >= TIMEOUT_CYCLES[31:0]) begin
                blitting  <= 1'b0;                   // re-arm: parser can see the next header
                timed_out <= 1'b1;
            end else begin
                idle_cnt <= idle_cnt + 32'd1;
            end
        end
    end
endmodule

`default_nettype wire
