// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - QOI-per-line blit receiver: CMD_BLIT payload bytes -> RGB565 pixels.
//
// Sits beside groovy_blit_rx for a session whose CMD_INIT asked for QOI (compression 2,
// docs/qoi_line_format.md). blit_rx still counts the coded bytes (bytes_len = cSize) and
// ends the blit; this block decodes them into the same pixel stream the ring takes from
// blit_rx for raw blits (px_we / px_data, RGB565, one per pixel, in raster order).
//
// The network gives one byte per 4 clk50m cycles with no back-pressure, and the decoder
// can be slower for a moment (a run op gives up to 62 pixels from one byte), so the bytes
// go through a FIFO first. A sender pacing lines at the raster's line times keeps it
// almost empty (a 640-px line decodes in at most ~640 + bytes cycles, against 3180
// cycles per 15 kHz line); 2^FIFO_LOG bytes hold a whole 1472-byte datagram of lines
// that each decode slowly. A byte that does not fit is dropped (`ovf` pulse): the
// line framing is then lost until the next blit, which resets the decoder and the FIFO.
//
// start (CMD_BLIT) resets both, so a lost datagram (blit_rx timeout) costs one frame.
// The ring writer never waits, so the decoder's output is always ready.
`default_nettype none

module groovy_qoi_rx #(
    parameter integer FIFO_LOG = 11              // 2048 bytes: one BSRAM
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,                    // pulse: CMD_BLIT header (new frame)
    input  wire        fmt565,                   // 1 = RGB565, 0 = RGB888 (CMD_INIT)
    input  wire [15:0] width,                    // pixels per line (CMD_SWITCHRES)

    input  wire        in_valid,                 // a coded byte of the blit payload
    input  wire [7:0]  in_data,

    output reg         px_we,                    // one decoded pixel
    output reg  [15:0] px_data,                  // RGB565
    output reg         line_bad,                 // pulse: a corrupted line was received
    output reg         ovf                       // pulse: a byte was dropped (FIFO full)
);
    wire dec_rst = rst | start;

    // ---- byte FIFO, synchronous read (block RAM), first-word-fall-through via `hv`
    localparam integer DEPTH = 1 << FIFO_LOG;
    localparam [FIFO_LOG:0] DEPTH_V = DEPTH;
    reg  [7:0]          mem [0:DEPTH-1];
    reg  [FIFO_LOG:0]   wp, rp;
    reg  [7:0]          rd_q;                    // mem[rp - 1], read last cycle
    reg                 hv;                      // rd_q holds a byte not yet taken
    wire                full  = (wp - rp) == DEPTH_V;
    wire                empty = (wp == rp);
    wire                d_ready;
    wire                pop   = !empty && (!hv || d_ready);

    always @(posedge clk) begin
        ovf <= 1'b0;
        if (in_valid && !full) mem[wp[FIFO_LOG-1:0]] <= in_data;
        if (pop) rd_q <= mem[rp[FIFO_LOG-1:0]];
        if (dec_rst) begin
            wp <= {(FIFO_LOG+1){1'b0}};  rp <= {(FIFO_LOG+1){1'b0}};  hv <= 1'b0;
        end else begin
            if (in_valid) begin
                if (full) ovf <= 1'b1;
                else      wp <= wp + 1'b1;
            end
            if (pop) begin rp <= rp + 1'b1;  hv <= 1'b1; end
            else if (hv && d_ready) hv <= 1'b0;
        end
    end

    // ---- decoder
    wire        o_valid, o_last, o_err, l_end, l_err;
    wire [23:0] o_data;
    qoi_line_decoder u_dec (
        .clk(clk), .rst(dec_rst), .fmt565(fmt565), .width(width),
        .in_valid(hv), .in_data(rd_q), .in_ready(d_ready),
        .out_valid(o_valid), .out_data(o_data), .out_last(o_last), .out_err(o_err),
        .out_ready(1'b1), .line_end(l_end), .line_err(l_err), .idle());

    // ---- RGB565 for the ring ({r8, g8, b8} truncated, as blit_rx packs RGB888)
    always @(posedge clk) begin
        px_we    <= o_valid && !dec_rst;
        px_data  <= fmt565 ? o_data[15:0] : {o_data[23:19], o_data[15:10], o_data[7:3]};
        line_bad <= l_end && l_err && !dec_rst;
    end
endmodule

`default_nettype wire
