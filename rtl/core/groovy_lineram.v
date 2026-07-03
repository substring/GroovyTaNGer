// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - beam-race line ring: N-slot dual-clock/dual-port BRAM.
//
// Replaces the DDR3 framebuffer for line streaming. Beam-race only needs the
// write-to-read WORKING SET (a few lines), not a whole frame, so a small BRAM ring
// holds it - and a TRUE DUAL-PORT BRAM means the writer (network, wr_clk) and the
// reader (scanout, rd_clk) access it SIMULTANEOUSLY with NO arbitration. This is
// what removes the DDR3-era writer/reader bus contention (the ~1s crawl) and all the
// DDR3 DQS/byte-lane grief.
//
// Layout: NLINES slots, each LINE_W pixels of DATA_W bits. Source line L lives in
// slot (L mod NLINES) - a ring. The writer fills lines ahead; the reader follows a
// few lines behind (read chases write). LINE_W is the NATIVE line width (the reader
// replicates horizontally on scanout), so it need only cover the widest native line,
// not the super-res'd output width.
//
// This module is JUST the storage (the CDC is the BRAM's two ports). Write/read line
// pointers, the read-behind-write margin, underrun, and mode select live in the top
// and in groovy_writeline - all reused from the HW-proven full/ BRAM beam-race path
// (commit "Rung 5/6: first picture from the PC").
`default_nettype none

module groovy_lineram #(
    parameter integer NLINES  = 8,      // ring depth in lines (jitter tolerance)
    parameter integer LINE_W  = 1024,   // max NATIVE pixels per line
    parameter integer DATA_W  = 16,     // bits per pixel (16=RGB565, 24=RGB888)
    parameter integer LNSEL_W = 3,      // clog2(NLINES)
    parameter integer COL_W   = 10      // clog2(LINE_W)
) (
    // ---- write port (network / clk50m) ----
    input  wire                 wr_clk,
    input  wire                 we,          // 1 per pixel
    input  wire [LNSEL_W-1:0]   w_slot,      // = write_line mod NLINES
    input  wire [COL_W-1:0]     w_col,       // column within the line (0..native_w-1)
    input  wire [DATA_W-1:0]    w_data,

    // ---- read port (scanout / pix_clk) ----
    input  wire                 rd_clk,
    input  wire [LNSEL_W-1:0]   r_slot,      // = read_line mod NLINES
    input  wire [COL_W-1:0]     r_col,
    output reg  [DATA_W-1:0]    r_data
);
    // Flat BRAM: address = {slot, col}. One write clock, one read clock -> the tool
    // infers a true dual-port (semi dual-port) block RAM; write and read never
    // conflict because the reader is always behind the writer by >= 1 line (the top
    // guarantees read_line <= write_line - MARGIN), so they touch different slots.
    localparam integer DEPTH = NLINES * LINE_W;
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    wire [LNSEL_W+COL_W-1:0] waddr = {w_slot, w_col};
    wire [LNSEL_W+COL_W-1:0] raddr = {r_slot, r_col};

    always @(posedge wr_clk) if (we) mem[waddr] <= w_data;
    always @(posedge rd_clk) r_data <= mem[raddr];
endmodule

`default_nettype wire
