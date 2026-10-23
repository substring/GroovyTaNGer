# HDMI corruption while the DDR3 runs (open issue)

Status: **open**, investigated 2026-10-23 on the Tang Primer 20K Dock. Workaround: the
line-ring path (`gwline`, BRAM only, no DDR3) shows a clean picture; the DDR3
full-frame path (`gwddr3net`, `gwddr3video`) waits until this is solved.

## Symptom

With `gwddr3net` driving a monitor over HDMI (720p, 74.25 MHz pixel clock):

- solid colour bars look perfect;
- a grey ramp, and some colours (e.g. RGB888 148,0,140 and 156,60,156), flicker;
- the wrong pixels "crawl": a band of glitches drifting slowly down the screen,
  always on the same colours, never random noise over the whole picture.

## What it is not

| Hypothesis | How it was ruled out |
|---|---|
| DDR3 readback / line buffer / scaler | UART probes `FD`/`SD` (order-dependent checksum of every frame of the fetched DDR3 words and of the pixels handed to the DVI encoder): on a static picture neither changed over ~900 frames. The FPGA sends bit-identical frames. |
| The reader's pixels at all | `HDMI_SELFTEST=1` in `gwddr3net_top` (encoder fed a logic-generated picture, everything else running): same flicker. |
| Monitor temporal dithering (FRC) | Half/half test with "6-bit-exact" vs "between levels" colours: the flicker follows the colour value, not the dithering class. |
| Cable / monitor | Same board, cable and monitor show Sipeed's `dk_video.fs` ramp and our own `hdmi_probe` picture cleanly. |
| Our DVI_TX copy, PLL, pins, IO standard | `rtl/board/tang_primer_20k/video/hdmi_probe_top.v` (same `rpll_tmds`, `CLKDIV`, DVI_TX, `.cst` as `gwddr3net`, nothing else) shows the very picture that flickers, cleanly. TMDS constraints and DVI_TX options are identical to Sipeed's example. |
| RMII outputs (MDC = 1 MHz at 24 mA in the TMDS bank) | MDC 4 mA, MDIO/TXEN 8 mA: no change. |
| SDC treating serial/pixel clocks as unrelated | `create_generated_clock` for both: no change. |

## Bisection (same logic-generated picture on every build)

| Bitstream | DDR3 | Ethernet | Result |
|---|---|---|---|
| `hdmi_probe` | no | no | clean |
| `gwline` + self-test picture | no | yes | clean |
| `gwddr3video` + self-test picture | yes | no | much better, a residual band remains |
| `gwddr3net` + self-test picture | yes | yes | flickers |

**The DDR3 controller is the aggressor**; Ethernet alone is harmless but adds to it.
Only in `gwddr3net` does the PnR report put `serial_clk` on a PRIMARY global as well
as on its bank HCLK (in every clean build it is HCLK only); not explained yet.

## DDR3 clock experiments (`gwddr3net`, self-test picture)

| mem_pll | DDR3 user clock | vs 74.25 MHz pixel clock | Result |
|---|---|---|---|
| 302.4 MHz (Sipeed, default) | 75.6 MHz | 1.35 MHz away = 30 cycles per line | crawling bands |
| 297 MHz (27 x 11) | 74.25 MHz | identical frequency, fixed phase | far worse |
| 324 MHz (27 x 12) | 81 MHz | ~9 % away | far worse |

The DDR3 data read back was identical at all three frequencies (`FK=30E0`): the DDR3
itself is fine, only the HDMI output changes. The effect depends strongly on the DDR3
clock but not monotonically with its distance from the pixel clock.

## Known Gowin issue

[juj/gowin_flipflop_drainer](https://github.com/juj/gowin_flipflop_drainer) documents
the same class of failure on Gowin FPGAs including the Primer 20K: with enough logic
toggling, DVI output shows colour glitches on individual pixels (or loses sync at
higher clocks) while timing passes and the PLL stays locked. Cables, capacitors and the
LVDS serialiser were ruled out there; the author suspects internal crosstalk / peak
current from many flip-flops switching on the same edge. Mitigations reported: a
smaller design, and splitting the switching logic across clock edges. No vendor fix.

## Next things to try (not done)

1. **Phase separation:** DDR3 user clock = pixel clock (297 MHz) and sweep the mem_pll
   output phase (`CLKOUTP` + `PSDA_SEL`) so the DDR3 controller switches away from the
   DVI encoder's edges. Check that the DDR3 IP's internal /4 lands on the same phase
   after every reset.
2. **Less simultaneous switching** in the DDR3 domain (clock enables when idle; the
   scanout reads only 240 lines per frame).
3. Find why `serial_clk` gets a PRIMARY global in `gwddr3net` and pin `CLKDIV` /
   `rpll_tmds` next to bank 0/1.
4. Compare with a known DDR3 + HDMI design on this board (nand2mario's cores).

## Tools left in the tree

- `rtl/board/tang_primer_20k/video/hdmi_probe_top.v` (+ `hdmi_probe.gprj`): the
  HDMI-only reference picture.
- `gwddr3net_top`: UART `FD SD FK SK PW` stability probes, `HDMI_SELFTEST` switch.
- Scratch senders used for the tests (not in the tree): a grey ramp + the two
  sensitive colours, sent as INIT + BLIT + 1440-byte datagrams back to back.
