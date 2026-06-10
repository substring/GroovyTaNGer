// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - Phase 1 bring-up: blink an LED from the 27 MHz clock.
// Spec section 9, Phase 0/1. This is the smallest design that proves the
// toolchain, the board, programming, and the clock pin BEFORE any HDMI/Ethernet.
//
// Port names match the Sipeed Tang Primer 20K Dock LED example so the verified
// pin map applies directly:  Clock -> H11 (27 MHz),  IO_voltage -> L14 (Dock LED).
// (https://wiki.sipeed.com/hardware/en/tang/tang-primer-20k/examples/led.html)
//
// No reset button is used (the Sipeed example doesn't either); the LED state is
// initialised via `initial`, which Gowin honours through bitstream config.
`default_nettype none

module led_blink #(
    // half the blink period in clock cycles. 27 MHz / (2 * 13_500_000) ~= 1 Hz.
    parameter integer HALF_PERIOD = 13_500_000
) (
    input  wire Clock,        // 27 MHz, pin H11
    output reg  IO_voltage    // LED,    pin L14
);
    localparam integer W = (HALF_PERIOD <= 1) ? 1 : $clog2(HALF_PERIOD);
    reg [W-1:0] cnt = {W{1'b0}};

    initial IO_voltage = 1'b0;

    always @(posedge Clock) begin
        if (cnt == HALF_PERIOD[W-1:0] - 1'b1) begin
            cnt        <= {W{1'b0}};
            IO_voltage <= ~IO_voltage;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end
endmodule

`default_nettype wire
