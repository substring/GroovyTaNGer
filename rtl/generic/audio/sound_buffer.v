// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - audio sample buffer (generic). Roadmap: Phase 10. Spec section 5.6.
//
// PORT TARGET (~90% from Psakhis Groovy_MiSTer rtl/sound.v). Buffers signed
// 16-bit PCM L/R bursts (CMD_AUDIO stream) and emits sound_l/sound_r at the
// audio rate. Output stays destination-neutral (spec section 5.6) -> feeds the
// HDMI data-island audio (audio_sample_word) and optionally the Dock jack.
// TODO(Phase10): FIFO over bram_dp_gowin, rate pacing from soundRateCode, CDC.
`default_nettype none

module sound_buffer (
    input  wire        clk,
    input  wire        rst,
    input  wire [1:0]  sound_rate_code,   // 0 none,1 22050,2 44100,3 48000
    input  wire        sound_chan,        // 0 mono, 1 stereo
    // burst input (raw bytes after CMD_AUDIO)
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    // PCM output @ audio rate
    output wire signed [15:0] sound_l,
    output wire signed [15:0] sound_r,
    output wire        sample_tick
);
    assign sound_l=16'sd0; assign sound_r=16'sd0; assign sample_tick=1'b0;
endmodule

`default_nettype wire
