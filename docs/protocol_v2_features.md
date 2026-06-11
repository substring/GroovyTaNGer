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

## Future
This is the negotiation hook for V2+: new compression bits (RLE/QOI), new RGB
modes, or capability flags (interlaced, audio, max resolution) can be added as
reserved bytes/bits without a new command or breaking older clients.
