# QOI line format (2026-11-06)

Status: **implemented in simulation** (validated by the user 2026-11-06, OPEN 1 decided by
measurement), and wired into the gwline build (2026-11-06, simulated end to end, bitstream
built, **not run on hardware**). The protocol points (OPEN 2..4) stay provisional until
agreed with Calamity.

| Piece | Where | Checked |
|---|---|---|
| C reference (encoder + decoder), single header, MIT | `tools/qoiline/qoiline.h` | `make qoiline_test`: round trips, corruptions, RGB888 lines byte-identical to the reference `qoi.h` |
| per-line size tool | `tools/qoiline/qoiline_size.c` | |
| Verilog decoder, MIT | `rtl/generic/compression/qoi_line_decoder.v` | `make qoi_line_decoder_tb`: 1602 lines vs the C model, 422 corrupted, random stalls |
| GroovyMAME encoder | `patches/groovymame-mister-qoi.patch` | applies on rgb565 (+ pacing), syntax-only compile with the libretro driver flags; not run |
| gwline receiver (byte FIFO 2 KB + decoder -> ring) | `rtl/core/groovy_qoi_rx.v`, `gwline_top.sv` (`QOI=1`) | `gwline_modeline_tb +QOI` on a `gen_gwline_stream.py --qoi` stream: 3 modes x 3 frames exact, `QE=0 QO=0`; raw sessions unchanged. Gowin mode 4: clk50 58.2 MHz, pix_clk 113 MHz, BSRAM 35/46 |

On the gwline UART line, `QE=` counts corrupted QOI lines and `QO=` bytes dropped because
the FIFO was full (both should stay 0). A QOI session is one whose CMD_INIT compression
byte is 2; CMD_BLIT then gives the coded size (cSize), which ends the blit.

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
   coded exactly as standard QOI would code it (r, g, b = the true colours, whatever the
   wire order), so standard `qoi.h` checks the encoder (done in `make qoiline_test`).
4. **No alpha** (the receiver outputs RGB): `QOI_OP_RGBA` is never sent.
5. **Raw fallback per line**: if the coded line is not shorter than the raw one, the line
   is sent raw. The worst case is then the raw size + 2 bytes per line.

## Line layout

```
line   := header payload
header := 2 bytes, little-endian
          bit 15     = 1: payload is the raw line (width x bytes per pixel, CMD_INIT format,
                          byte for byte what an uncompressed blit sends: RGB888 = B, G, R;
                          RGB565 = 16-bit little-endian, R in bits 15..11)
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
A decoder meeting an index to an entry not written in this line marks the line bad (the
encoder never sends one).

Channel widths `wr, wg, wb`: RGB888 = 8, 8, 8; RGB565 = 5, 6, 5. Differences are taken
modulo 2^w and read as signed values (`vr = (r - prev.r) mod 2^wr`, in `-2^(wr-1)..2^(wr-1)-1`).

For each pixel, in this order (the standard QOI order):

| Condition | Code | Bytes |
|---|---|---|
| pixel == prev | `QOI_OP_RUN` `11rrrrrr`, run 1..62 (bias -1); a run ends at 62 or at the end of the line | 1 per run |
| cache[hash] == pixel | `QOI_OP_INDEX` `00iiiiii` | 1 |
| vr, vg, vb all in -2..1 | `QOI_OP_DIFF` `01 rr gg bb` (bias +2) | 1 |
| vg in -32..31, and vr - vg', vb - vg' in -8..7 | `QOI_OP_LUMA` `10gggggg` (bias +32), then `rrrrbbbb` (bias +8) | 2 |
| otherwise | `QOI_OP_RGB` `0xFE`, then the pixel: RGB888 r, g, b (standard QOI order, NOT the B, G, R wire order); RGB565 the 16-bit little-endian word | 4 (RGB888) / 3 (RGB565) |

- `hash = (r * 3 + g * 5 + b * 7 + 255 * 11) mod 64`, on the channel values in their own
  width (for RGB888 it is the standard QOI hash with alpha 255).
- `vg'` is the green difference in red/blue units: `vg` for RGB888; for RGB565
  `vg' = vg >> 1` (arithmetic), because green has one more bit: a grey step (+1 red,
  +2 green, +1 blue) then gives vr - vg' = vb - vg' = 0. `vr - vg'` and `vb - vg'` are
  taken modulo 2^wr / 2^wb too (for RGB888 that is standard QOI's signed-char wrap).
  **Decided 2026-11-06** (was OPEN 1), measured against `vg' = vg` on RGB565: never worse,
  +1.5 % on 4x4.mp4 (600 frames 640x480: 3.26x vs 3.21x), +10 % on a flat 320x288
  snapshot, equal on five 512x448 ones.
- After any pixel that is not part of a run, `cache[hash(pixel)] = pixel`; `prev = pixel`.
  The decoder does the same for every pixel it outputs (QOI rule).
- `0xFF` (`QOI_OP_RGBA`) is reserved: a decoder that meets it marks the line bad.

## Protocol

- **OPEN 2**: compression code in CMD_INIT. GroovyMAME sends 1 for both lz4 and lz4hc
  (lz4hc only changes the encoder); Groovy_MiSTer's `setInit` keeps 0 and 1 and turns any
  other value into raw. The patch uses **2 for QOI, provisional**, to be agreed with
  Calamity so it never clashes with a future Groovy_MiSTer codec. A MiSTer sent 2 would
  expect raw frames and not show the stream.
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

- **C reference** (`tools/qoiline/qoiline.h`): one encoder + one decoder, plain C99 (also
  compiles as C++), no dependency, a single header like `qoi.h` (internal names prefixed
  `qoil_`), used three ways: by the GroovyMAME patch (encoder, a copy of the file;
  `make qoiline_test` fails if the copy differs), by the measurement tool, and as the
  golden model of the Verilog tests.
- Licence: MIT for `qoiline.h` and the decoder (as QOI itself), so the encoder can go into
  any sender and the decoder into any FPGA project; the rest of the repository stays GPL.
  The user may change this.
- **Verilog decoder** (`rtl/generic/compression/qoi_line_decoder.v`):
  - Verilog-2001, no vendor primitive, no SystemVerilog, synchronous reset;
  - byte stream in and pixel stream out with valid/ready handshakes, so it fits any
    receiver (a line ring, a frame buffer, another network stack);
  - the pixel format (888 / 565) and the line width are inputs, sampled with the second
    header byte of each line, so one build handles both; pixels come out as {r8, g8, b8}
    or {8'd0, r5, g6, b5};
  - the 64-entry cache is an inferred simple dual-port RAM with a synchronous
    (read-before-write) read, plus 64 valid flags cleared per line; its write is delayed
    one cycle (hash from registers) with a bypass for an index to the pixel just written;
  - every line gives exactly `width` pixels and consumes exactly its header length; a
    corrupted line (op 0xFF, index to an unwritten entry, payload too short or too long,
    more pixels than the width, wrong raw length, length 0) gets black filler pixels with
    `out_err`, and `line_err` with `line_end`;
  - throughput: one byte per clock (an index op: 2 clocks), one pixel per clock on runs,
    far above the 100 Mbit link (12.5 MB/s) and a 640-px line every 63.6 us (10 Mpixel/s);
  - size on the GW2A-18 (standalone Gowin synthesis + P&R, 2026-11-06): 693 LUT/ALU,
    188 registers, 1 BSRAM (the cache), 1/4 DSP; Fmax 86.9 MHz (the receiver's network
    domain is 50 MHz). The undelayed cache write gave 58.6 MHz;
  - self-checking testbench against the C reference, runnable with Icarus Verilog; lints
    clean with `verilator --lint-only -Wall`.
- The board-specific part (where decoded pixels go, the CMD_BLIT size, the UART counters)
  stays in the board top.
