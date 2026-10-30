# Driving gwline from GroovyMAME (2026-10-30)

What it takes to run the real GroovyMAME client (`-video mister`, its own nogpu client in
`src/osd/modules/render/drawnogpu.cpp`) against the gwline BRAM line ring over the Tang
Primer 20K Dock's 100 Mbit Ethernet. Protocol conformance itself is in
`docs/protocol_conformance_2026-10.md`.

## Setup recap: the three "hacks" that make it work (2026-10-30, HW-confirmed on the CRT)

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

Plus, on the FPGA side, a bitstream with the conformance fixes (commit 0f317be or later;
`GET_STATUS` status bit 6 = 1 proves it) and, for the CRT, VIDEO_MODE 3
(`impl/variants/gwline_mode3_240p_15k_x4_27mhz_gm.fs`). And the PC's address on the
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
