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
#                     kind: 0 = INIT, 1 = BLIT header, 2 = pixel datagram
import argparse, os, struct
from gen_gwline_frames import build_udp_frame, cmd_init, cmd_blit_field_vsync

def pix(f, l, c):
    return ((l * 0x9E37) ^ (c * 0x7F4B) ^ (f * 0x1D2F) ^ 0x5A5A) & 0xFFFF

def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else "")
    p.add_argument("outdir")
    p.add_argument("--frames", type=int, default=4)
    p.add_argument("--width", type=int, default=320)
    p.add_argument("--height", type=int, default=240)
    p.add_argument("--lines-per-dgram", type=int, default=2)
    a = p.parse_args()
    os.makedirs(a.outdir, exist_ok=True)

    frames = [(0, build_udp_frame(cmd_init()))]
    for f in range(a.frames):
        frames.append((1, build_udp_frame(cmd_blit_field_vsync(f + 1))))
        for l0 in range(0, a.height, a.lines_per_dgram):
            payload = b"".join(struct.pack("<H", pix(f, l, c))
                               for l in range(l0, min(l0 + a.lines_per_dgram, a.height))
                               for c in range(a.width))
            frames.append((2, build_udp_frame(payload)))

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
