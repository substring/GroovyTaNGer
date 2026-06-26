// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - synthetic DDR3 responder for DIAGNOSTICS (no real memory).
//
// Drop-in replacement for the nand2mario ddr3_controller's USER PORT only: it
// answers single-word read requests with a computed value pix = f(addr), with a
// realistic fixed latency, and ACKs writes (ignoring data). Used to bypass the
// real DDR3 entirely so we can test the line-buffer reader + scaler + DVI path
// in isolation. If the period-2 stripes appear even with this PERFECT memory,
// the bug is in the reader/scaler/scanout - NOT in DDR3.
//
// The read value is a deterministic function of the address so any pixel that
// reads "wrong" reveals exactly which address it actually came from.
`default_nettype none

module groovy_fake_ddr3 #(
    parameter integer ADDR_W  = 26,
    parameter integer LATENCY = 6,   // pclk cycles from rd pulse to data_ready
    parameter integer BARS    = 0,   // 1 = 8 HORIZONTAL colour bars (value constant
                                     //     within each WIDTH-block = each source line),
                                     //     so a clean scanout has ~0 horizontal
                                     //     transitions and rain shows as excess ones.
    parameter integer WIDTH   = 320, // source line width (addresses per row)
    parameter integer HEIGHT  = 240
) (
    input  wire              clk,        // pclk
    input  wire              rst,
    input  wire              rd,
    input  wire              wr,         // accepted + ignored
    input  wire              refresh,    // accepted + ignored
    input  wire [ADDR_W-1:0] addr,
    input  wire [15:0]       din,        // ignored
    output reg  [15:0]       dout,
    output reg               data_ready,
    output reg               busy
);
    // PATTERN(addr): a value that makes addressing errors obvious. Low bits drive
    // colour so adjacent addresses differ strongly (period-2 / off-by-one shows).
    //   bit0 of addr -> toggles a channel; mid bits -> a ramp.
    // 8 horizontal colour bands by ROW (= addr/WIDTH), HEIGHT/8 rows each.
    function [15:0] bandf; input [ADDR_W-1:0] a;
        reg [15:0] row; reg [2:0] band;
        begin
            row  = a / WIDTH[ADDR_W-1:0];
            band = row / (HEIGHT/8);
            case (band)
                3'd0: bandf=16'hF800; 3'd1: bandf=16'h07E0; 3'd2: bandf=16'h001F;
                3'd3: bandf=16'hFFE0; 3'd4: bandf=16'h07FF; 3'd5: bandf=16'hF81F;
                3'd6: bandf=16'hFFFF; default: bandf=16'h8410;
            endcase
        end
    endfunction
    function [15:0] patf; input [ADDR_W-1:0] a;
        // BARS=0: gradient (adjacent addrs differ, off-by-one visible).
        // BARS=1: 8 horizontal colour bars (value constant within each source line).
        patf = (BARS != 0) ? bandf(a) : { a[4:0], a[5:0], (a[0] ? 5'h1F : 5'h00) };
    endfunction

    reg [ADDR_W-1:0] addr_l;
    reg [7:0]        cnt;          // widened so LATENCY can exceed 15 (stress the race)
    always @(posedge clk) begin
        data_ready <= 1'b0;
        if (rst) begin
            busy <= 1'b0; cnt <= 8'd0;
        end else begin
            // accept a command: go busy, latch addr, count down latency
            if ((rd | wr | refresh) && !busy) begin
                busy   <= 1'b1;
                addr_l <= addr;
                cnt    <= LATENCY[7:0];
            end else if (busy) begin
                if (cnt > 8'd1) cnt <= cnt - 8'd1;
                else begin
                    busy <= 1'b0;
                    // only reads produce data_ready + dout
                    data_ready <= 1'b1;
                    dout       <= patf(addr_l);
                end
            end
        end
    end
endmodule

`default_nettype wire
