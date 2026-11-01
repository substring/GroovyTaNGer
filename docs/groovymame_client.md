# Driving gwline from GroovyMAME (2026-10-30)

What it takes to run the real GroovyMAME client (`-video mister`, its own nogpu client in
`src/osd/modules/render/drawnogpu.cpp`) against the gwline BRAM line ring over the Tang
Primer 20K Dock's 100 Mbit Ethernet. Protocol conformance itself is in
`docs/protocol_conformance_2026-10.md`.

## Setup recap: the "hacks" that make it work (2026-10-30, HW-confirmed on the CRT; 4 and 5 added 2026-11-01)

Everything below is needed together; each one is explained further down.

1. **RGB565 from GroovyMAME** - `patches/groovymame-mister-rgb565.patch`, option
   `-mister_rgb_mode rgb565`. Raw RGB888 does not fit 100 Mbit; RGB565 does.
2. **Kernel pacing in GroovyMAME** - `patches/groovymame-mister-pacing.patch` (apply after
   the rgb565 one), option `-mister_pacing 1.0`. Spreads each frame over the raster time
   instead of a wire-speed burst that overflows the FPGA's 32-line ring; the emulation
   thread does not wait.
3. **The `fq` qdisc on the sending interface** (root, not persistent), without which
   `-mister_pacing` silently does nothing:
   ```bash
   tc qdisc replace dev <interface> root fq flow_limit 1000
   ```
   `<interface>`: `eno1` on g4ge, `enp6s0` on the 5800X. `flow_limit 1000` is mandatory
   (the default 100 drops the tail of every frame). Back to normal:
   `tc qdisc replace dev <interface> root fq_codel`.
4. **`-aspect 4:3`** on GroovyMAME's command line: otherwise switchres takes the PC
   desktop's aspect (16:10 here) for the CRT's and widens every mode by 1.2 (a 320-px game
   in a 384-px mode, black bars each side). See "Raster from the modeline".
5. **The user's own `-monitor custom -crt_range0 ...`** (or `-switchres_ini 1` with a
   `switchres.ini` in the current directory; it is NOT read by default): the FPGA
   (VIDEO_MODE 4) now runs the modeline as is, so the CRT geometry comes from there.

Plus, on the FPGA side, a bitstream with the conformance fixes (commit 0f317be or later;
`GET_STATUS` status bit 6 = 1 proves it) and, for the CRT, VIDEO_MODE 4
(`impl/variants/gwline_mode4_modeline.fs`; before 2026-11-01: VIDEO_MODE 3). And the PC's address on the
board's subnet (`ip addr add 192.168.15.15/24 dev <interface>`, root).

Constraint to remember: GroovyMAME's frame delay must stay >= ~8.9 (262-line modes) for
the 32-line ring - see "The real constraint" below.

## Command line

```bash
./gmlibretro libretro -L <core>.so -cart <rom> -video mister -mister_ip 192.168.15.14 \
    -mister_rgb_mode rgb565 -mister_pacing 1.0 -verbose
```

The renderer is called **`mister`**, not `nogpu` (`osd_module(OSD_RENDERER_PROVIDER,
"mister")`); `-video nogpu` falls back to `auto` without an error.

## Two client patches (in `patches/`, for the user's fork substring/GroovyMAME)

Apply in this order, on 4ce01b9 (`libretro-driver`):

| Patch | Option | What |
|---|---|---|
| `groovymame-mister-rgb565.patch` | `-mister_rgb_mode rgb565` | 5-byte CMD_INIT with rgbMode 2 (already in the protocol, MiSTer supports it) and 2-byte little-endian pixels. Default rgb888 keeps the 4-byte INIT. |
| `groovymame-mister-pacing.patch` | `-mister_pacing <F>` | Sets `SO_MAX_PACING_RATE` = F x bytes per raster line x hfreq at each SWITCHRES, so the kernel spreads the frame over the raster time. Default 0 = off. Linux only. |
| `groovymame-mister-pacing-raise-fix.patch` | (same) | 2026-11-01 fix, already folded into the pacing patch above: Linux only ever LOWERS a UDP socket's pacing rate, so to raise it after a narrower mode the socket is recreated on the same local port. |

Both apply cleanly and their files compile (g++ -std=c++20 -Werror); neither has run
against the board yet.

## Why the bandwidth is the whole story

100 Mbit on the wire, 1538 bytes per 1472-byte datagram. Per source line of 320 pixels:

| Format | Wire time per line | 15 kHz raster line | Writer vs raster |
|---|---|---|---|
| RGB888 (GroovyMAME default) | 80 us | 63.6 us | falls behind ~62 lines/frame: bottom lines late (black) |
| RGB565 burst (patch 1 alone) | 53 us | 63.6 us | gains ~40-47 lines/frame: overflows the 32-line ring |
| RGB565 + pacing 1.0 (both patches) | 63.6 us | 63.6 us | constant lead = where the burst started |

MiSTer has 1 Gbit and full-frame DDR3, so none of this exists there.

## Pacing without stealing time from the emulation

GroovyMAME's nogpu client sends from the emulation thread. Sleeping between lines there
would cost the next frame's emulation time and kill frame delay. Kernel pacing does not:
`sendto()` copies the whole frame into the socket and returns at once (the socket is
non-blocking with a 2 MB send buffer), and the **fq** queueing discipline releases the
datagrams one by one, `packet length / rate` apart. The emulation thread even gains the
~0.3 ms the burst used to take. (The alternative that also works on Windows is a
dedicated sender thread with a double buffer: a bigger patch.)

### The qdisc, in detail

Every packet leaving Linux goes through the interface's queueing discipline (qdisc).
`SO_MAX_PACING_RATE` only records a rate on the socket; **only the `fq` qdisc enforces
it**. Systemd's default, `fq_codel`, ignores it. Checked on 2026-10-30, both machines run
`fq_codel` and have `net.core.wmem_max` = 4 MB:

| Machine | Interface | qdisc | wmem_max |
|---|---|---|---|
| 5800X (dev PC) | enp6s0 | fq_codel | 4194304 |
| g4ge (GroovyArcade, kernel 7.2.11-arch1-1-15khz) | eno1 | fq_codel | 4194304 |

Commands (root):

```bash
tc qdisc show dev eno1                                   # current qdisc
tc qdisc replace dev eno1 root fq flow_limit 1000        # enable pacing (not persistent)
tc -s qdisc show dev eno1                                # during a run: 'dropped', 'flows_plimit' must stay 0
tc qdisc replace dev eno1 root fq_codel                  # back to the default
```

Two traps:
- **`flow_limit`**: fq queues at most 100 packets per flow by default and drops the rest.
  One frame is 105 datagrams (320x240 RGB565) to 126 (384x240): without
  `flow_limit 1000` the tail of every frame is lost.
- **send buffer**: paced packets wait in the socket's send buffer. GroovyMAME asks for
  2 MB (honoured because wmem_max is 4 MB); one frame is ~150-300 KB of buffer.

Making it permanent on GroovyArcade: `net.core.default_qdisc = fq` in a
`/etc/sysctl.d/` file switches every interface to fq at boot, but keeps
`flow_limit 100`, so a small service or a NetworkManager / systemd-networkd hook must
still run the `tc ... flow_limit 1000` line once the interface is up. fq is the default
on many servers; it keeps per-flow fairness but loses CoDel's queue-delay control, which
only matters on a desktop that saturates its uplink (an arcade box mostly sends this
stream). It can be limited to the interface that reaches the FPGA.

## The real constraint: frame delay vs the 32-line ring

With pacing, line k of a frame leaves the PC k raster lines after the burst starts, so
the writer's lead over the raster stays equal to the distance between the line where
GroovyMAME blits and the raster's top of frame:

    lead = vtotal - vsync_scanline,   vsync_scanline = vtotal * frame_delay + 1

The ring holds 32 lines, so the lead must stay under ~30. With vtotal 262 that means a
frame delay of about **0.89 or more** (GroovyMAME `fd` >= 8.9). The user's first run
showed `fd: 9.100` (automatic frame delay, light core): lead ~24, fine. A heavy game whose
automatic frame delay drops (say fd 5, blit at line 131) would arrive ~130 lines early:
the ring overflows even with pacing. This is inherent to a beam-racing ring that is much
smaller than a frame; MiSTer's full frame buffer accepts any frame delay.

Ways around it, for later:
- `SO_TXTIME` + the `etf` qdisc: the client stamps the first datagram with a launch time
  ~30 lines before the raster's top, whatever the frame delay (the emulation still runs
  early; only the transmission waits). Bigger patch, and needs the raster phase (the ACK
  or the FPGA beacon) to compute the launch time;
- FPGA back-pressure (stall the ring writer when full; udp.sv's 8 KB RX FIFO absorbs ~12
  lines): a little more margin, not a solution;
- a bigger ring (384-column slots: ~64 lines for about +7 BSRAM).

## First run with GroovyMAME (2026-10-30)

Sonic 2 (Genesis Plus GX, libretro driver) with `-mister_rgb_mode rgb565`, board still on
the pre-conformance bitstream: no picture. `GET_STATUS` from the PC got an ACK with status
0x01 (bit 6 = 0 = old bitstream, which rejects CMD 6). GroovyMAME's log: `wait_status`
timed out on the one frame where it waited (16 ms, no matching ACK); otherwise emulation
took ~17.2 ms (> 16.7) so it never waited. Switchres created 384x240 and 307x192 modes.
Next: the new mode-3 bitstream `impl/variants/gwline_mode3_240p_15k_x4_27mhz_gm.fs` (also
on g4ge:~/groovy_tang/), which has the conformance fixes and the SWITCHRES frame size.

## First picture from GroovyMAME (2026-10-30)

Same run after flashing `gwline_mode3_240p_15k_x4_27mhz_gm.fs` on g4ge (GET_STATUS from
the PC: status 0x41, bit 6 = 1): **GroovyMAME's Sonic 2 shows on the 15 kHz CRT** through
the HDMI->VGA converter (user: "ça marche !"). Patches applied in the fork: rgb565 and
pacing. Known defect: the picture is shifted, because the FPGA raster still uses its own
fixed mode-3 timings (1716 x 262 at 27 MHz, syncs at 1360/243) and ignores the porches
and totals of the CMD_SWITCHRES modeline (only its active size is used). Next: drive the
raster from the modeline (open item 4).

User feedback on that run: **picture quality good** (apart from the shift). **Audio
crackles a little in the treble** - not investigated; leads: underruns / buffer level
(UART `AU=` / `AL=`, not read during the run: the UART is on g4ge), the PC-vs-FPGA clock
drift (status item 1), or the PT8211 itself (a non-oversampling DAC with no reconstruction
filter: images above Nyquist sound harsh on treble; the earlier idle hiss already showed
the analog stage needs filtering). **Interlaced modes do not work at all** - expected,
interlace is not implemented yet (status item 5).

More feedback from the user on the same run: centring wrong (known: fixed raster
timings). **Input lag** still to measure. **Inputs cannot go back from the board to the
PC**: Groovy_MiSTer sends the MiSTer's joysticks/keyboard to the host (the protocol's
input packets), but the Tang Primer 20K Dock has no USB host port for pads. Possible
later alternative: arcade controls (buttons/sticks or a JAMMA harness) wired to free Dock
pins and sent as protocol input packets.

**Correction (user, same evening): that run was WITHOUT `-mister_pacing`, and it looked
fine.** Not a contradiction: Switchres picked a 384x240 mode, and a 384-px RGB565 line
takes 64.2 us on the wire, i.e. the 15 kHz raster's 63.6 us almost exactly - the burst is
naturally paced (the writer even loses ~2 lines over a frame). The simulation showed an
overflow for 384 because the bench raster is 720p (66.7 us per source line). Narrower
modes are where pacing matters, on the 15 kHz raster too:

| Width (RGB565) | Wire time / line | Writer gain over 240 lines (15 kHz) |
|---|---|---|
| 256 | 42.8 us | ~79 lines: overflows the 32-line ring |
| 320 | 53.5 us | ~38 lines: overflows |
| 384 | 64.2 us | ~-2 lines: fine without pacing |

To check on the hardware: a 256- or 320-wide mode without `-mister_pacing` (expect
glitches in the lower part of the picture), then with it.

## Raster from the modeline: VIDEO_MODE 4 (2026-11-01, HW: works)

**HW (2026-11-01, user):** works, better than the fixed raster ("ça marche mieux"), but the
porches look very large. Measured: they are exactly GroovyMAME's modeline, not ours. Its
`-v` log: `384x240_60 15.66 kHz 7.83 MHz 384 400 437 500 240 242 245 261` (and 384x448i
`... 448 467 473 523 interlace`), i.e. front porch 2.04 us, sync 4.73 us, back porch
8.05 us = switchres' default `arcade_15` crt_range (2.000, 4.700, 8.000): only 77 % of
the line is active. GroovyMAME was not using the user's own crt_range (options
`monitor` / `crt_range0` in its own ini or on the command line). FPGA side, read with
`tools/gm_test_sender.py --host 192.168.15.14 srresult`: pclk 7804 kHz x4 = 31216 kHz,
rPLL idiv 9 / fbdiv 52 / odiv 4 -> 31200 kHz (0.05 %), h_total 1995 for 1996: correct.
First HW run of the dynamic rPLL outside 720p/480p.

**The real cause of the narrow picture: `-aspect 4:3` is needed.** With `-video mister`,
GroovyMAME still gives switchres the PC DESKTOP's aspect as the monitor aspect
(`switchres_module.cpp:243`, `monitor->aspect()`); on a 16:10 desktop switchres widens
every mode by `monitor_aspect / (4/3)` = 1.2 (`3rdparty/switchres/modeline.cpp:172`,
`aspect_corrector`): the game asks 320x224, switchres builds 384x224 at scale 1.0, and the
320-px picture sits in the middle of a 384-px mode with 32 black pixels each side. With
`-aspect 4:3`: `get_mode(0) 320 240 60 1.333333`, modeline `320x224 6.725 MHz 320 352 383
430 224 232 235 261` (user's crt_range). This is HACK no. 4 of the setup (see the recap
at the top). Proper fix for the fork: ignore the desktop aspect for `-video mister` (the
real screen is the CRT behind the FPGA).


Until now the raster ignored the CMD_SWITCHRES timings (only the active size was used), so
the picture position could not come from the host. With `VIDEO_MODE 4` the FPGA runs the
modeline itself, like Groovy_MiSTer: **porches, sync widths, totals and interlace come from
GroovyMAME's switchres** (so from the user's `switchres.ini` / `crt_range`), and centring
is done there, not in the FPGA. Bitstream: `gwline_mode4_modeline.fs`.

How (`rtl/core/groovy_modeline_ctl.v`, `gwline_top.sv`):

- **Pixel clock = pclk x N** through the dynamic rPLL (`rpll_tmds_dyn`, HW-proven in
  `rtl/board/tang_primer_20k/video/`), N = smallest factor with pclk x N >= 25 MHz (the
  HDMI floor, `superres_factor.v`), coefficients from `groovy_pll_solver`.
- **h_total is recomputed on the clock really obtained**: the integer rPLL from 27 MHz
  misses most clocks by up to ~0.8 %, so `h_total = round(htotal x N x achieved / target)`.
  The line rate, and the refresh rate the game runs at, then match the modeline within one
  pixel clock per line (sim: 0.001 to 0.04 %, against up to 0.75 % without it). The extra
  or missing pixel clocks land in the back porch.
- **Horizontal replicate N is now any integer** (the ring reader counts columns instead of
  shifting), e.g. 256 px x 5 = 1280.
- **Seamless when the PLL does not change**: e.g. 320x240p <-> 320x448i at the same pclk
  only reloads the timing registers at a frame boundary (no reset, the HDMI sink does not
  resync). A new PLL setting holds the pixel domain in reset for 2.5 ms (the dynamic
  rPLL's LOCK never asserts, so a fixed settle like `groovy_video_dyn_top`).
- **The ring is cleared on every CMD_SWITCHRES** (all modes): its lines belong to the old
  geometry (a wider new mode showed stale columns on the right edge for a field).
- Boots with the mode-3 raster (240p 15 kHz at 27 MHz) until the first modeline.
- Syncs are negative (the protocol's modeline has no polarity fields; MiSTer's are
  negative too).

Sim (`sim/tb/gwline_modeline_tb.sv`, stream `gen_gwline_stream.py --modes ...`): four
modelines in a row - 320x240p @ 6.7 MHz, 320x448i @ 6.7 MHz (no reset), 384x224p @ 8 MHz
(new PLL, one reset), 256x224p @ 5.37 MHz (N = 5). For each: N, active width, HSYNC
position and width, real-time line period, lines per field (263/262 interlaced), active
lines and VSYNC line all match the modeline; every frame is shown pixel-exact; no wrong
pixel ever. Gowin build: timing met (+4.2 ns worst setup).

Limits: still the 512-column ring (a 640-wide mode is cut); serration/equalising pulses
not generated; the converter must accept each new pixel clock (it resyncs on a PLL
change). Not HW-tested: the dynamic rPLL settings other than 720p/480p (bring-up) have
never run on the board.

## Interlace (implemented 2026-10-31, HW-confirmed 2026-11-01)

**HW result (2026-11-01, user):** Sonic 2 (Genesis, 2-player mode) on the 15 kHz CRT through
the HDMI->VGA converter, bitstream `gwline_mode3_240p_15k_x4_27mhz_gm_il.fs`: the game
switched to **320x448i** and it works very well; the progressive <-> interlaced switches
are seamless ("d'une fluidité juste incroyable"). So the converter passes 15 kHz
interlace through, and the field order is right.

Why it "did not work at all" on the first run: GroovyMAME's `-mister_interlaced_fb`
defaults to 1, which means **each blit is ONE field** (`vactive/2` lines,
drawnogpu.cpp: `nogpu_blit(m_frame, m_width, m_height / interlace_factor)`), and the
CMD_SWITCHRES modeline says `interlace = 1`. The FPGA ignored the flag and waited for
`vactive` lines per blit: every blit swallowed the next one and timed out.

What the client expects (Groovy_MiSTer `rtl/vga.v`, drawnogpu.cpp):

| Item | Groovy_MiSTer semantics | gwline now |
|---|---|---|
| Blit size | `interlace = 1`: one field = `H x V/2`; `= 2`: whole frame, the core drops every other line | `= 1`: one field, shown like a progressive frame of `V/2` lines. `= 2`: consumed whole (stream stays in step) but not displayed correctly (needs 2x the bandwidth) |
| Frame counter | `vga_frame` steps once per **field** | the same (our raster "frame" is a field) |
| ACK status bit 5 (`VGA_F1`) | field being scanned: 0 = even lines, 1 = odd | `field` from the raster |
| ACK vCount | in **frame** lines: `v_cnt` runs 0,2,4.. (even field) or 1,3,5.. (odd) | `2 * field line + field` while the modeline is interlaced |
| Which field the client sends | `m_field = F1 ^ ((m_frame - frame_gpu) % 2)`: the parity of the field that will scan frame `m_frame` | nothing to do on our side |
| Pacing | `lines_to_wait = ((frame_req - frame_gpu) * vtotal + vcount_req - vcount_gpu) / 2`, `vtotal` = 525 | consistent with the two rows above |

The raster (VIDEO_MODE 2/3 only, `rtl/generic/video/video_timing_gen_il.v`): fields of
263 lines (top, even source lines, VSYNC starting and ending half a line late) and 262
lines (bottom, odd lines, line-aligned VSYNC), so VSYNC starts are exactly 262.5 lines
apart (checked in `sim/tb/video_timing_gen_il_tb.v`). The field after the half-line VSYNC
is drawn half a line lower, as with CEA-861 480i. The 720p and 480p rasters stay
progressive and simply show each field (bob, no half-line offset).

Bandwidth: one field per raster field, so an interlaced mode costs exactly what the
progressive mode of the same width costs: 320-wide fine in RGB565, RGB888 as limited as
in progressive. A 640-wide interlaced mode is out of reach (147 Mbit/s in RGB565) and is
cut at the ring's 512 columns anyway.

Sim (`gwline_top_e2e_tb.sv +GM +IL`, stream `gen_gwline_stream.py --groovymame
--interlace`): an RGB888 320x480i stream passes (no timeout, every ACK right, vCount
doubled; the same check without `+IL` fails, as it must). The RGB565 interlaced stream
gives exactly the same numbers as the progressive 320x240 RGB565 stream (both overflow
the ring when sent unpaced in the 720p bench, a known, pre-existing limit).

HW test to do: bitstream `gwline_mode3_240p_15k_x4_27mhz_gm_il.fs` (VIDEO_MODE 3), an
interlaced game, no extra option (`-mister_interlaced_fb 1` is the default). Open
questions: does the HDMI->VGA converter pass a 15 kHz interlaced signal through
untouched (DVI has no interlace flag; the sink sees only the half-line VSYNC); is the
field order right on the tube (if the picture "combs" or lines are swapped pairwise, the
fix is to swap which field gets the half-line VSYNC); no serration/equalising pulses yet.

## Pacing bug: the rate could only go down (2026-11-01, fixed in the patch, not HW-tested)

First real run of `-mister_pacing 1.0` (the earlier runs had `fq_codel`, which ignores the
rate, so pacing never acted): sound glitches, the picture never complete, every
`wait_status` a timeout. GroovyMAME's log: rates right (`pacing 10347860` for 320x240,
`8246692` for 256x192, then `10295092` for 320x224), but the ACK vCount drifted ~24
lines later every frame (206, 229, 256, 21 of the next frame...) until the ACKs came too
late and the sync was lost; `tc -s qdisc` showed 24 436 packets dropped by `flow_limit`.
Cause, reproduced on the 5800X with a GroovyMAME-like load (101 datagrams per frame at
59.92 Hz): Linux's `SO_MAX_PACING_RATE` sets `sk_pacing_rate = min(sk_pacing_rate, new)`
and nothing raises it again on a UDP socket, so after the 256-px mode the 320-px one
stayed at 8.25 MB/s for ~9.0 MB/s of data. At one fixed 10.35 MB/s rate the backlog
drains every frame (no drop); set 8.25 then 10.35 and it grows every frame. Fix: recreate
the socket (same local port, the FPGA answers there) when the rate must go up -
`patches/groovymame-mister-pacing-raise-fix.patch` on the fork as it is.

Also learned: the qdisc is not persistent; after a reboot it is `fq_codel` again and
`-mister_pacing` silently does nothing (the 320-px modes then overflow the ring: a black
horizontal band in the middle of the picture, top and bottom quarters fine).

## Pacing on Windows and macOS (discussion 2026-10-31, nothing implemented)

`SO_MAX_PACING_RATE` and the fq qdisc are Linux-only.
- **Windows**: the QoS API (qWAVE, `QOSSetOutgoingRate`) shapes one UDP flow through the
  OS packet scheduler, the closest equivalent (sendto still returns at once). Its
  shaping granularity is unknown: if it releases ~1 ms bursts, that is ~16 lines, half the
  ring. To measure before relying on it.
- **macOS**: no per-socket pacing; dummynet (`dnctl`/`pf`) shapes the whole machine,
  needs root - not recommended.
- **Portable answer: a sender thread in GroovyMAME.** The emulation thread copies the
  frame into a buffer and returns; the sender thread sends chunks of 4-8 lines
  (0.25-0.5 ms) at the raster's pace (high-resolution waitable timers on Windows 10+,
  precise timers on macOS, a short spin as last resort). Same code on all three OSes;
  fq stays a zero-CPU option on Linux.
- FPGA side, client-independent: ring-writer back-pressure (udp.sv's 8 KB RX FIFO absorbs
  ~12 lines of jitter) and/or a bigger ring.
- The frame-delay constraint (fd >= ~8.9 at 262 lines) comes from the ring size, not
  the OS.

## RGB888 is a link-throughput problem, not a buffering one (user, 2026-10-31)

The ring stores RGB565 whatever the wire format (blit_rx converts), so a bigger ring or
pacing only addresses RGB565, whose burst arrives TOO FAST. Raw RGB888 at 320x240@60
needs 116 Mbit/s on the wire, more than the Dock's 100: each frame takes ~19 ms while one
comes every 16.7 ms, the delay grows frame after frame and no buffer can fix it. Raw
RGB888 only fits up to ~256 px wide (256x224: 86 Mbit/s, 256x240: 92 Mbit/s). Beyond
that, RGB888 needs compression.

## Compression: QOI, not LZ4 (user decision, 2026-10-31)

LZ4 is dropped as too complex to handle here (64 KB back-references across a frame, while
the ring keeps 32 lines). **QOI** ("Quite OK Image" format) is the chosen codec; a Verilog
implementation already exists: **amstan/qoi-fpga** (github.com/amstan/qoi-fpga, Alexandru
M Stan, 2022-2023; `verilog/qoi_decoder.v` 127 lines, `qoi_encoder.v` 140 lines).
Reviewed 2026-10-31:
- **licence: none.** The repo is a fork of phoboslab/qoi (MIT, whose C files keep their
  MIT header), but it has no LICENSE file, GitHub reports no licence, and the two Verilog
  files carry no header. By default that means all rights reserved: we cannot vendor them
  as they are. Either ask the author to add a licence (MIT like the parent would be the
  natural choice), or write our own decoder from the public QOI specification and use
  theirs only as a cross-check.
- **fit**: a complete decoder, 1 pixel per clock (all QOI_OPs, run handled by holding
  the chunk), consuming a 5-byte window with a `chunk_len_consumed` count, so it needs a
  byte-stream front end. The 64-entry colour index is a 64 x 32-bit register array with
  a combinational read and a one-cycle reset: convenient for a per-line state reset,
  but ~2k flip-flops plus wide muxes on the GW2A-18 (24-bit entries without alpha would
  cut that). Written in SystemVerilog (array ports, `signed'()`, `'{default: 0}`, `--`),
  to check against Gowin's synthesis.
- the encoder is not needed on the FPGA: the client side (GroovyMAME) can use the MIT
  reference `qoi.h`. The
protocol already reserves it: `groovy_features.v` advertises compression bit 3 = QOI.
Design points to settle when it starts:
- reset the QOI state (previous pixel, 64-entry colour index) at each line or datagram, so
  every datagram decodes on its own (a lost datagram costs only its own lines) and the
  decoder fits the beam race with no frame history;
- worst case QOI expands (QOI_OP_RGB = 4 bytes per pixel): a per-line raw fallback keeps
  the wire time bounded;
- compressed lines arrive even faster than raw RGB565, so pacing / back-pressure matter
  MORE, not less;
- client side: a GroovyMAME encoder (per line, cheap) + negotiation through GET_FEATURES
  and the CMD_INIT compression byte, without breaking stock MiSTer (which only knows 0/1).
