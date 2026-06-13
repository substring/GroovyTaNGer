#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Groovy_Tang - protocol bring-up test sender.
#
# Sends ONE Groovy_MiSTer control packet at a time and decodes the reply, so each
# validation rung can be exercised in isolation (independent of GroovyMAME).
# Wire formats per docs/protocol_verified.md (verified vs psakhis/Groovy_MiSTer).
#
# Examples:
#   gm_test_sender.py --host 192.168.1.59 version
#   gm_test_sender.py --host 192.168.1.59 init --lz4 0 --rate 48000 --chan 2 --rgb 0
#   gm_test_sender.py --host 192.168.1.59 status
#   gm_test_sender.py --host 192.168.1.59 switchres --pclk 25.175 \
#       --hactive 640 --hbegin 656 --hend 752 --htotal 800 \
#       --vactive 480 --vbegin 490 --vend 492 --vtotal 525 --interlace 0
#   gm_test_sender.py --host 192.168.1.59 blit --frame 1 --field 0 --vsync 0
import argparse, socket, struct, sys, time

DATA_PORT = 32100

CMD_CLOSE, CMD_INIT, CMD_SWITCHRES, CMD_AUDIO = 1, 2, 3, 4
CMD_GET_STATUS, CMD_BLIT_FIELD_VSYNC, CMD_GET_VERSION = 5, 7, 8
CMD_GET_FEATURES = 9                       # Groovy_Tang v2.0.0 extension
CMD_GET_SWITCHRES_RESULT = 10              # v2.0.0 debug: read mode-change math

RATE_CODE = {0: 0, 22050: 1, 44100: 2, 48000: 3}
COMP_BITS = ["RAW", "LZ4", "RLE", "QOI"]
RGB_BITS  = ["RGB888", "RGBA888", "RGB565"]


def decode_features(data: bytes) -> str:
    if len(data) < 12:
        return f"FEATURES reply too short ({len(data)} bytes): {data.hex()}"
    major, minor, patch, comp, rgb = data[4], data[5], data[6], data[7], data[8]
    comps = [n for i, n in enumerate(COMP_BITS) if comp & (1 << i)] or ["(none)"]
    rgbs  = [n for i, n in enumerate(RGB_BITS) if rgb & (1 << i)] or ["(none)"]
    return (f"FEATURES: protocol v{major}.{minor}.{patch} "
            f"| compression={'|'.join(comps)} (0x{comp:02x}) "
            f"| rgb={'|'.join(rgbs)} (0x{rgb:02x})")


def decode_switchres(data: bytes) -> str:
    if len(data) < 25:
        return f"GTSR reply too short ({len(data)} bytes): {data.hex()}"
    pclk_khz, = struct.unpack_from("<I", data, 4)
    n = data[8]
    pclk_out, = struct.unpack_from("<I", data, 9)
    idiv, fbdiv, odiv = data[13], data[14], data[15]
    achieved, = struct.unpack_from("<I", data, 16)
    ok = data[20]
    h_total, = struct.unpack_from("<H", data, 21)
    v_total, = struct.unpack_from("<H", data, 23)
    return (f"SWITCHRES: pclk={pclk_khz} kHz, superres x{n} -> {pclk_out} kHz | "
            f"PLL idiv={idiv} fbdiv={fbdiv} odiv={odiv} -> {achieved} kHz (ok={ok}) | "
            f"modeline h_total={h_total} v_total={v_total}")


def decode_reply(data: bytes) -> str:
    if len(data) >= 4 and data[:4] == b"GTSR":
        return decode_switchres(data)
    if len(data) >= 4 and data[:4] == b"GTF1":
        return decode_features(data)
    if len(data) == 1:
        return f"VERSION reply: core_version={data[0]}"
    if len(data) != 13:
        return f"unexpected reply ({len(data)} bytes): {data.hex()}"
    frameEcho, vCountEcho, frame, vCount, status = struct.unpack("<IHIHB", data)
    bits = [
        ("vramReady",    status & 0x01),
        ("vramEndFrame", (status >> 1) & 1),
        ("vramSynced",   (status >> 2) & 1),
        ("vgaFrameskip", (status >> 3) & 1),
        ("vgaVblank",    (status >> 4) & 1),
        ("vgaF1",        (status >> 5) & 1),
        ("audio",        (status >> 6) & 1),
        ("vramQueue",    (status >> 7) & 1),
    ]
    flags = " ".join(f"{n}={v}" for n, v in bits)
    return (f"ACK: frameEcho={frameEcho} vCountEcho={vCountEcho} "
            f"| fpga frame={frame} vCount={vCount} | status=0x{status:02x} [{flags}]")


def gen_frame(w: int, h: int) -> bytes:
    # RGB565 test image: red gradient left->right, green top->bottom, B=0,
    # plus an 8x8 white square at the top-left as an origin/orientation marker.
    buf = bytearray()
    for y in range(h):
        for x in range(w):
            if x < 8 and y < 8:
                pix = 0xFFFF
            else:
                r5 = (x * 31) // (w - 1) if w > 1 else 0
                g6 = (y * 63) // (h - 1) if h > 1 else 0
                pix = (r5 << 11) | (g6 << 5)
            buf += struct.pack("<H", pix)            # little-endian RGB565
    return bytes(buf)


def gen_frame_anim(w: int, h: int, phase: int) -> bytes:
    # gradient background + a 4px white vertical bar sweeping across (motion test).
    barx = phase % w
    buf = bytearray()
    for y in range(h):
        g6 = (y * 63) // (h - 1) if h > 1 else 0
        for x in range(w):
            if abs(x - barx) < 2:
                pix = 0xFFFF
            else:
                r5 = (x * 31) // (w - 1) if w > 1 else 0
                pix = (r5 << 11) | (g6 << 5)
            buf += struct.pack("<H", pix)
    return bytes(buf)


def send_blitstream(sock, addr, args):
    # continuous frames -> exercises the double buffer (smooth, no tearing).
    sock.sendto(struct.pack("<BBBBB", CMD_INIT, 0, 0, 2, 2), addr)
    sock.setblocking(False)
    period = 1.0 / args.fps if args.fps > 0 else 0.0
    ch = args.chunk & ~1
    for i in range(args.frames):
        t0 = time.time()
        sock.sendto(struct.pack("<BIBH", CMD_BLIT_FIELD_VSYNC, i + 1, 0, args.vsync), addr)
        frame = gen_frame_anim(args.width, args.height, i)
        for off in range(0, len(frame), ch):
            sock.sendto(frame[off:off+ch], addr)
            if args.delay > 0: time.sleep(args.delay)
        try:
            while True: sock.recv(64)          # drain ACKs
        except BlockingIOError:
            pass
        dt = time.time() - t0
        if dt < period: time.sleep(period - dt)
    print(f"blitstream: {args.frames} frames {args.width}x{args.height} "
          f"@~{args.fps}fps (delay={args.delay}s) -> {addr[0]}:{addr[1]}")


def send_blitimg(sock, addr, args):
    # 1) INIT rgb565 (rgbMode=2), 2) CMD_BLIT header, 3) pixel datagrams.
    sock.sendto(struct.pack("<BBBBB", CMD_INIT, 0, 0, 2, 2), addr)
    try: print(decode_reply(sock.recvfrom(64)[0]))         # INIT ACK
    except socket.timeout: print("(no INIT ack)")
    sock.sendto(struct.pack("<BIBH", CMD_BLIT_FIELD_VSYNC, args.frame, 0, args.vsync), addr)
    try: print(decode_reply(sock.recvfrom(64)[0]))         # BLIT ACK
    except socket.timeout: print("(no BLIT ack)")
    frame = gen_frame(args.width, args.height)
    ch = args.chunk & ~1                                    # keep pixels (2B) aligned
    n = 0
    for off in range(0, len(frame), ch):
        sock.sendto(frame[off:off+ch], addr); n += 1
        if args.delay > 0: time.sleep(args.delay)           # avoid overrunning UDP RX
    print(f"blitimg: {args.width}x{args.height} = {len(frame)} bytes "
          f"in {n} datagrams (delay={args.delay}s) -> {addr[0]}:{addr[1]}")


def build(args) -> bytes:
    c = args.cmd
    if c == "close":
        return struct.pack("<B", CMD_CLOSE)
    if c == "version":
        return struct.pack("<B", CMD_GET_VERSION)
    if c == "status":
        return struct.pack("<B", CMD_GET_STATUS)
    if c == "init":
        rate = RATE_CODE.get(args.rate, 0)
        if args.rgb is None:                      # 4-byte form (rgbMode omitted)
            return struct.pack("<BBBB", CMD_INIT, 1 if args.lz4 else 0, rate, args.chan)
        return struct.pack("<BBBBB", CMD_INIT, 1 if args.lz4 else 0, rate, args.chan, args.rgb)
    if c == "switchres":
        return struct.pack("<BdHHHHHHHHB", CMD_SWITCHRES, args.pclk,
                           args.hactive, args.hbegin, args.hend, args.htotal,
                           args.vactive, args.vbegin, args.vend, args.vtotal,
                           args.interlace)
    if c == "blit":                               # 8-byte raw blit header only
        return struct.pack("<BIBH", CMD_BLIT_FIELD_VSYNC, args.frame, args.field, args.vsync)
    if c == "features":                           # v2.0.0: 1-byte request
        return struct.pack("<B", CMD_GET_FEATURES)
    if c == "srresult":                           # v2.0.0 debug: read switchres math
        return struct.pack("<B", CMD_GET_SWITCHRES_RESULT)
    raise SystemExit("unknown command")


def main():
    p = argparse.ArgumentParser(description="Groovy_Tang protocol test sender")
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=DATA_PORT)
    p.add_argument("--timeout", type=float, default=1.0)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("close"); sub.add_parser("version"); sub.add_parser("status")
    sub.add_parser("features")   # v2.0.0 capabilities query
    sub.add_parser("srresult")   # v2.0.0 debug: read SWITCHRES mode-change math
    i = sub.add_parser("init")
    i.add_argument("--lz4", type=int, default=0)
    i.add_argument("--rate", type=int, default=0, help="0/22050/44100/48000")
    i.add_argument("--chan", type=int, default=2)
    i.add_argument("--rgb", type=int, default=None, help="omit for the 4-byte INIT form")
    s = sub.add_parser("switchres")
    for n, d in [("pclk", 25.175)]:
        s.add_argument(f"--{n}", type=float, default=d)
    for n, d in [("hactive", 640), ("hbegin", 656), ("hend", 752), ("htotal", 800),
                 ("vactive", 480), ("vbegin", 490), ("vend", 492), ("vtotal", 525),
                 ("interlace", 0)]:
        s.add_argument(f"--{n}", type=int, default=d)
    b = sub.add_parser("blit")
    b.add_argument("--frame", type=int, default=1)
    b.add_argument("--field", type=int, default=0)
    b.add_argument("--vsync", type=int, default=0)
    bi = sub.add_parser("blitimg")    # INIT(rgb565) + BLIT header + a test frame
    bi.add_argument("--width", type=int, default=100)
    bi.add_argument("--height", type=int, default=75)
    bi.add_argument("--frame", type=int, default=1)
    bi.add_argument("--chunk", type=int, default=1440)
    bi.add_argument("--delay", type=float, default=0.002, help="seconds between datagrams")
    bi.add_argument("--vsync", type=int, default=0, help=">0 = beam-race mode")
    bs = sub.add_parser("blitstream")  # continuous animated frames (double-buffer test)
    bs.add_argument("--width", type=int, default=100)
    bs.add_argument("--height", type=int, default=75)
    bs.add_argument("--frames", type=int, default=600)
    bs.add_argument("--fps", type=float, default=30.0)
    bs.add_argument("--chunk", type=int, default=1440)
    bs.add_argument("--delay", type=float, default=0.001, help="seconds between datagrams")
    bs.add_argument("--vsync", type=int, default=0, help=">0 = beam-race mode")
    args = p.parse_args()

    if args.cmd in ("blitimg", "blitstream"):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(args.timeout)
        (send_blitimg if args.cmd == "blitimg" else send_blitstream)(sock, (args.host, args.port), args)
        return

    pkt = build(args)
    expects_reply = args.cmd in ("init", "status", "version", "blit", "features", "srresult")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(args.timeout)
    sock.sendto(pkt, (args.host, args.port))
    print(f"sent {args.cmd}: {len(pkt)} bytes -> {args.host}:{args.port}  [{pkt.hex()}]")
    if not expects_reply:
        return
    try:
        data, _ = sock.recvfrom(64)
        print(decode_reply(data))
    except socket.timeout:
        print("no reply (timeout) — expected for this command?", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
