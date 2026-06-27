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
#   gm_test_sender.py --host 192.168.1.59 blitimg --width 320 --height 240
#   gm_test_sender.py --host 192.168.1.59 blitfile photo.png   # native size + switchres modeline
#       (loads at NATIVE resolution, runs switchres for the 15kHz CRT modeline,
#        sends CMD_SWITCHRES + the native pixels; --refresh/--monitor/--dotclock-min)
#   gm_test_sender.py --host 192.168.1.59 blitstream --width 320 --height 240 --fps 30
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


def calc_modeline(w, h, refresh, monitor="arcade_15", dotclock_min=25.0):
    """Invoke the switchres CLI to compute a CRT modeline for a NATIVE w x h @ refresh.

    Returns a dict {pclk_mhz, hact,hbeg,hend,htot, vact,vbeg,vend,vtot, interlace,
    name}. dotclock_min forces switchres to apply HORIZONTAL super-resolution until
    the pixel clock clears the HDMI ~25 MHz floor - WITHOUT touching the line count
    (so the vertical scan stays native = a true 15 kHz / native-Hz CRT signal). The
    modeline's hActive is therefore the super-res'd OUTPUT width (e.g. 1280); the
    pixels we send stay at the image's NATIVE width (e.g. 320) and the FPGA replicates
    horizontally. Mirrors how GroovyMAME's bundled switchres feeds CMD_SWITCHRES.
    """
    import subprocess, re
    cmd = ["switchres", str(w), str(h), f"{refresh:g}", "-c",
           "-m", monitor, "--dotclock_min", f"{dotclock_min:g}"]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    m = re.search(r'Modeline\s+"([^"]+)"\s+([\d.]+)\s+'
                  r'(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+'
                  r'(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+'
                  r'([-+]\w+)\s+([-+]\w+)(\s+interlace)?', out)
    if not m:
        raise SystemExit(f"switchres gave no modeline for {w}x{h}@{refresh}:\n{out}")
    g = m.groups()
    return dict(name=g[0], pclk_mhz=float(g[1]),
                hact=int(g[2]), hbeg=int(g[3]), hend=int(g[4]), htot=int(g[5]),
                vact=int(g[6]), vbeg=int(g[7]), vend=int(g[8]), vtot=int(g[9]),
                interlace=1 if g[12] else 0)


def load_image_rgb565(path):
    """Load PNG/BMP/etc. at its NATIVE size (no resize) -> (w, h, rgb565 bytes LE)."""
    from PIL import Image
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    buf = bytearray()
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            buf += struct.pack("<H", ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))
    return w, h, bytes(buf)


def send_blitfile(sock, addr, args):
    # NATIVE-resolution image -> switchres modeline -> CMD_SWITCHRES -> INIT -> BLIT.
    # No resize: the image's own w x h define the source; switchres derives the CRT
    # modeline (horizontal super-res for the HDMI clock floor, native line count).
    w, h, frame = load_image_rgb565(args.file)
    ml = calc_modeline(w, h, args.refresh, args.monitor, args.dotclock_min)
    print(f"image {w}x{h}  ->  modeline '{ml['name']}'  pclk={ml['pclk_mhz']:.3f}MHz "
          f"h[{ml['hact']} {ml['hbeg']} {ml['hend']} {ml['htot']}] "
          f"v[{ml['vact']} {ml['vbeg']} {ml['vend']} {ml['vtot']}] il={ml['interlace']}"
          f"  (H super-res x{ml['hact']//w if w else 1})")

    # CMD_SWITCHRES: pclk is a double in MHz; timings are the modeline's (output) values.
    sock.sendto(struct.pack("<BdHHHHHHHHB", CMD_SWITCHRES, ml['pclk_mhz'],
                            ml['hact'], ml['hbeg'], ml['hend'], ml['htot'],
                            ml['vact'], ml['vbeg'], ml['vend'], ml['vtot'],
                            ml['interlace']), addr)
    time.sleep(0.1)                                        # let the PLL retune/settle

    sock.sendto(struct.pack("<BBBBB", CMD_INIT, 0, 0, 2, 2), addr)   # rgb565
    try: print(decode_reply(sock.recvfrom(64)[0]))
    except socket.timeout: print("(no INIT ack)")
    sock.sendto(struct.pack("<BIBH", CMD_BLIT_FIELD_VSYNC, args.frame, 0, args.vsync), addr)
    try: print(decode_reply(sock.recvfrom(64)[0]))
    except socket.timeout: print("(no BLIT ack)")

    ch = args.chunk & ~1                                   # keep pixels (2B) aligned
    n = 0
    for off in range(0, len(frame), ch):
        sock.sendto(frame[off:off+ch], addr); n += 1
        if args.delay > 0: time.sleep(args.delay)
    print(f"blitfile: {args.file} {w}x{h} = {len(frame)} bytes (RGB565) "
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
    p = argparse.ArgumentParser(
        description="Groovy_Tang protocol test sender",
        epilog="Run '<command> --help' for a command's own options "
               "(e.g. 'blitfile --help' shows --refresh/--monitor/--dotclock-min).")
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=DATA_PORT)
    p.add_argument("--timeout", type=float, default=1.0)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("close",    help="CMD_CLOSE - end the session")
    sub.add_parser("version",  help="CMD_GET_VERSION")
    sub.add_parser("status",   help="CMD_GET_STATUS")
    sub.add_parser("features", help="CMD_GET_FEATURES (v2.0.0 capabilities)")
    sub.add_parser("srresult", help="CMD_GET_SWITCHRES_RESULT (v2.0.0 debug: PLL/super-res math)")
    i = sub.add_parser("init", help="CMD_INIT - start a session (rgb mode, audio)")
    i.add_argument("--lz4", type=int, default=0)
    i.add_argument("--rate", type=int, default=0, help="0/22050/44100/48000")
    i.add_argument("--chan", type=int, default=2)
    i.add_argument("--rgb", type=int, default=None, help="omit for the 4-byte INIT form")
    s = sub.add_parser("switchres", help="CMD_SWITCHRES - send a raw modeline (manual fields)")
    for n, d in [("pclk", 25.175)]:
        s.add_argument(f"--{n}", type=float, default=d)
    for n, d in [("hactive", 640), ("hbegin", 656), ("hend", 752), ("htotal", 800),
                 ("vactive", 480), ("vbegin", 490), ("vend", 492), ("vtotal", 525),
                 ("interlace", 0)]:
        s.add_argument(f"--{n}", type=int, default=d)
    b = sub.add_parser("blit", help="CMD_BLIT - raw 8-byte blit header only")
    b.add_argument("--frame", type=int, default=1)
    b.add_argument("--field", type=int, default=0)
    b.add_argument("--vsync", type=int, default=0)
    bi = sub.add_parser("blitimg", help="send a synthetic test gradient (INIT+BLIT+pixels)")
    bi.add_argument("--width", type=int, default=100)
    bi.add_argument("--height", type=int, default=75)
    bi.add_argument("--frame", type=int, default=1)
    bi.add_argument("--chunk", type=int, default=1440)
    bi.add_argument("--delay", type=float, default=0.002, help="seconds between datagrams")
    bi.add_argument("--vsync", type=int, default=0, help=">0 = beam-race mode")
    bf = sub.add_parser("blitfile",
        help="send a PNG/BMP at NATIVE size; switchres computes+sends the CRT modeline")
    bf.add_argument("file", help="PNG/BMP/etc. - sent at its NATIVE size (no resize)")
    bf.add_argument("--refresh", type=float, default=60.0, help="target refresh Hz")
    bf.add_argument("--monitor", default="arcade_15",
                    help="switchres monitor preset (arcade_15, generic_15, pal, ntsc, vga...)")
    bf.add_argument("--dotclock-min", dest="dotclock_min", type=float, default=25.0,
                    help="min pixel clock MHz (H super-res to clear the HDMI floor)")
    bf.add_argument("--frame", type=int, default=1)
    bf.add_argument("--chunk", type=int, default=1440)
    bf.add_argument("--delay", type=float, default=0.01, help="seconds between datagrams")
    bf.add_argument("--vsync", type=int, default=0, help=">0 = beam-race mode")
    bs = sub.add_parser("blitstream", help="continuous animated frames (stream/double-buffer test)")
    bs.add_argument("--width", type=int, default=100)
    bs.add_argument("--height", type=int, default=75)
    bs.add_argument("--frames", type=int, default=600)
    bs.add_argument("--fps", type=float, default=30.0)
    bs.add_argument("--chunk", type=int, default=1440)
    bs.add_argument("--delay", type=float, default=0.001, help="seconds between datagrams")
    bs.add_argument("--vsync", type=int, default=0, help=">0 = beam-race mode")
    args = p.parse_args()

    if args.cmd in ("blitimg", "blitstream", "blitfile"):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(args.timeout)
        dispatch = {"blitimg": send_blitimg, "blitstream": send_blitstream,
                    "blitfile": send_blitfile}
        dispatch[args.cmd](sock, (args.host, args.port), args)
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
