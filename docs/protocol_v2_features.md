# Groovy protocol v2.0.0 extension — CMD_GET_FEATURES

A backward-compatible capability/version negotiation command, added by Groovy_Tang.
v1.0.0 (current upstream Groovy_MiSTer) has no such command; a v1.0.0 client never
sends it, and the receiver only answers when asked — so this does not break the
strict v1 compatibility of the existing commands (see `protocol_verified.md`).

## Versioning
- **Protocol version 1.0.0** = the commands verified in `protocol_verified.md`
  (CMD 1..8). No feature negotiation.
- **Protocol version 2.0.0** = v1 + `CMD_GET_FEATURES`. A receiver that answers
  `CMD_GET_FEATURES` declares itself ≥ 2.0.0 and reports exactly what it supports,
  so the PC side can pick a compression codec / behavior at runtime instead of
  assuming.

## Request — `CMD_GET_FEATURES` (command code 9), 1 byte
```
[0] = 9
```
Sent to the data port (32100), like the other control commands. Command code 9 is
unused by v1.0.0 (which defines 1..8; 6 is the deprecated CMD_BLIT_VSYNC).

## Reply — 12 bytes, little-endian
```
off 0..3  magic = 'G','T','F','1'  (0x47 0x54 0x46 0x31)   # identifies this reply
off 4     proto_major   (= 2)
off 5     proto_minor   (= 0)
off 6     proto_patch   (= 0)
off 7     compression bitfield:  b0 RAW   b1 LZ4   b2 RLE   b3 QOI   (b4..7 reserved)
off 8     rgb_modes   bitfield:  b0 RGB888 b1 RGBA888 b2 RGB565      (b3..7 reserved)
off 9..11 reserved (0)
```
- The **magic** makes the reply self-identifying (the other replies — 13-byte ACK,
  1-byte version — have no magic; the client tells them apart by what it asked).
  It also future-proofs against a longer reply: a client may read ≥ 12 bytes and
  ignore trailing fields it doesn't understand.
- **compression** advertises only codecs the receiver actually implements. RAW is
  always set. Groovy_Tang sets LZ4/RLE/QOI bits as each lands (LZ4 = roadmap
  Phase 8; RLE/QOI = later). The values are build parameters of
  `rtl/core/groovy_features.v` — keep them truthful.
- **rgb_modes** mirrors the CMD_INIT rgbMode codes (0/1/2) as a bitfield.

## Implementation
- Decode: `rtl/core/groovy_packet_parser.v` (CMD_GET_FEATURES=9 → `get_features_valid`).
- Reply:  `rtl/core/groovy_features.v` (parameterised descriptor, byte-stream out).
- The reply is sent over the UDP TX path (Milestone B). Once TX is bridged,
  `get_features_valid` triggers the descriptor exactly as INIT/GET_STATUS/BLIT
  trigger the ACK.

## Testing
- Sim: `sim/tb/groovy_features_tb.v` — drives a cmd-9 packet through the parser
  into `groovy_features` and checks the 12-byte descriptor (`make groovy_features_tb`).
- PC: `tools/gm_test_sender.py --host <ip> features` — sends `[09]`, decodes the
  reply (version + compression + rgb). Works once the TX path exists on hardware.

## CMD_GET_SWITCHRES_RESULT (command 10) — debug

A bring-up/debug query that returns the board's computed mode-change math for the
last CMD_SWITCHRES, so the host can verify pclk decode + super-res + PLL solve
WITHOUT the rPLL/video pipeline yet existing.

Request: 1 byte `[0] = 10`. Reply: 25 bytes, little-endian:
```
[0..3]  'G','T','S','R'
[4..7]  pclk_khz        (source pixel clock, from the SWITCHRES double)
[8]     superres_n      (horizontal integer scale to reach >= 25 MHz HDMI)
[9..12] pclk_out_khz    (= pclk_khz * n, the TMDS output clock to synthesize)
[13] idiv [14] fbdiv [15] odiv   (Gowin rPLL coefficients)
[16..19] achieved_khz   (what those coefficients actually produce)
[20]    ok              (locked within tolerance)
[21..22] h_total  [23..24] v_total   (echo of the parsed modeline)
```
Implemented by `rtl/core/groovy_switchres.v` (the PLL solver runs on a ~1 MHz
clock; its 32-bit divisions don't meet 50 MHz timing). Tool:
`gm_test_sender.py srresult`. This is debug scaffolding — it can be removed once
the real rPLL reconfig + video pipeline (Rung 4b+) make the result observable as
an actual clock/picture.

## CMD_BLIT line/frame HASH — proposed v2 integrity extension

**Status: PROPOSAL (not yet implemented). Motivation: see `docs/ddr3.md` byte-lane
skew + memory `ddr3-byte-lane-skew`.**

### Why
Two independent integrity gaps the current v1 protocol does not cover:
1. **Network**: v1 integrity is *length-only* — the receiver aborts a blit if the
   running byte total ≠ expected (`protocol_verified.md` "frame abort"), but a
   corrupted-but-right-length datagram passes silently.
2. **DDR3 round-trip (our actual bug)**: the framebuffer write→DDR3→read path can
   corrupt pixels (HW-confirmed byte-lane read skew). Nothing today *detects* that a
   stored line reads back wrong; we found it only by hand-decoding UART hex.

A per-line hash sent by the emulator lets the FPGA **self-verify**: store the hash in
BRAM when the line arrives, write the pixels to DDR3, then on scanout (or a verify
pass) recompute the hash from what DDR3 actually returned and compare. Mismatch =>
bump an internal counter. This turns "is the rain fixed?" into a single number, and
catches network corruption for free.

### Algorithm
**CRC-32** (IEEE 802.3 poly 0x04C11DB7) over each line's pixel bytes, in transmission
order, before any DDR3 store. Chosen because:
- On an FPGA a CRC-32 over a 16-bit (or wider) word is **fully combinational, 1 clock,
  zero added latency**, a few dozen LUTs — it runs *in parallel* with the existing
  write/read datapath, so the cycle cost is effectively zero (the real question the
  user raised: HW "CPU overhead" is a non-issue).
- Standard, well-distributed, and the emulator already links zlib/LZ4 (CRC available).
- NOTE: CRC **detects**, it does not **correct**. Our DDR3 error is *deterministic*
  (same wrong byte every read), so detect-and-retry can't recover a bad pixel — the
  hash is a *diagnostic / fix-verification* tool and a *network* integrity check, not
  a runtime repair. Repairing a whole stale byte would need heavy ECC (Reed-Solomon
  class), which costs more than fixing the PHY; out of scope.

### Wire format — two options (pick at INIT via a feature bit)
- **Per-line, inline**: the emulator appends a 4-byte CRC-32 after each line's pixels
  in the BLIT stream. Receiver strips/checks it per line. Best for localizing which
  line is bad (DDR3 debug) and bounded BRAM (one CRC in flight).
- **Per-frame, trailing**: one CRC-32 over the whole frame, sent in the BLIT tail
  (extends the `cSize`/flag tail of variants 8/9/12/13). Cheaper bandwidth, coarser.

Advertise support via a new **`integrity` bitfield** byte in the `CMD_GET_FEATURES`
reply (reserved bytes 9..11 today): `b0 CRC32_LINE  b1 CRC32_FRAME`. The PC enables
it in CMD_INIT only if the board advertises it — strict v1 clients never send hashes,
so this stays backward-compatible.

### FPGA side
- `rtl/core/groovy_crc32.v` (new): streaming CRC-32, parallel per data word.
- Line-hash BRAM: store the received CRC per line (depth = max lines, e.g. 320).
- Verify: a second CRC-32 instance on the DDR3 *read* stream; compare to the stored
  value at end-of-line; counters `crc_lines_checked`, `crc_lines_bad`, `crc_first_bad`.
- Expose the counters over the existing UART debug (pin M11, see memory
  `tang-debug-uart`) and/or in the CMD_GET_STATUS ACK spare bits — so a fix attempt is
  a one-glance pass/fail instead of pixel hunting.

### Testing
- Sim: feed a known line + its CRC, corrupt one byte in the modelled DDR3, assert the
  bad-counter increments and `crc_first_bad` = that line.
- HW: run the soak with CRC verify; report `bad/checked` over UART. Any future DDR3
  deskew fix is confirmed iff `crc_lines_bad == 0`.

## CMD_SET_BEACON (command 11) — implemented (gwline)

`[0]=11 [1]=enable`. While enabled, the receiver pushes one 16-byte datagram per video
frame when the raster enters vertical blanking, instead of being polled:

```
off 0  "GTB1"        off 4  uint32 video_frame   off 8  uint16 raster_line
off 10 uint16 good_lines (valid output lines of the last frame)
off 12 uint16 lead_top   (writer line when the raster crossed source line 0)
off 14 uint8  status     off 15 uint8 seq (wraps; gaps = lost beacons)
```
Off after reset and after CMD_CLOSE, so a v1 client never receives one. The host takes
the KERNEL receive timestamp of each beacon as its raster phase reference
(`tools/gm_test_sender.py blitrace --beacon`; HW: phase error within a few us).
RTL: `rtl/core/groovy_beacon_sender.v`.

## Audio outputs — planned (not implemented)

Noted 2026-10-24. The receiver should:
1. **Advertise** the audio outputs it has, and which one is the **default**, e.g. in the
   `CMD_GET_FEATURES` reply's reserved bytes (a bitfield of outputs + a default index):
   - **HDMI** (audio in the TMDS stream: needs an HDMI encoder with data islands; the
     current Gowin DVI_TX is DVI only),
   - **jack** (the Dock's 3.5 mm output; driver chip to be checked on the schematic).
2. **Let the client select** the output (new command, or a field of an extended
   CMD_INIT), falling back to the default when the client does not ask - a v1 client
   never asks, so it gets the default.
The audio data itself stays the v1 transport (CMD_INIT soundRate/chan + CMD_AUDIO).

## Future
This is the negotiation hook for V2+: new compression bits (RLE/QOI), new RGB
modes, integrity hashes (above), or capability flags (interlaced, audio, max
resolution) can be added as reserved bytes/bits without a new command or breaking
older clients.
