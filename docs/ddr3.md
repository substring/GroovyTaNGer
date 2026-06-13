# DDR3 framebuffer — design

Goal: lift the two BRAM ceilings that currently cap us at **800×600 / ~40 MHz**:

1. **Capacity** — BRAM holds ~52K RGB565 pixels total, so double-buffered native
   tops out near 160×144. A real arcade frame (320×240 = 76.8K) does not fit, even
   single-buffered.
2. **Read speed** — the BRAM read path flickers above ~40 MHz pixel clock, so we
   cannot scan out 720p (74 MHz) / 1080p (148 MHz) directly from BRAM.

DDR3 fixes capacity (128 MB) and, via a **line-buffer in front of the pixel clock**,
also sidesteps the read-speed wall.

## Why the line buffer is the whole trick
We do **not** read DDR3 at the pixel clock. The ≤40 MHz BRAM lesson stays true — so:

- DDR3 streams scanlines **ahead of the beam** into a small **BRAM line buffer**
  (a few lines, ping-pong). The line-buffer BRAM read is tiny and fast → the pixel
  clock (74 MHz+) only ever touches BRAM, which it can do for a *one-line* buffer.
- The DDR3 read engine runs in its own ~100 MHz domain and fills the next line(s)
  while the current line scans out. CDC between the two is the line-buffer itself.
- This is the standard "DDR3 → line FIFO → video" scanout; it decouples output
  resolution from DDR3 latency, and decouples the pixel clock from BRAM-read limits.

## The controller — nand2mario/ddr3-tang-primer-20k (Apache-2.0)
Purpose-built for our exact chip (GW2A-18C / Tang Primer 20K). Chosen over the
official Gowin DDR3 Memory Interface IP because it is **low-latency, lightweight
(6% LUTs), single-word (no burst), and has iverilog sim** — and because its
single 16-bit word maps 1:1 to our RGB565 pixel.

Source: https://github.com/nand2mario/ddr3-tang-primer-20k (commit to vendor under
`rtl/vendor/nand2mario_ddr3/` with attribution, like the Sipeed UDP stack).

### Verified user interface (`module ddr3_controller`)
- **Clocks:** `pclk` (~100 MHz user clock), `fclk` (4×pclk = 400 MHz, DDR3-800),
  `ck` (90° shifted). All from one rPLL. `resetn` active-low.
- **Address:** `addr [BANK+ROW+COL-1:0]` = 3+13+10 = **26-bit word address** →
  2²⁶ × 16 bit = **128 MB**. Flat word-addressed space.
- **Write:** pulse `wr` with `addr` + `din[15:0]`. Honour `busy` (0 = ready).
- **Read:** pulse `rd` with `addr`; `data_ready` ~6 cycles (~90 ns) later;
  `dout[15:0]` **and `dout128[127:0]`** — a single read returns 8 contiguous words.
- **Refresh:** caller pulses `refresh` ~once / 15 µs. *We* own refresh timing →
  predictable latency, ideal for beam-racing (insert refresh only in blanking).
- **Calibration:** ZQ / write-leveling / read-cal run at init; `init_done`-style
  status before first access. Gate the datapath on it.

### Bandwidth budget (the make-or-break number)
- 100 MHz, 1 word/cmd → naive ~tens of M words/s mixed R/W.
- **`dout128` gives 8 words per read transaction** → read throughput multiplies ~8×.
- 1280×720@60 scanout = 720 active lines × 60 × 1280 px ≈ **55 M px/s**.
  With 128-bit reads that's ~7 M read-transactions/s for scanout — comfortable,
  leaving headroom for the network write stream and refresh.
- Strategy: **read in `dout128` chunks** to fill the line buffer; **write single
  words** from the blit stream (write rate ≪ read rate, and writes hide in slack).

## Address map (static, no dynamic alloc)
Word-addressed regions, partitioned at synthesis (matches `ring_buffer.v` intent):
```
frame N base = N * FRAME_WORDS,  FRAME_WORDS = max_w * max_h
pixel addr   = base + y*max_w + x
```
N frames (3 for triple-buffer, or 2 + beam-race-direct). 128 MB swallows any res
we can scan, so capacity is no longer the constraint — DDR3 *latency hiding* is.

## Interplay with what we already have
- **Double-buffer / triple-buffer:** banks become DDR3 regions; the vblank swap
  logic stays, just swaps a region index instead of a BRAM bank base.
- **Beam-racing:** the write engine streams blit pixels straight to the active
  region; the line-buffer read chases it. `groovy_writeline` still tracks write
  progress; underrun status bit still feeds the ACK. Refresh confined to blanking
  keeps the chase deterministic.
- **Scaler:** `groovy_pixel_reader` moves to address the **line buffer** (native
  line resident) instead of full-frame BRAM — horizontal super-res reads within a
  line; the DDR3 engine handles vertical line fetch / `recip_v` line selection.

## Build order (each step HW-tested before commit, per project rule)
1. **Vendor the controller** + bring-up: instantiate, wire DDR3 pins in `.cst`,
   PLL for pclk/fclk/ck, run its calibration, prove `init_done` + a write→read
   round-trip to an LED/UART. (Replaces the `ddr3_gowin.v` stub.)
2. **Memory test:** walking-1s / address-in-address over a region; pass on hardware.
3. **DDR3 → line buffer → video:** static test pattern written to DDR3, scanned
   out at 720p via the line buffer. Confirms the ≤40 MHz wall is bypassed.
4. **Wire the blit write path** to DDR3 (replace `groovy_vram` for large frames;
   keep BRAM path for tiny/fast modes). Double-buffered network video at 720p.
5. **Beam-race over DDR3** + refresh-in-blanking; underrun status.
6. **GroovyMAME at real arcade native** (320×240) → 720p+ output. Closes the loop.

## Risks / open questions
- **Calibration robustness across boards/temperature** — nand2mario notes trial-
  and-error on DQS timing; budget bring-up time on step 1.
- **`.cst` DDR3 pinout** — need the Tang Primer 20K DDR3 net names (not yet in our
  `.cst`); pull from the Sipeed reference / nand2mario project.
- **Pixel-clock PLL vs DDR3 PLL** — separate PLLs (74 MHz pixel domain, 100/400 MHz
  DDR3 domain); CDC is the line buffer. Confirm both fit the rPLL/VCO budget.
- **Refresh stalls vs beam-race** — must guarantee a refresh fits in blanking and
  never collides with an in-progress line fetch; may need a refresh scheduler.
