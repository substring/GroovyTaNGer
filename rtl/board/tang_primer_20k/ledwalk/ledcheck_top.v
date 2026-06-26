// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - LED MAP CHECK: drive a KNOWN static pattern by board label and
// confirm the board->led[] scramble map is correct. NO DDR3, no PLL, nothing that
// can interfere - just the 27 MHz clock for an optional heartbeat.
//
// We light EXACTLY board labels 0, 1, 2 (solid), and leave 3, 4, 5 OFF, using the
// calibrated board->led map. If the user sees exactly labels 0,1,2 lit and 3,4,5
// dark, the map is correct. If a different set lights, the map is wrong and the
// user's reading tells us the true map directly.
`default_nettype none

module ledcheck_top (
    input  wire        sys_clk,
    input  wire        sys_resetn,
    output wire [5:0]  led
);
    // active-HIGH board[k] = light board LABEL k. Calibrated map:
    //   led0=board1 led1=board5 led2=board3 led3=board4 led4=board2 led5=board0
    // i.e. led[5:0] = ~{board0, board2, board4, board3, board5, board1}.
    wire [5:0] board;
    assign board[0] = 1'b1;   // light board label 0
    assign board[1] = 1'b1;   // light board label 1
    assign board[2] = 1'b1;   // light board label 2
    assign board[3] = 1'b0;   // board 3 OFF
    assign board[4] = 1'b0;   // board 4 OFF
    assign board[5] = 1'b0;   // board 5 OFF
    assign led = ~{ board[0], board[2], board[4], board[3], board[5], board[1] };
endmodule

`default_nettype wire
