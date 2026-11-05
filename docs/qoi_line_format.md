# QOI line format (draft for review, 2026-11-05)

Status: **proposal, nothing implemented**. To be validated by the user, and the protocol
points (marked OPEN) to be agreed with Calamity before GroovyMAME sends it.

## Goal and constraints

- Lossless compression of the CMD_BLIT payload, so a beam-racing receiver on a 100 Mbit
  link keeps up with wider modes (512-px SNES / PC Engine modes in RGB565) and keeps a
  margin when the LAN is busy.
- **Works for every pixel format of CMD_INIT**: RGB888 and RGB565 (RGBA888: see OPEN 4).
  The coding adapts to the channel widths of the format.
- **Decodable line by line**: the receiver has no frame buffer (a 16..32-line ring), so
  every line is decoded on its own, as it arrives, at the raster's pace.
- **Reusable**: the C reference and the Verilog decoder must not depend on the Tang
  Primer 20K or on Gowin (the user has another FPGA in view). See "Reuse rules".

## Why QOI, and what changes from standard QOI

QOI (qoiformat.org, specification public, reference code MIT) codes each pixel against the
previous one and a 64-entry cache of recent colours: 1 byte for a repeat run, a cached
colour or a small difference, 2 bytes for a larger luma difference, otherwise the pixel in
full. It catches the flat areas, the dithering (two colours alternating: both stay in the
cache) and the gradients of 2D consoles, and its decoder is a few hundred LUTs.

Measured so far (`docs/groovymame_client.md`, "Measured 2026-11-05"): 3.59x overall on a
lossless PS2 recording, but too many heavy lines for 640-px RGB888 3D games. 2D consoles
before the PS1 need at most RGB565 (SNES 15-bit, PC Engine and Mega Drive 9-bit), so this
format targets them first; it is not measured on 2D material yet.

Changes from standard QOI, all needed for the line-by-line receiver:

1. **State reset at every line**: previous pixel and cache restart at each line, so a lost
   or late line never corrupts the next ones.
2. **No file header, no end marker**: the width comes from CMD_SWITCHRES, the format from
   CMD_INIT. A 2-byte line header gives the coded length (below).
3. **Channel widths follow the pixel format** (RGB565: 5, 6, 5 bits). The QOI operations
   work on the channel values themselves, modulo 2^width. With RGB888 every line is
   coded exactly as standard QOI would code it, so standard `qoi.h` can check the encoder.
4. **No alpha** (the receiver outputs RGB): `QOI_OP_RGBA` is never sent.
5. **Raw fallback per line**: if the coded line is not shorter than the raw one, the line
   is sent raw. The worst case is then the raw size + 2 bytes per line.

## Line layout

```
line   := header payload
header := 2 bytes, little-endian
          bit 15     = 1: payload is the raw line (width x bytes per pixel, CMD_INIT format)
                       0: payload is QOI-coded
          bits 14..0 = payload length in bytes (1..32767)
```

The lines of a field/frame follow each other in the CMD_BLIT payload, across datagram
boundaries, exactly like raw pixels today. The receiver knows where each line ends from
the header (and checks it against the pixel count: a mismatch = corrupted line, shown as
the "bad line" colour, the next header is still found by the length).

## Pixel coding (QOI payload)

Per line, before the first pixel: `prev = (0, 0, 0)`, the 64 cache entries empty (no
entry matches before it has been written, as in QOI where the cache starts with alpha 0).

Channel widths `wr, wg, wb`: RGB888 = 8, 8, 8; RGB565 = 5, 6, 5. Differences are taken
modulo 2^w and read as signed values (`vr = (r - prev.r) mod 2^wr`, in `-2^(wr-1)..2^(wr-1)-1`).

For each pixel, in this order (the standard QOI order):

| Condition | Code | Bytes |
|---|---|---|
| pixel == prev | `QOI_OP_RUN` `11rrrrrr`, run 1..62 (bias -1); a run ends at 62 or at the end of the line | 1 per run |
| cache[hash] == pixel | `QOI_OP_INDEX` `00iiiiii` | 1 |
| vr, vg, vb all in -2..1 | `QOI_OP_DIFF` `01 rr gg bb` (bias +2) | 1 |
| vg in -32..31, and vr - vg', vb - vg' in -8..7 | `QOI_OP_LUMA` `10gggggg` (bias +32), then `rrrrbbbb` (bias +8) | 2 |
| otherwise | `QOI_OP_RGB` `0xFE`, then the pixel in the CMD_INIT format (RGB888: r, g, b; RGB565: 16-bit little-endian) | 4 (RGB888) / 3 (RGB565) |

- `hash = (r * 3 + g * 5 + b * 7 + 255 * 11) mod 64`, on the channel values in their own
  width (for RGB888 it is the standard QOI hash with alpha 255).
- `vg'` is the green difference in red/blue units: `vg` for RGB888; for RGB565
  `vg' = vg >> 1` (arithmetic), because green has one more bit: a grey step (+1 red,
  +2 green, +1 blue) then gives vr - vg' = vb - vg' = 0. **OPEN 1**: to be compared on
  real material against `vg' = vg` before freezing it.
- After any pixel that is not part of a run, `cache[hash(pixel)] = pixel`; `prev = pixel`.
  The decoder does the same for every pixel it outputs (QOI rule).
- `0xFF` (`QOI_OP_RGBA`) is reserved: a decoder that meets it marks the line bad.

## Protocol

- **OPEN 2**: compression code in CMD_INIT (GroovyMAME sends 1 for lz4, 2 for lz4hc today;
  QOI needs its own value, to be agreed with Calamity so it never clashes with a future
  Groovy_MiSTer codec).
- **OPEN 3**: CMD_BLIT keeps its compressed-size field (`cSize` = bytes of the whole
  field/frame payload, headers included), as for LZ4. The receiver's frame-done logic then
  counts bytes, not pixels.
- Negotiation: our CMD_GET_FEATURES already reserves compression bit 3 = QOI.
- **OPEN 4**: RGBA888 (4 bytes per pixel in Groovy_MiSTer). Proposal: code as RGB888 and
  drop alpha (nothing displays it); or keep QOI_OP_RGBA for it.

## Sending (pacing)

With compression the lines no longer have the same size, so the constant-rate kernel pacing
(`-mister_pacing`, bytes per second) would deliver simple lines early and heavy ones late.
Lines must be sent at the raster's line times instead: part of the planned send-time patch
(GroovyMAME, separate patch file).

## Reuse rules (C and Verilog)

- **C reference** (`tools/qoiline/` planned): one encoder + one decoder, plain C99, no
  dependency, used three ways: by the GroovyMAME patch (encoder), by the measurement tool,
  and as the golden model of the Verilog tests.
- **Verilog decoder** (`rtl/generic/compression/qoi_line_decoder.v` planned):
  - Verilog-2001, no vendor primitive, no SystemVerilog, synchronous reset;
  - byte stream in and pixel stream out with valid/ready handshakes, so it fits any
    receiver (a line ring, a frame buffer, another network stack);
  - the pixel format (888 / 565) and the line width are inputs, so one build handles both;
  - the 64-entry cache as an inferred register array (or a small RAM), no FPGA-specific
    memory;
  - throughput: at least one byte per clock in and one pixel per clock out on runs, far
    above the 100 Mbit link (12.5 MB/s) and a 640-px line every 63.6 us (10 Mpixel/s);
  - self-checking testbench against the C reference, runnable with Icarus Verilog.
- The board-specific part (where decoded pixels go, the CMD_BLIT size, the UART counters)
  stays in the board top.
