// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - session/config registers: CMD_INIT / CMD_CLOSE effect. Rung 1.
//
// The parser (groovy_packet_parser) decodes these commands; this block holds
// their *effect*, mirroring groovy.cpp setInit()/setClose() minus the HPS-only
// parts (DDR malloc, sockets, MiSTer logo). The ACK that follows CMD_INIT is
// produced by groovy_ack_policy, not here.
//
// setInit clamps each field (groovy.cpp): compression<=1, audio_rate<=3,
// audio_chan<=2, rgb_mode<=2 (else 0). setClose zeroes them and disconnects.
`default_nettype none

module groovy_session (
    input  wire        clk,
    input  wire        rst,

    // from groovy_packet_parser (1-cycle strobes + fields)
    input  wire        init_valid,
    input  wire [7:0]  init_lz4,
    input  wire [7:0]  init_sound_rate,
    input  wire [7:0]  init_sound_chan,
    input  wire [7:0]  init_rgb_mode,
    input  wire        close_valid,

    // latched session configuration
    output reg         session_active,   // 1 after INIT, 0 after CLOSE
    output reg         cfg_lz4,          // 0 = raw, 1 = LZ4
    output reg  [1:0]  cfg_sound_rate,   // 0 none / 1 22050 / 2 44100 / 3 48000
    output reg  [1:0]  cfg_sound_chan,   // 0..2
    output reg  [1:0]  cfg_rgb_mode,     // 0 RGB888 / 1 RGBA888 / 2 RGB565
    output reg         new_session,      // 1-cycle pulse on INIT (reset blit state)
    output reg         end_session,      // 1-cycle pulse on CLOSE

    // derived: bytes per pixel for the current rgb mode (blit sizing later)
    output wire [2:0]  cfg_bytes_per_pixel
);
    // RGB888=3, RGBA888=4, RGB565=2
    assign cfg_bytes_per_pixel = (cfg_rgb_mode == 2'd1) ? 3'd4 :
                                 (cfg_rgb_mode == 2'd2) ? 3'd2 : 3'd3;

    always @(posedge clk) begin
        new_session <= 1'b0;
        end_session <= 1'b0;

        if (rst) begin
            session_active <= 1'b0;
            cfg_lz4        <= 1'b0;
            cfg_sound_rate <= 2'd0;
            cfg_sound_chan <= 2'd0;
            cfg_rgb_mode   <= 2'd0;
        end else if (init_valid) begin
            session_active <= 1'b1;
            new_session    <= 1'b1;
            cfg_lz4        <= (init_lz4 == 8'd1);                            // <=1 ? : 0
            cfg_sound_rate <= (init_sound_rate <= 8'd3) ? init_sound_rate[1:0] : 2'd0;
            cfg_sound_chan <= (init_sound_chan <= 8'd2) ? init_sound_chan[1:0] : 2'd0;
            cfg_rgb_mode   <= (init_rgb_mode   <= 8'd2) ? init_rgb_mode[1:0]   : 2'd0;
        end else if (close_valid) begin
            session_active <= 1'b0;
            end_session    <= 1'b1;
            cfg_lz4        <= 1'b0;
            cfg_sound_rate <= 2'd0;
            cfg_sound_chan <= 2'd0;
            cfg_rgb_mode   <= 2'd0;
        end
    end
endmodule

`default_nettype wire
