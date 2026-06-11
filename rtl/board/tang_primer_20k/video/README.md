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

## Dynamic variant — `groovy_video_dyn.gprj` (Rung 4b step 2) — WORKS ON HW
Same flow, but with the **reconfigurable** rPLL (`rpll_tmds_dyn` + `rpll_sel_encode`)
and a timer that cycles **720p ⇄ 480p every ~6 s**. Build the same way (enable
*Use SSPI as regular IO*, P&R, flash `impl/pnr/groovy_video_dyn.fs`). The monitor
switches resolution every ~6 s, showing our color bars at each — proving runtime
rPLL reconfig + clean relock + dynamic timing. LEDs: `led[0]`=pix_clk alive,
`led[1]`=mode, `led[2]`=running, `led[3]`=heartbeat.

Two non-obvious lessons baked in here:
- **The rPLL `LOCK` output does NOT assert in dynamic mode** (`DYN_*_SEL="true"`)
  even though the clock is correct — so never gate on it. `CLKDIV.RESETN=I_rst_n`
  and the FSM uses a fixed settle delay, not a lock-wait.
- Dwell long enough (~seconds) per mode for the **monitor** to re-sync; switching
  too fast looks like "no signal".
- `rpll_sel_encode`: IDSEL=64−IDIV, FBDSEL=64−FBDIV, ODSEL is a table (verified
  against apicula's dynamic example). `groovy_pll_test.gprj` is a constant-720p
  isolation harness kept for debugging the dynamic rPLL.

Next: SWITCHRES drives the rPLL+timing, plus the ×N pixel replicator (Phase 3).
