// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - beam-race write-progress tracker (Rung 6).
//
// Watches the blit write stream (one wr_en per pixel, raster order) and counts how
// many native lines are FULLY written: the display may safely read native line L
// once write_line > L. This is the producer side of the beam-race read-chase
// (the consumer compares its display line, vcount>>shift_v, against write_line via
// CDC). Reset/frame_start clears it at the start of each frame.
`default_nettype none

module groovy_writeline #(
    parameter integer LW = 12          // width of the line counter
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,    // pulse: a new frame's blit begins
    input  wire        wr_en,          // one pulse per pixel written
    input  wire [11:0] native_w,       // source width (pixels per line)
    output reg  [LW-1:0] write_line    // count of fully-written native lines
);
    reg [11:0] col;
    always @(posedge clk) begin
        if (rst || frame_start) begin
            col <= 12'd0; write_line <= {LW{1'b0}};
        end else if (wr_en) begin
            if (col == native_w - 12'd1) begin     // last pixel of a line
                col <= 12'd0;
                write_line <= write_line + {{(LW-1){1'b0}},1'b1};
            end else begin
                col <= col + 12'd1;
            end
        end
    end
endmodule

`default_nettype wire
