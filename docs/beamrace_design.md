<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
# Beam-race architecture (real-time line streaming)

The design that replaces the store-and-forward static path. Goal: ~1 scanline of
latency (GroovyMiSTer behaviour), not a full frame. Written after the static-image
work proved the network->DDR3->HDMI plumbing but exposed why store-and-forward can't
stream in real time.

## Why the static path crawls (the problem we're solving)

In `gwddr3net` today the **reader** (HDMI scanout) and the **writer** (network fill)
run as INDEPENDENT clients on one shared DDR3 port:

- The reader free-runs at 60 Hz, fetching every source line every frame. It holds the
  bus most of the time (`fetch_active` = `fstate != FIDLE`).
- The writer scrounges the leftover gaps (`grant_wr = wr_active && !fetch_active`).
  With the reader running continuously, those gaps are tiny, so the writer is
  STARVED: a 76800-word frame takes ~1 second to land (HW-observed: the image
  visibly paints in line by line over ~1 s, regardless of how fast the host sends -
  the host blasts a frame in <1 ms; the bottleneck is the writer's bus access).

Root cause: the two clients FIGHT for the bus with no coordination. No amount of
writer speed-up fixes this while the reader runs free - it's architectural.

## The beam-race idea: synchronize both to the raster

Instead of fighting, the writer and reader march down the frame TOGETHER, around one
moving point - the current scanline:

- The host (emulator) sends line N's pixels timed to arrive JUST BEFORE the FPGA
  raster reaches line N. (GroovyMiSTer already does this; the protocol carries it -
  see below.)
- The FPGA WRITES line N into DDR3, then READS line N a moment later for scanout.
- Read lags write by a small margin (a few lines), never the other way.
- Per line-time: ~one line written + one line read. Bus load is balanced BY
  CONSTRUCTION, not by scrounging.
- The host paces sending using the vCount ACK feedback (FPGA reports the raster line
  it is scanning; host stays ~`frame_delay` ahead).

Latency: store-and-forward = ~16-33 ms (a frame). Beam-race = ~1-3 ms (a few lines).

## What the protocol already gives us (verified)

From docs/protocol_verified.md + the existing cores:
- A frame >> MTU, so pixels already arrive as ~150 datagrams (horizontal slices) -
  i.e. the wire is ALREADY line-ish granular.
- The BLIT header carries `vSync` (u16) and `frame#`. `vSync==0` = full-frame mode;
  `vSync>0` = beam-race target line. (full/groovy_top.sv already keys beam_race off
  `blit_vsync != 0`.)
- The ACK reports `fpga_vga_vcount` (live raster line) and echoes vSync -> the closed
  loop for the host to tune `frame_delay`. TODAY this vCount is a placeholder; the
  KEY gateware change is to make it the REAL scanout line.

## The hard constraint: DDR3 read cadence (do not break DQS)

Discovered this project ([[ddr3-readgap-breaks-dqs]], [[ddr3-byte-lane-skew]]): the
reader's per-line fetch must be BACK-TO-BACK reads; injecting a write (or a gap) into
the MIDDLE of a line fetch desyncs the DQS byte lanes (~80% errors). So beam-race bus
sharing must be at LINE granularity, never mid-line:

- Writer writes a whole line (or its share) in the inter-line window.
- Reader fetches a whole line back-to-back, uninterrupted.
- They alternate per line-time, each getting an uninterrupted DDR3 burst.

This is actually easier than fine interleaving: the reader already fetches one source
line then idles for V_REPL output lines (the replay window). That idle window is where
the writer's line goes.

## Buffering model: BRAM LINE RING, read chases write  [REVISED 2026-07-01]

NOT DDR3 and NOT a full-frame double-buffer. A full frame doesn't fit BRAM (320x240
RGB565=145% BSRAM) - that's why DDR3 existed. But beam-race only needs the write->read
WORKING SET (a few lines), which fits BRAM trivially, and a TRUE DUAL-PORT BRAM serves
writer + reader SIMULTANEOUSLY with NO arbitration -> the DDR3 bus contention (the ~1s
crawl) and all DQS/byte-lane grief simply vanish.

- `groovy_lineram`: NLINES-slot x LINE_W x DATA_W dual-port BRAM ring. Source line L
  lives in slot (L mod NLINES). Store NATIVE line width (reader replicates H on
  scanout) so LINE_W only covers the widest native line (1024 covers all realistic
  incl. hi-res; parameter, can go wider). NLINES parameterized (default ~8) = jitter
  tolerance. 12 lines x1024 RGB888 = 288Kb (~35% BSRAM), fits with LZ4/audio.
- Track WRITE line (highest fully-written, = groovy_writeline - REUSED, HW-proven) and
  READ line (raster / V_REPL). TWO-SIDED invariant (both HW-verified in
  groovy_lineram_tb):
    * UNDERRUN: read must stay >= MARGIN behind write (read line L only when
      L <= write_line - MARGIN). If read catches write -> show STALE line + ACK status
      bit, NEVER stall (raster unstoppable).
    * OVERRUN/LAP: write must NOT lap read by >= NLINES (write_line - read_line <
      NLINES) or it clobbers a slot the reader still needs (tb confirmed this corrupts).
      The raster pacing (vCount ACK) keeps the host from running ahead; gateware still
      guards it.
  State: SYNC/FILL -> STREAM -> UNDERRUN.
- REUSE from the HW-proven full/ BRAM path (commit 6f92680): groovy_writeline
  (write-ptr), beam_race mode select off blit_vsync!=0, underrun->beamrace_status,
  vcount->ACK, groovy_pixel_reader (H/V replicate scaler). Swap its full-frame
  double-buffer for groovy_lineram.

## States (per frame)

- **SYNC/FILL**: at frame start, wait until the write pointer is MARGIN lines ahead
  before starting scanout (absorbs startup jitter). Like the current `have_frame`
  gate but line-granular and re-armed every frame.
- **STREAM**: steady state. Each line-time: writer fills the next pending line(s),
  reader fetches the current scan line (which is <= write_ptr - MARGIN).
- **UNDERRUN**: read line reached write_ptr. Display stale, flag it, keep the raster
  going. Recover when write catches up.

## Gateware pieces (build order)

1. **Real vCount ACK** (smallest, highest value): wire the actual scanout raster line
   (pix_clk `vcount`, CDC'd to clk50m) into `groovy_ack_policy.fpga_vcount`. This
   alone lets the host beam-race-pace against truth, testable independently.
2. **Write-pointer tracking**: in the writer / blit path, track the highest line
   whose pixels have been committed to DDR3 this frame; CDC to the reader's pix_clk.
3. **Line-granular arbiter**: replace `grant_wr = !fetch_active` with a per-line
   scheduler - reader fetches its line uninterrupted; writer gets the inter-line
   window; both always whole-line. Reader-blocked-until `read_line <= write_ptr -
   MARGIN`.
4. **Underrun handling**: stale-line display + status bit; never stall.
5. **frame/vSync mode select**: key beam-race vs full-frame off blit `vSync`
   (0=full-frame fallback, >0=raster target), as full/groovy_top.sv already sketches.

## KNOWN LIMITATION of the first gwline cut (2026-07-01)

The first gwline_top handles ONE frame cleanly (static-image test): writer fills the
ring, lap-guard throttles it to the raster rate, reader chases -> picture in ~1 frame,
no crawl, no corruption. But CONTINUOUS streaming has a cross-frame ring hazard: a new
blit_valid resets write_line to 0 while the reader is still finishing the previous
frame at a high line; line 0 and (old_line) can map to the SAME ring slot -> collision.
Needs frame-boundary handling in the beam-race control (e.g. per-frame ring reset gated
on the reader reaching frame end, or a frame-parity bit in the slot tag). Fine to defer
past the static-image HW proof; must fix before live continuous emulator content.

## Open questions to settle before coding

- MARGIN (how many lines read stays behind write): start ~4-8 lines? Tune on HW.
- Where the write pointer lives (pixel domain vs line domain) and the CDC to pix_clk.
- Static-image fallback: a still image has no emulator pacing. Keep a "full-frame"
  mode (vSync==0) that writes the whole frame with the reader briefly held (the
  current have_frame behaviour) for stills/test, and use beam-race (vSync>0) for live
  emulator content. Two modes, one buffer.
- Interlace (sr_interlace) - defer.

See [[gwddr3net-status]], [[groovy-tang-roadmap]] (line/beam-race section).
