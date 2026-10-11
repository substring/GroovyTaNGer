// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - line-ring writer (see groovy_linering.v for the contract).
//
// Counts the incoming pixel stream into (line, col) and stores every pixel the cycle
// after it arrives - unconditionally. It also maintains the slot tag the reader trusts:
//   0xFFFF  never written since reset
//   0xFFFE  being rewritten (set with the line's FIRST pixel, so a reader that lands on
//           a half-written slot does not show a mix of two lines)
//   L       the slot holds all of source line L (set with the line's LAST pixel)
//
// SLOTS RUN CONTINUOUSLY ACROSS FRAMES: the slot counter advances one per line and is
// NOT reset by frame_start, so the ring always holds exactly the last NLINES lines
// written, whatever the frame height. (With slot = line mod NLINES, a 240-line frame
// wraps onto slots only 240 mod 32 = 16 lines old, halving the ring at every frame
// boundary - measured: host-lead window 10..20 lines instead of 10..30.) frame_base is
// the slot of the current frame's line 0; the reader adds its own line number to it.
`default_nettype none

module groovy_linewr #(
    parameter integer NLINES  = 32,
    parameter integer LNSEL_W = 5,
    parameter integer COL_W   = 9,
    parameter integer DATA_W  = 16
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 frame_start,
    input  wire                 px_we,
    input  wire [DATA_W-1:0]    px_data,
    input  wire [15:0]          native_w,

    output reg                  we,
    output reg  [LNSEL_W-1:0]   w_slot,
    output reg  [COL_W-1:0]     w_col,
    output reg  [DATA_W-1:0]    w_data,

    output reg                  tag_we,
    output reg  [LNSEL_W-1:0]   tag_slot,
    output reg  [15:0]          tag_line,

    output reg  [15:0]          write_line,
    output reg  [LNSEL_W-1:0]   frame_base      // slot holding line 0 of this frame
);
    reg [15:0]      col, line;
    reg [LNSEL_W-1:0] slot;          // free-running: slot of the line being written
    reg             clearing;        // after reset: walk every tag back to 0xFFFF
    reg [LNSEL_W:0] clear_idx;

    wire last_col = (col + 16'd1 >= native_w);

    always @(posedge clk) begin
        we     <= 1'b0;
        tag_we <= 1'b0;

        if (rst) begin
            col <= 16'd0; line <= 16'd0; write_line <= 16'd0;
            slot <= {LNSEL_W{1'b0}}; frame_base <= {LNSEL_W{1'b0}};
            clearing <= 1'b1; clear_idx <= {(LNSEL_W+1){1'b0}};
        end else if (clearing) begin
            tag_we   <= 1'b1;
            tag_slot <= clear_idx[LNSEL_W-1:0];
            tag_line <= 16'hFFFF;
            clear_idx <= clear_idx + 1'b1;
            if (clear_idx == NLINES - 1) clearing <= 1'b0;
        end else if (frame_start) begin
            // Tags are deliberately NOT cleared here: the previous frame's tail is still
            // being scanned out while this frame's head arrives. `slot` keeps running
            // (a frame cut short mid-line simply restarts in the slot it was filling).
            col <= 16'd0; line <= 16'd0; write_line <= 16'd0;
            frame_base <= slot;
        end else if (px_we) begin
            we     <= 1'b1;
            w_slot <= slot;
            w_col  <= col[COL_W-1:0];
            w_data <= px_data;

            if (last_col) begin
                tag_we   <= 1'b1;
                tag_slot <= slot;
                tag_line <= line;
                col        <= 16'd0;
                slot       <= slot + 1'b1;
                line       <= line + 16'd1;
                write_line <= line + 16'd1;
            end else begin
                if (col == 16'd0) begin
                    tag_we   <= 1'b1;
                    tag_slot <= slot;
                    tag_line <= 16'hFFFE;
                end
                col <= col + 16'd1;
            end
        end
    end
endmodule

`default_nettype wire
