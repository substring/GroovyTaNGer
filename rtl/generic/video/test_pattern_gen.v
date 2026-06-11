// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - SMPTE-style color-bar test pattern (generic, vendor-neutral).
//
// Combinational RGB from the timing generator's hcount/vcount/de. Used to prove
// our video pipeline (video_timing_gen -> this -> DVI_TX) end to end on hardware
// before real pixels arrive from VRAM. 8 vertical bars across H_ACT + a white
// overscan border. H_ACT must be a multiple of 8.
`default_nettype none

module test_pattern_gen #(
    parameter integer H_ACT = 1280,
    parameter integer V_ACT = 720
) (
    input  wire [15:0] hcount,
    input  wire [15:0] vcount,
    input  wire        de,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b
);
    localparam integer BW = H_ACT / 8;   // bar width

    reg [2:0] bar;
    always @(*) begin
        // pick bar 0..7 by hcount (threshold compares, no division on hardware)
        if      (hcount <  BW)   bar = 3'd0;
        else if (hcount < 2*BW)  bar = 3'd1;
        else if (hcount < 3*BW)  bar = 3'd2;
        else if (hcount < 4*BW)  bar = 3'd3;
        else if (hcount < 5*BW)  bar = 3'd4;
        else if (hcount < 6*BW)  bar = 3'd5;
        else if (hcount < 7*BW)  bar = 3'd6;
        else                     bar = 3'd7;

        if (!de) begin
            r = 8'd0; g = 8'd0; b = 8'd0;                 // blanking must be black
        end else if (hcount < 4 || hcount >= H_ACT-4 ||
                     vcount < 4 || vcount >= V_ACT-4) begin
            r = 8'hFF; g = 8'hFF; b = 8'hFF;              // white border (overscan)
        end else begin
            case (bar)                                   // R G B
                3'd0: begin r=8'hFF; g=8'hFF; b=8'hFF; end // white
                3'd1: begin r=8'hFF; g=8'hFF; b=8'h00; end // yellow
                3'd2: begin r=8'h00; g=8'hFF; b=8'hFF; end // cyan
                3'd3: begin r=8'h00; g=8'hFF; b=8'h00; end // green
                3'd4: begin r=8'hFF; g=8'h00; b=8'hFF; end // magenta
                3'd5: begin r=8'hFF; g=8'h00; b=8'h00; end // red
                3'd6: begin r=8'h00; g=8'h00; b=8'hFF; end // blue
                default: begin r=8'h00; g=8'h00; b=8'h00; end // black
            endcase
        end
    end
endmodule

`default_nettype wire
