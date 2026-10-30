# Groovy_MiSTer protocol conformance audit (2026-10-30)

What gwline (the BRAM line-ring receiver) does today, checked against the three reference
implementations. It supersedes the "Reconciliation" table of `protocol_verified.md` where
they differ (that table assumed GroovyMAME uses CMD 7: it does not).

| Reference | Where | Version read |
|---|---|---|
| MiSTer receiver (HPS) | `psakhis/Groovy_MiSTer` `hps_linux/src/support/groovy/groovy.cpp` | `109908c` (2024-09-23, unchanged since) |
| MiSTer core RTL | same repo, `Groovy.sv`, `rtl/vga.v`, `rtl/hps_ext.v` | same |
| Client library (RetroArch, Dolphin...) | same repo, `api/groovymister.cpp` | same |
| **GroovyMAME** (the real client) | `antonioginer/GroovyMAME` `src/osd/modules/render/drawnogpu.cpp` | `e0146b0` (2024-04-25); the user's fork `4ce01b9` (2026-10) is identical here |

## Two clients, two dialects

GroovyMAME does **not** use the `groovymister` library; it has its own client (`drawnogpu.cpp`):

| | GroovyMAME (`drawnogpu.cpp`) | `groovymister` API |
|---|---|---|
| CMD_INIT | **4 bytes** `{2, lz4, rate, chan}`: no rgbMode, so **RGB888** | 5 bytes, rgbMode 0/1/2 |
| Blit | **CMD_BLIT_VSYNC = 6, always 11 bytes** `{6, frame u32, vsync u16, cSize u32}` (cSize = 0 when raw) | CMD_BLIT_FIELD_VSYNC = 7 (8/9/12/13 bytes) |
| Waits for | ACK after INIT (1000 ms), then the ACK whose `frame_req == m_frame` after every blit | ACK after INIT (60 ms), ACKs read opportunistically |
| Raster sync | `lines_to_wait = (frame_req - frame_gpu) * vtotal + vcount_req - vcount_gpu` | `DiffTimeRaster()`: `((frameEcho-1)*vTotal + vCountEcho) - (frame*vTotal + vCount)` |
| Audio | sent only if ACK status **bit 6 (FPGA_AUDIO)** was set | same (`CmdAudio` returns if `!fpga.audio`) |
| Compression | option `mister_compression` none (default) / lz4 / lz4hc | `lz4Frames` 0..6 |
| GET_VERSION | never sent | commented out |

Every test so far used `tools/gm_test_sender.py`, which speaks the API dialect (CMD 7 +
RGB565). **The real GroovyMAME has never been exercised against gwline.**

## Reference semantics that matter

- **Frame counter** (`rtl/vga.v`): `vga_frame` counts vblanks, reset by CMD_INIT; it
  increments once per frame at the start of the first active line; frame N is displayed
  while `vga_frame == N` (blits with `frame <= vga_frame` arriving in vblank are discarded
  as late, `Groovy.sv:966`). GroovyMAME numbers its frames from 1 after INIT (the first
  emulated frame is skipped), and re-aligns `m_frame = frame_gpu + 1` when it falls behind.
- **vCount**: raster line in **source (modeline) lines**, 0 = first active line, up to
  vTotal-1; the HPS reports line 0 as vTotal during vblank (`groovy.cpp:456-470`).
- **Status byte**: b0 vram_ready, b1 vram_end_frame, b2 vram_synced, b3 frameskip,
  b4 vblank, b5 field (interlace), **b6 audio = the core's "audio enabled" OSD option**
  (not "currently playing"), b7 vram_queue > 0. GroovyMAME reads only b5 (field) and b6.
- **GET_VERSION**: one-byte reply, `GROOVY_VERSION = 1`.
- **Loss recovery** (`groovy.cpp:1928-1981`): while receiving pixels or audio, a datagram
  shorter than 1472 that does not end the transfer exactly aborts it; if it is <= 26 bytes
  it is re-parsed as a command. There is no timer.

## Findings

| # | Item | gwline today | Severity |
|---|---|---|---|
| 1 | CMD_BLIT_VSYNC (6), 7 or 11 bytes | **rejected** as bad packet | **Blocking**: GroovyMAME shows nothing |
| 2 | ACK `frame` (GPU frame counter) | constant **0** | **Blocking**: GroovyMAME computes `lines_to_wait = frame_req * vtotal + ...` and waits seconds-to-hours per frame |
| 3 | ACK `vCount` | output-side ring line (`src_line_wr`), not checked against the "0 = first active source line" rule | Must match #2 |
| 4 | ACK status bit 6 (audio) | = "audio playing" | **Blocking for sound**: a stock client waits for bit 6 before sending any audio, and we only set it once audio has arrived (deadlock) |
| 5 | Raw RGB888 bandwidth (GroovyMAME's only raw format) | ring + 100 Mbit PHY | **Blocking for most games**, see below |
| 6 | Per-mode frame size | `bytes_len` fixed to 320x240 | **Blocking**: every game has its own resolution (CMD_SWITCHRES) - this is open item 4 (dynamic geometry) |
| 7 | LZ4 (`mister_compression lz4`) | not decoded | Needed if #5 is solved by compression (open "compression plan") |
| 8 | Loss recovery | 8 ms idle timeout | Differs: the reference aborts on the first short datagram that does not complete the transfer and re-parses it as a command. Ours eats following commands as pixels until the timeout. Plausible cause of the "isolated short frames" |
| 9 | GET_VERSION | parsed, **no reply** | Minor (no client sends it today) |
| 10 | Interlace (SWITCHRES `interlace` 1/2, field via ACK b5) | ignored | Open item 5 |
| 11 | Our extensions (GET_FEATURES 9, GET_SWITCHRES_RESULT 10, SET_BEACON 11) | only answer when asked | OK: no stock client sends 9-11, the reference ignores unknown commands (logs them) |
| 12 | INIT 4/5 bytes, SWITCHRES 26 bytes, AUDIO 3 bytes, CLOSE, GET_STATUS -> ACK(0,0), INIT -> ACK(0,0), no ACK after SWITCHRES/AUDIO/CLOSE | as reference | OK |
| 13 | Little-endian 13-byte ACK layout | as reference | OK |

### #5 - why raw RGB888 does not fit the 100 Mbit beam race

The Dock's PHY (RTL8201) is 100 Mbit; MiSTer is 1 Gbit. With 1472-byte payloads one
datagram costs 1538 bytes on the wire (x1.045).

| Mode (60 Hz) | RGB888 | RGB565 |
|---|---|---|
| 256x224 | 86 Mbit/s | 58 |
| 320x224 | 108 (too much) | 72 |
| 320x240 | 116 (too much) | 77 |
| 384x224 | 130 (too much) | 86 |
| 640x240 per field (480i) | 231 (too much) | 154 (too much) |

The beam race is stricter than the average rate: one 320-px RGB888 line takes 80 us on the
wire against a 63.6 us raster line (15 kHz), so the writer loses ~62 lines of lead over a
frame while the ring holds 32. In RGB565 the same line takes 53 us: it keeps up (this is
what every test so far used).

Ways out (decision for the user):
- **(a) RGB565 from GroovyMAME**: a small client patch (INIT 5 bytes with rgbMode 2 and
  2-byte pixels) - already part of the protocol and supported by the MiSTer core. Covers
  up to ~384 wide at 15 kHz; not 480i fields.
- **(b) LZ4**: no client change (`-mister_compression lz4`), but the FPGA must decode LZ4
  on the fly. A whole-frame LZ4 block may reference up to 64 KB back (~68 lines of 320
  RGB888) while the ring holds 32 lines in RGB565: needs a separate RGB888 history window
  in BSRAM, and the compressed rate is content-dependent (worst case not guaranteed).
- **(c) Both**: (a) now, (b) later for the modes (a) cannot carry.

### Pacing note

GroovyMAME sends a whole frame in one burst, starting when the raster reaches its vsync
scanline (`vtotal * frame_delay + 1`, automatic frame delay by default) of the previous
frame. MiSTer stores whole frames, so any start line works there; our 32-line ring needs
the burst to start at most ~32 lines before the raster's top of frame. Whether the
automatic frame delay lands there has to be measured with GroovyMAME on the board.

## Fixed 2026-10-30 (sim-validated, not yet HW-tested)

- **#1** `groovy_packet_parser.v` accepts CMD_BLIT_VSYNC (6), 7 or 11 bytes (lz4 = cSize != 0).
- **#2/#3** `gwline_top.sv` `gpu_frame`: cleared by INIT/CLOSE, preset to F-1 by the first
  blit F, +1 at every raster top of frame. vCount = raster source line when the command is
  parsed (0 = first active line). e2e bench: GPU frame 0,1,2,3 for one blit per video frame
  and 0,2,4 for one every other frame; vCount equal to the raster line at the header.
- **#4** ACK status bit 6 = 1 (the jack is always available). The beacon keeps bit 6 =
  playing.
- **RGB888 byte order** (found on the way): the wire carries **B,G,R** (MiSTer core
  `{r,g,b} <= word64[23:0]`, GroovyMAME copies MAME's little-endian ARGB). `groovy_blit_rx`
  read R,G,B: red and blue were swapped. Fixed + unit test.
- e2e bench: `gen_gwline_stream.py --groovymame` + `+GM` speak GroovyMAME's dialect (4-byte
  INIT, CMD 6, B,G,R bytes in 1472-byte datagrams, back to back with the 96-bit Ethernet
  IFG). Result: every frame decoded pixel-exact until the raster overtakes the RGB888
  writer, ~111 source lines in (#5 confirmed in simulation).

New findings while testing:
- **#14 GET_STATUS bursts**: requests that arrive while an ACK is still being sent are
  dropped (`groovy_ack_policy` ignores the trigger while `ack_busy`): 12 back-to-back
  requests gave 3 ACKs. The reference answers every one. GroovyMAME does not burst, but a
  queued trigger would be more faithful.

## Fix order proposed

1. CMD_BLIT_VSYNC (6) in the parser (7/11 bytes; cSize only when INIT asked for LZ4).
2. ACK: a reference-style `vga_frame` counter and vCount; status b6 = audio output
   available; reply to GET_VERSION with 1.
3. Loss recovery by datagram length, like the reference (keep the timer as a backstop).
4. Dynamic frame size from SWITCHRES (bytes per frame, line width) - start of open item 4.
5. The #5 decision: RGB565 client patch and/or LZ4 decoder.
6. Then a real GroovyMAME run on the board.

1-3 are small and testable in the existing e2e bench; the generator needs a GroovyMAME
dialect mode (`gen_gwline_stream.py`) so the bench speaks exactly what `drawnogpu.cpp` sends.
