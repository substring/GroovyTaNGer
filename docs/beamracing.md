# Beam-racing (low-latency line streaming) — design

Goal: sub-frame latency (~1–3 ms) instead of the double-buffer's ~1 frame, by
**reading the framebuffer while it's still being written** — the display's raster
"chases" the network write pointer with a small `frame_delay` margin.

## How it works on our platform
- The host (GroovyMAME) sends the frame **in raster order**, paced so the write
  stays ahead of the display read by `frame_delay`. It uses our **ACK `vCount`**
  (already the real raster line) to know where our beam is and pace itself.
- The FPGA writes the frame to a buffer and the display **reads the same buffer**
  (no vsync swap). As long as write_line > read_line, the display shows the fresh
  frame; latency ≈ `frame_delay`.
- **Underrun** (read catches write): the un-written lines still hold the *previous*
  frame → tearing on those lines. Policy: **never stall** (the raster is fixed-rate);
  show stale + raise a status bit so the host backs off (increases frame_delay).
- Mode select per protocol: **blit `vSync == 0` → full-frame (double-buffer, current);
  `vSync > 0` → beam-race**. So we honour whatever GroovyMAME sends; keep BOTH.

## Why the host side is the crux
The display raster is unstoppable; only the host can keep the write ahead. Tight
sub-ms pacing is GroovyMAME's job (real-time C). Our Python `gm_test_sender` can
only *approximate* (ms-jittery) — a best-effort `blitrace` that polls `status`/ACK
vCount and starts each frame near vsync will show the *mechanism* (and some tearing),
but the clean low-latency result needs real GroovyMAME.

## FPGA pieces (build order)
1. **write-progress tracker** (`groovy_writeline`, clk50m): from `wr_en` + native_w,
   count fully-written native lines (`write_line`). [this commit — sim-verified]
2. **beam-race read mode**: when active, the reader reads the *write* bank (no swap);
   CDC `write_line` → pix_clk, compare to the display native line
   (`vcount >> shift_v`) → `underrun = (read_line >= write_line)`.
3. **status bit** in the ACK (underrun / vramReady) so the host paces; mode from
   `blit_vsync != 0`.
4. **best-effort `blitrace`** in gm_test_sender (pace frames to ~vsync via vCount),
   then real GroovyMAME.

## Constraints carried over
- GW2A read path wants ≤ ~40 MHz pixel clock (see [[groovy-tang-status]]) → keep the
  800×600 output (or scan-double a native CRT mode into a ≤40 MHz monitor mode).
- Single-buffer beam-race needs only the active frame in BRAM (no 2× banks) — frees
  BRAM, or allows a larger native.
