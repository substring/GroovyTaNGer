# HDMI (to be vendored) — Phase 2/3

This directory will hold the **forked** HDMI module described in spec §6.5,
sourced from tangcore `nestang/src/hdmi2/` (itself a Gowin adaptation of
[sameer/hdl-util/hdmi](https://github.com/hdl-util/hdmi)).

It is intentionally empty now: vendoring third-party RTL is a deliberate,
license-bearing step that should be a reviewable commit of its own, done when
Phase 2 starts and the board is in hand.

## What to vendor (spec §6.5 table)

```
hdmi.sv  serializer.sv  tmds_channel.sv  packet_picker.sv  packet_assembler.sv
audio_sample_packet.sv  audio_clock_regeneration_packet.sv
audio_info_frame.sv  auxiliary_video_information_info_frame.sv
source_product_description_info_frame.sv
```
Plus `nes2hdmi.sv` (integration example) and `gowin_pll_hdmi.v` (to be made
reconfigurable, see `rtl/vendor/gowin/rpll_gowin.v`).

## Forks required (spec §6.5 "Limites", Q8)

1. **Dynamic timing** — `hdmi.sv` picks timing via `generate case (VIDEO_ID_CODE)`
   at synthesis. Convert `frame_width`, `screen_width`, `hsync_pulse_start`,
   … to *input signals* so arbitrary modelines work (Phase 3). Our
   `rtl/generic/video/video_timing_gen.v` already follows this dynamic style and
   can drive / replace that timing front-end.
2. **Interlaced** — not implemented upstream; add field 0/1, half-line, and AVI
   InfoFrame `scan_info` (Phase 9).
3. **Dynamic `VIDEO_REFRESH_RATE`** — needed for the audio N/CTS calc (Phase 10).

## License / attribution (spec §6.5)

- Upstream `sameer/hdl-util/hdmi`: MIT-like. **[À VÉRIFIER]** confirm exact
  license headers of the `hdmi2/*` files at vendor time.
- Preserve original notices; credit Sameer Puri and nand2mario.
- Compatible with our GPL-2.0-or-later, but keep the third-party headers intact.
