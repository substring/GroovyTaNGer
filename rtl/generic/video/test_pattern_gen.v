// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - SMPTE-style color-bar test pattern (generic, vendor-neutral).
//
// Combinational RGB from the timing generator's hcount/vcount/de. The active
// size (h_act/v_act) is a RUNTIME input so the bars fit whatever resolution the
// modeline selects (needed once SWITCHRES retimes dynamically). 8 vertical bars
// + a white overscan border.
`default_nettype none

module test_pattern_gen (
    input  wire [11:0] h_act,
    input  wire [11:0] v_act,
    input  wire [15:0] hcount,
    input  wire [15:0] vcount,
    input  wire        de,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b
);
    wire [15:0] bw = {4'd0, h_act[11:3]};   // bar width = h_act/8

    reg [2:0] bar;
    always @(*) begin
        if      (hcount <  bw)      bar = 3'd0;
        else if (hcount <  2*bw)    bar = 3'd1;
        else if (hcount <  3*bw)    bar = 3'd2;
        else if (hcount <  4*bw)    bar = 3'd3;
        else if (hcount <  5*bw)    bar = 3'd4;
        else if (hcount <  6*bw)    bar = 3'd5;
        else if (hcount <  7*bw)    bar = 3'd6;
        else                        bar = 3'd7;

        if (!de) begin
            r = 8'd0; g = 8'd0; b = 8'd0;                          // blank -> black
        end else if (hcount < 16'd4 || hcount >= {4'd0,h_act} - 16'd4 ||
                     vcount < 16'd4 || vcount >= {4'd0,v_act} - 16'd4) begin
            r = 8'hFF; g = 8'hFF; b = 8'hFF;                       // white border
        end else begin
            case (bar)                                            // R G B
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
