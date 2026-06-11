# HDMI video bring-up — Phase 2 (fixed 720p test pattern)

Proves **our** video pipeline through the Gowin DVI_TX path on hardware:
```
rpll_tmds (27 MHz → 371.25 MHz serial) → CLKDIV/5 → pix_clk (74.25 MHz)
video_timing_gen (720p) → de/hs/vs/hcount/vcount
test_pattern_gen → rgb (8 color bars + white border)
DVI_TX_Top (Gowin IP) → TMDS → HDMI
```
Output: 1280×720@60 color bars on an HDMI monitor. No super-res / no network yet —
that's Phase 3 (dynamic timing + ×N pixel replicator) and Rung 5 (network pixels).

## One-time: provide the DVI_TX IP
The Gowin DVI_TX IP is proprietary and git-ignored. Put `dvi_tx.v` in `dvi_tx/`
(see `dvi_tx/README.md`) — generate it in Gowin's IP wizard or copy the Sipeed
example's. (Already in place locally if you copied it during bring-up.)

## Build (Gowin IDE)
1. Open `groovy_video.gprj`. (Plain Verilog — no SystemVerilog option needed.)
2. **Project → Configuration → Dual-Purpose Pin → Use SSPI as regular IO**
   (`I_rst_n` = T10 = SSPI). The LED/TMDS/clk pins are not dual-purpose.
3. Synthesize → Place & Route → `impl/pnr/groovy_video.fs`.

## Flash & view
```bash
openFPGALoader -b tangprimer20k impl/pnr/groovy_video.fs
```
Plug an HDMI monitor into the Dock's HDMI port → **8 color bars (white, yellow,
cyan, green, magenta, red, blue, black) with a thin white border**, at 1280×720.
LEDs: `led[0]` = PLL lock, `led[1]` = heartbeat.

## What this proves
Our `video_timing_gen` and `test_pattern_gen` drive a real HDMI signal correctly.
Next: make the timing dynamic (from SWITCHRES), add the ×N horizontal pixel
replicator (super-res), and feed pixels from VRAM (network BLIT).
