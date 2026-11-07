# Groovy_MiSTer protocol — verified against source (Rung 0)

Verified 2026-06-10 against `psakhis/Groovy_MiSTer@main`:
- client lib: `api/groovymister.{h,cpp}` (defines what goes on the wire)
- receiver:   `hps_linux/src/support/groovy/groovy.cpp` (defines how it's parsed)

This **supersedes inferences** in `original_spec.md §5` where they differ.
Line numbers cite the source above.

## Command codes (groovy.cpp:113-120 / groovymister.cpp:32-39) — all confirmed
```
CMD_CLOSE 1  CMD_INIT 2  CMD_SWITCHRES 3  CMD_AUDIO 4
CMD_GET_STATUS 5  CMD_BLIT_VSYNC 6 (deprecated)  CMD_BLIT_FIELD_VSYNC 7  CMD_GET_VERSION 8
```

## Control packet wire formats (little-endian; x86 host order)

| Cmd | Len | Layout | Source |
|---|---|---|---|
| CLOSE | 1 | `[0]=1` | gm.cpp:173 |
| INIT | **4 or 5** | `[0]=2 [1]=lz4(0/1) [2]=soundRateCode [3]=soundChan [4]=rgbMode?` | gm.cpp:447, **groovy.cpp:2003** |
| SWITCHRES | 26 | `[0]=3 [1..8]=pClock(double) [9..10]hActive [11..12]hBegin [13..14]hEnd [15..16]hTotal [17..18]vActive [19..20]vBegin [21..22]vEnd [23..24]vTotal [25]interlace` | gm.cpp:518-530 |
| AUDIO | 3 | `[0]=4 [1..2]=soundSize` + raw stream | gm.cpp:679 |
| GET_STATUS | 1 | `[0]=5` | groovy.cpp:2040 |
| BLIT_VSYNC (dep.) | 7 or 11 | `[0]=6 [1..4]frame [5..6]vsync (+[7..10]cSize)` | groovy.cpp:2051 |
| BLIT_FIELD_VSYNC | 8/9/12/13 | see below | gm.cpp:614-645, groovy.cpp:2076 |
| GET_VERSION | 1 | `[0]=8` | groovy.cpp:1985 |

- `soundRateCode` (gm.cpp:449): `22050→1, 44100→2, 48000→3, else 0`.
- `lz4` byte on the wire is only `0/1` even though the client's internal
  `lz4Frames` can be 1-6 (HC/adaptive variants are client-side only).
- INIT len==4 ⇒ `rgbMode` omitted ⇒ defaults to RGB888 (0) (groovy.cpp:2012).

### BLIT_FIELD_VSYNC variants (groovy.cpp:2076-2104)
Common head: `[0]=7 [1..4]=frame(u32) [5]=field(u8) [6..7]=vSync(u16)`.
- **8** : raw, no flag.
- **9** : raw + `[8]=0x01` **frame_dup** (identical frame; **no pixel stream follows**).
- **12**: lz4 + `[8..11]=cSize`.
- **13**: lz4 + `[8..11]=cSize` + `[12]=0x01` **frame_delta**.
The receiver also gates on the INIT compression mode (`blitCompression`): 9 is
frame_dup only when raw; 12/13 are lz4 only when compressed. The client never
crosses these, so packet length alone disambiguates conformant traffic.

## ACK — 13 bytes (gm.cpp setFpgaStatus:1084-1090) — matches our ack_sender
```
[0..3]  frameEcho   (u32, echo of blit frame#)
[4..5]  vCountEcho  (u16, echo of blit vSync)
[6..9]  frame       (u32, fpga gpu frame counter)
[10..11] vCount     (u16, fpga gpu vcount)
[12]    status bits: b0 vramReady  b1 vramEndFrame b2 vramSynced b3 vgaFrameskip
                     b4 vgaVblank  b5 vgaF1        b6 audio      b7 vramQueue
```
**ACK is sent after:** INIT (`sendACK(0,0)` :2015), GET_STATUS (:2043),
BLIT_VSYNC (:2069), BLIT_FIELD_VSYNC (`sendACK(frame,vsync)` :2103).
**NOT sent after:** SWITCHRES, AUDIO, CLOSE, GET_VERSION.

## GET_VERSION reply — 1 byte
Receiver calls `sendVersion()` (groovy.cpp:1988); client reads a single byte
into `m_core_version` (gm.cpp:739/775). ⇒ reply = one byte = core version.

## Pixel stream sizing (groovy.cpp:788)
`PoC_bytes_len = rgbMode==1 ? pixels<<2 : rgbMode==2 ? pixels<<1 : pixels*3`
i.e. RGBA888=4B/px, RGB565=2B/px, RGB888=3B/px. (×½ per field if interlaced.)

## frame_delta — mechanism (NOT fully on the C side)
- Raw mode: "delta" is only ever **frame_dup** (`PoC_bytes_recv = PoC_bytes_len`,
  `isBlitting=0`, no pixels) (groovy.cpp:1201,1239).
- LZ4 mode: the `0x01` flag sets `PoC_delta_lz4` (groovy.cpp:1217); the LZ4
  payload (size `cSizeDelta`) is streamed to the FPGA, which applies it as a
  delta vs. the previous frame. **The exact reconstruction is in `rtl/lz4.v`**
  (read it when implementing Rung 8/9). The client builds the delta buffer via
  `getPBufferBlitDelta()`; GroovyMAME fills it.

## Timeout / resync (groovy.cpp:1928-1972)
While blitting, if a datagram makes `PoC_bytes_recv + len` ≠ the expected total,
the receiver aborts the blit (`isBlitting=0`) and records `prev_len`/`tota_len`
for the error log, then resumes parsing control packets. This is the loss-recovery
behavior for Rung 11.

---

## Reconciliation with our RTL

| Item | Our impl | Verdict |
|---|---|---|
| CMD codes 1-8 | parser localparams | ✅ correct |
| INIT 5-byte decode | parser | ✅ correct |
| **INIT 4-byte accept** | parser rejected len 4 | ❌ **FIXED**: accept 4 or 5, rgbMode⇐0 |
| SWITCHRES 26-byte LE + pClock@1 | parser | ✅ correct |
| AUDIO 3-byte | parser | ✅ correct |
| BLIT 8/9/12/13, fields/flag offsets | parser | ✅ correct |
| ACK 13-byte order + status bits | ack_sender | ✅ correct |
| GET_VERSION 1-byte reply | (not built yet) | ➕ note: reply = 1 byte |
| SWITCHRES → no ACK | (n/a) | ➕ Rung 4 confirms via next status ACK |
| CMD_BLIT_VSYNC=6 | parser flags bad | ⚠️ deprecated; OK to reject (GroovyMAME uses 7) |
| Blit gated by INIT lz4 mode | parser uses length only | ⚠️ fine for conformant traffic; optional `lz4_mode` input later |
| frame_delta reconstruction | lz4_decoder stub | ⛏️ defined in rtl/lz4.v — Rung 8/9 |
