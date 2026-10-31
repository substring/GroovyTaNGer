#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Groovy_Tang - Ethernet frame stream for sim/tb/gwline_top_e2e_tb.sv.
#
# Emits what a host really puts on the wire for a beam-race session: one CMD_INIT, then
# for each of N network frames a CMD_BLIT_FIELD_VSYNC header followed by the pixel
# datagrams (2 source lines each). Every Ethernet frame is complete (IP + UDP checksums,
# FCS) so the testbench can clock it straight into udp.sv over RMII.
#
# Each pixel is a hash of (frame, line, col) - different on every line AND every frame -
# and the testbench recomputes the same hash, so a line shown from the wrong slot, the
# wrong ring lap or the wrong frame cannot pass. Keep pix() in sync with the tb.
#
# Output (in <outdir>):
#   stream_bytes.hex  all frames' bytes, concatenated, one byte per line
#   stream_idx.hex    one 64-bit word per Ethernet frame: {kind[7:0], len[23:0], offset[31:0]}
#                     kind: 0 = INIT, 1 = BLIT header, 2 = pixel datagram,
#                           3 = CMD_SET_BEACON 1 (--beacon: right after INIT),
#                           5 = ARP request from the host (always first),
#                           6 = CMD_AUDIO header, 7 = audio payload datagram (--audio N:
#                               N stereo 16-bit samples per frame, after its pixels; CMD_INIT
#                               then announces 48 kHz stereo). Sample k of the stream:
#                               L = 2k, R = 2k + 1 (mod 65536), checked by the testbench.
#                           8 = CMD_SWITCHRES (--groovymame: right after CMD_INIT,
#                               h_active x v_active = --width x --height)
#                           4 = CMD_GET_STATUS (--status-burst N: N of them after each
#                               frame's last pixel datagram, back to back)
#
# --groovymame speaks GroovyMAME's own dialect (src/osd/modules/render/drawnogpu.cpp),
# not the groovymister API's: a 4-byte CMD_INIT (no rgbMode -> RGB888), an 11-byte
# CMD_BLIT_VSYNC (6) {6, frame u32, vsync u16, cSize u32 = 0}, and the frame's RGB888
# bytes (B,G,R per pixel, MAME's little-endian ARGB) cut into 1472-byte datagrams with no
# regard for line boundaries (nogpu_send_mtu). Each pixel's 888 value packs back to the
# same pix() RGB565 hash, so the testbench check is unchanged.
import argparse, os, struct
import zlib
from gen_gwline_frames import (build_udp_frame, cmd_init, cmd_blit_field_vsync,
                               SRC_MAC, SRC_IP, DST_IP, ip_to_bytes)

def build_arp_request():
    # the host asking who has DST_IP: udp.sv learns the host's MAC from it, as on a real
    # LAN (without an entry it answers nothing and keeps sending ARP requests itself)
    arp = struct.pack(">HHBBH", 1, 0x0800, 6, 4, 1) + SRC_MAC + ip_to_bytes(SRC_IP) \
          + bytes(6) + ip_to_bytes(DST_IP)
    frame = b"\xff" * 6 + SRC_MAC + struct.pack(">H", 0x0806) + arp
    frame += bytes(max(0, 60 - len(frame)))
    return frame + struct.pack("<I", zlib.crc32(frame) & 0xFFFFFFFF)

def pix(f, l, c):
    return ((l * 0x9E37) ^ (c * 0x7F4B) ^ (f * 0x1D2F) ^ 0x5A5A) & 0xFFFF

def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else "")
    p.add_argument("outdir")
    p.add_argument("--frames", type=int, default=4)
    p.add_argument("--width", type=int, default=320)
    p.add_argument("--height", type=int, default=240)
    p.add_argument("--lines-per-dgram", type=int, default=2)
    p.add_argument("--beacon", action="store_true",
                   help="enable the FPGA raster beacon (CMD_SET_BEACON 1) after CMD_INIT")
    p.add_argument("--audio", type=int, default=0,
                   help="stereo samples per frame (48 kHz: 800); 0 = no audio")
    p.add_argument("--groovymame", action="store_true",
                   help="GroovyMAME dialect: 4-byte INIT (RGB888), CMD_BLIT_VSYNC 6, 1472-byte chunks")
    p.add_argument("--rgb565", action="store_true",
                   help="with --groovymame: GroovyMAME patched with -mister_rgb_mode rgb565 "
                        "(patches/groovymame-mister-rgb565.patch): 5-byte INIT, 2-byte pixels")
    p.add_argument("--interlace", action="store_true",
                   help="with --groovymame: CMD_SWITCHRES announces 2*height lines interlaced "
                        "(interlace=1, GroovyMAME's -mister_interlaced_fb 1); each blit is one "
                        "field of --height lines")
    p.add_argument("--status-burst", dest="status_burst", type=int, default=0,
                   help="CMD_GET_STATUS requests sent back to back after each frame")
    a = p.parse_args()
    os.makedirs(a.outdir, exist_ok=True)

    rate = 3 if a.audio else 0
    if a.groovymame:
        init = bytes([2, 0, rate, 2, 2]) if a.rgb565 else bytes([2, 0, rate, 2])
    else:
        init = cmd_init(sound_rate=rate, sound_chan=2)
    frames = [(5, build_arp_request()), (0, build_udp_frame(init))]
    if a.groovymame:   # GroovyMAME sends the game's modeline before its first blit
        w, h = a.width, a.height
        if a.interlace:   # 480i-style modeline: each blit is ONE field of --height lines
            frames.append((8, build_udp_frame(struct.pack("<BdHHHHHHHHB", 3, 6.7,
                           w, w + 16, w + 48, w + 104, 2 * h, 2 * h + 6, 2 * h + 12, 525, 1))))
        else:
            frames.append((8, build_udp_frame(struct.pack("<BdHHHHHHHHB", 3, 6.7,
                           w, w + 16, w + 48, w + 104, h, h + 3, h + 6, 262, 0))))
    k_audio = 0
    if a.beacon:
        frames.append((3, build_udp_frame(bytes([11, 1]))))   # CMD_SET_BEACON, enable
    for f in range(a.frames):
        if a.groovymame:
            frames.append((1, build_udp_frame(struct.pack("<BIHI", 6, f + 1, 200, 0))))
            raw = bytearray()
            for l in range(a.height):
                for c in range(a.width):
                    v = pix(f, l, c)
                    if a.rgb565:
                        raw += struct.pack("<H", v)
                    else:
                        raw += bytes([(v & 0x1F) << 3, ((v >> 5) & 0x3F) << 2, (v >> 11) << 3])
            for o in range(0, len(raw), 1472):
                frames.append((2, build_udp_frame(bytes(raw[o:o + 1472]))))
        else:
            frames.append((1, build_udp_frame(cmd_blit_field_vsync(f + 1))))
        for l0 in (range(0, a.height, a.lines_per_dgram) if not a.groovymame else ()):
            payload = b"".join(struct.pack("<H", pix(f, l, c))
                               for l in range(l0, min(l0 + a.lines_per_dgram, a.height))
                               for c in range(a.width))
            frames.append((2, build_udp_frame(payload)))
        if a.audio:
            pcm = b"".join(struct.pack("<HH", (2 * (k_audio + i)) & 0xFFFF,
                                       (2 * (k_audio + i) + 1) & 0xFFFF) for i in range(a.audio))
            k_audio += a.audio
            frames.append((6, build_udp_frame(struct.pack("<BH", 4, len(pcm)))))
            for o in range(0, len(pcm), 1440):
                frames.append((7, build_udp_frame(pcm[o:o + 1440])))
        for _ in range(a.status_burst):
            frames.append((4, build_udp_frame(bytes([5]))))

    off = 0
    with open(os.path.join(a.outdir, "stream_bytes.hex"), "w") as fb, \
         open(os.path.join(a.outdir, "stream_idx.hex"), "w") as fi:
        for kind, data in frames:
            fi.write(f"{(kind << 56) | (len(data) << 32) | off:016x}\n")
            fb.write("".join(f"{b:02x}\n" for b in data))
            off += len(data)
    print(f"{len(frames)} ethernet frames, {off} bytes, {a.frames} network frames "
          f"of {a.width}x{a.height}")

if __name__ == "__main__":
    main()
