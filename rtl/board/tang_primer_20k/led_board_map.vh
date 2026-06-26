// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - Dock LED board-number mapping (REFERENCE, not a macro).
//
// The 6 Dock LEDs are physically SCRAMBLED relative to the led[] bit index
// (calibrated by the `ledwalk` project; see the tang-led-mapping memory). The
// board silkscreen prints LED NUMBERS 0..5, and we ALWAYS reason in those board
// numbers - the user reads the board; only RTL permutes. The user reports board
// LED numbers; I drive board LED numbers.
//
// In every top module, declare an active-HIGH `board[5:0]` (board[k] = lit on
// board LED k) and emit the active-low led[] with this EXACT assignment:
//
//     wire [5:0] board;
//     assign board[0] = ...;   // what to show on board LED 0
//     ... board[1..5] ...
//     assign led = ~{ board[2], board[4], board[3],
//                     board[5], board[1], board[0] };
//
// The {..} order is led[5:0] = {led5,led4,led3,led2,led1,led0}, and each led bit
// carries its board signal per the VERIFIED static-single-LED calibration
// (2026-06-22; the earlier walk-based map was WRONG):
//   led5=board2  led4=board4  led3=board3  led2=board5  led1=board1  led0=board0
// (i.e. led[N]=board label N EXCEPT led2<->label5 and led5<->label2 are swapped.)
//
// Quick sanity (verified in sim): board[k]=1 lights exactly board LED k.
//
// NOTE: board LED 3 is on N14 (a normal 3.3V bank) - it's fine. The DDR3-bank LED
// that reads dim is led[2] = board label 5 (L16); avoid BOARD LABEL 5 for critical
// signals in DDR3 designs.
