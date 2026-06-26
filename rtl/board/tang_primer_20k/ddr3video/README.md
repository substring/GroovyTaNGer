# DDR3 → line buffer → 720p HDMI (DDR3 step 3b)

Proves the core `docs/ddr3.md` thesis **on hardware**: a framebuffer in DDR3,
scanned out at **1280×720 @ 74.25 MHz** through a **3-line ping-pong BRAM buffer**,
so the pixel clock only ever reads a one-line BRAM — **bypassing the ~40 MHz
BRAM-read wall** that caps a full-frame BRAM framebuffer at 800×600.

No network, no scaler. On boot an FSM writes a fixed **test pattern** (8 vertical
colour bars + a per-line tint so adjacent lines differ) into DDR3 once, then the
`groovy_linebuf_reader` streams it to the Gowin DVI_TX continuously.

## Build (Gowin EDA)
1. Open `ddr3video.gprj`.
2. Project → Configuration → **Synthesis**: Verilog language = **SystemVerilog**
   (the DDR3 controller needs it).
3. Project → Configuration → **Dual-Purpose Pin**: **DONE**, **READY**, **SSPI**
   all = regular IO (LEDs on C13/A13, reset on T10).
4. Provide the Gowin **DVI_TX** IP at `../video/dvi_tx/dvi_tx.v` (git-ignored;
   see that dir's README / IP wizard).
5. Synthesize → P&R → Program. For a persistent flash add `-f` to openFPGALoader.

## What to expect on screen
A 720p image of **8 vertical colour bars**, each with a subtle vertical gradient
(the per-line tint). It should be **rock-stable, no flicker** — that's the whole
point: 720p clean from DDR3 = the 40 MHz BRAM-read wall is beaten.

A wrong **rightmost column** or **per-line smearing** would indicate a line
addressing / last-pixel bug (the class we fixed in `groovy_linebuf_reader`).

## LED readout (active-low)
| LED | Meaning |
|---|---|
| led[0] | `ddr_lock` — DDR3 PLL locked |
| led[1] | `tmds_lock` — 720p pixel PLL locked |
| led[2] | `!ddr_busy` — DDR3 calibration done (L16: dim, DDR3-bank — see note) |
| led[3] | `fill_done` — the test pattern has been written to DDR3 |
| led[4] | `fetch_active` — the line-buffer fetch engine is running |
| led[5] | heartbeat |

Good state: led[0],[1],[3] lit, led[5] blinking, led[4] flickering (fetching each
line). led[2] (L16) reads dim because it shares the DDR3 1.5 V bank — cosmetic.

## Architecture notes
- Two PLLs from 27 MHz: `Gowin_rPLL` (DDR3 398.25/99.5/90°) + `rpll_tmds`
  (371.25 → CLKDIV/5 → 74.25 MHz pixel). Both HW-proven elsewhere.
- One DDR3 user port, two clients: the boot **writer** owns it until `fill_done`,
  then hands off permanently to the **reader**. A refresh scheduler injects an
  auto-refresh (~every 7.8 µs) in idle gaps. (Step 4 adds true read/write
  interleaving for live network blits.)
- RGB565 (stored) → RGB888 (DVI) by bit replication — combinational, free.
- `de/hs/vs` are delayed 2 pix_clk to match the line-buffer read pipeline.
