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


# SOLID vertical colour bars (RGB565) - the EASY-TO-READ pattern for visual HW checks.
# 8 bars across the width: black, red, green, yellow, blue, magenta, cyan, white. A defect
# (wrong colour, torn/shifted bar, wrong line) is immediately obvious and describable -
# unlike a gradient. Plus a distinct 1px white line at the very TOP and a red one at the
# BOTTOM as vertical orientation/edge markers.
BAR_COLORS = [0x0000, 0xF800, 0x07E0, 0xFFE0, 0x001F, 0xF81F, 0x07FF, 0xFFFF]
def gen_bars(w: int, h: int, mark=3) -> bytes:
    # VERTICAL colour bars. `mark` source rows thick for the edge markers so they survive
    # V replication. (All source lines identical except markers -> can't reveal ring
    # persistence; use gen_hbars for that.)
    nbar = len(BAR_COLORS)
    buf = bytearray()
    for y in range(h):
        for x in range(w):
            if y < mark:            pix = 0xFFFF     # top edge marker (white band)
            elif y >= h - mark:     pix = 0xF800     # bottom edge marker (red band)
            else:                   pix = BAR_COLORS[(x * nbar) // w]
            buf += struct.pack("<H", pix)
    return bytes(buf)


def gen_hbars(w: int, h: int) -> bytes:
    # HORIZONTAL colour bars: each source LINE is a different solid colour (8 bands top
    # to bottom). Lines DIFFER vertically, so if the stream stops and the ring replays its
    # last ~NLINES lines, the screen freezes on those few lines (one/two colours stretched)
    # instead of the full image - proving beam-race (ring != frame store). Also a per-line
    # left-edge white marker (first 4 px) as a horizontal position reference.
    nbar = len(BAR_COLORS)
    buf = bytearray()
    for y in range(h):
        c = BAR_COLORS[(y * nbar) // h]
        for x in range(w):
            pix = 0xFFFF if x < 4 else c
            buf += struct.pack("<H", pix)
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


def _pace_until(t_target, spin_win=0.0015):
    # Precise wait to t_target (perf_counter seconds). OS sleep() is coarse (esp. Windows,
    # ~15ms granularity), so we SLEEP the bulk of a long wait then BUSY-SPIN the last
    # spin_win seconds on perf_counter - which is precise on BOTH Windows and Linux (only
    # sleep() is bad on Windows). This is what GroovyMAME's WaitSync does. The busy-spin
    # burns a core for ~1.5ms per wait; fine for a dedicated sender.
    now = time.perf_counter()
    bulk = t_target - now - spin_win
    if bulk > 0:
        time.sleep(bulk)
    while time.perf_counter() < t_target:
        pass


def _read_ack_vcount(sock, addr):
    """Poll CMD_GET_STATUS and return the FPGA's live raster source line (vCount), or None
    on timeout / bad reply. Only valid BETWEEN blits (while blitting, the FPGA eats every
    datagram as pixel data and won't answer). This is the phase-lock feedback."""
    try:
        sock.sendto(struct.pack("<B", CMD_GET_STATUS), addr)
        data, _ = sock.recvfrom(64)
    except OSError:
        return None
    if len(data) != 13:
        return None
    _, _, _, vcount, _ = struct.unpack("<IHIHB", data)
    return vcount


def send_blitrace(sock, addr, args):
    # BEAM-RACE paced blit (OPEN-LOOP RATE MATCH). While blitting, the FPGA treats every
    # datagram as pixel DATA (blit framing) and cannot answer CMD_GET_STATUS mid-frame,
    # so per-line polling is impossible - exactly like stock GroovyMAME, which streams a
    # frame's pixels at the GAME's pixel rate. We do the same: send the frame's source
    # lines at a fixed cadence tuned to the FPGA raster's consumption rate, so the write
    # pointer tracks the read pointer within the line-ring depth (NLINES). The FIFO+ring
    # absorbs jitter; the FPGA UART reports the outcome (GL= valid output lines per video
    # frame, LT= the writer's measured lead). Tune --lead until LT sits mid-window.
    #
    # Consumption rate: the reader drains SRC_H source lines per FRAME PERIOD (1/refresh),
    # so the sustainable average is line_period = 1/(refresh*h). We send lines_per_dgram
    # lines per datagram and wait line_period*lines_per_dgram between datagrams. The rate
    # is not adjustable: a line ring only works at exactly the raster's rate.
    if args.file:
        w, h, frame = load_image_rgb565(args.file)
        ml = calc_modeline(w, h, args.refresh, args.monitor, args.dotclock_min)
        print(f"image {w}x{h} -> modeline '{ml['name']}' pclk={ml['pclk_mhz']:.3f}MHz "
              f"(H super-res x{ml['hact']//w if w else 1})")
        sock.sendto(struct.pack("<BdHHHHHHHHB", CMD_SWITCHRES, ml['pclk_mhz'],
                                ml['hact'], ml['hbeg'], ml['hend'], ml['htot'],
                                ml['vact'], ml['vbeg'], ml['vend'], ml['vtot'],
                                ml['interlace']), addr)
        time.sleep(0.1)
    else:
        w, h = args.width, args.height
        frame = {"bars": gen_bars, "hbars": gen_hbars,
                 "gradient": gen_frame}[args.pattern](w, h)
        print(f"pattern: {args.pattern} {w}x{h}")

    line_bytes = w * 2                                     # RGB565 = 2 B/px
    sock.settimeout(0.5)
    sock.sendto(struct.pack("<BBBBB", CMD_INIT, 0, 0, 2, 2), addr)   # rgb565
    try: print(decode_reply(sock.recvfrom(64)[0]))
    except socket.timeout: print("(no INIT ack)")

    # PACING with PHASE LOCK to the FPGA raster (loose loop, PC time-master).
    # line_period = wall time per SOURCE line. frame_period = one video frame.
    # The FPGA raster spends vactive of its vtotal output lines on the picture and the
    # rest in vertical blanking, so in SOURCE lines one video frame is h*vtotal/vactive
    # long (250 for 240 lines in 720p) and the raster crosses one source line every
    # frame_period/250 = 66.7 us - NOT frame_period/240. Two things depend on that:
    #  - pacing: sending at the raster's own line rate, then idling through blanking,
    #    keeps the writer's lead CONSTANT down the frame. Spreading the lines over the
    #    whole frame instead lets the raster gain ~10 lines on the writer by the bottom,
    #    which costs a third of the 32-line ring (valid lead 10..30 vs 1..28, measured in
    #    sim/tb/groovy_linering_beamrace_tb.sv, +RPACE).
    #  - phase lock: the raster line reported in the ACK runs 0..249, and the time left
    #    to the next line 0 is (250 - v) raster lines. Treating it as (240 - v) frame/240
    #    periods mis-placed the lock by up to 10 lines depending on when it was polled.
    frame_period = 1.0 / args.refresh
    raster_lines = h * args.vtotal / args.vactive          # source lines per video frame
    raster_line  = frame_period / raster_lines if h else 0.0
    line_period  = raster_line if args.pace == "raster" else frame_period / h
    lpd    = max(1, args.group)                            # lines per datagram
    period = line_period * lpd                            # busy-spin cadence per datagram

    # --- INITIAL LOCK: read the FPGA's current raster line, predict the next vsync ---
    # The FPGA reports its live scan source line (0..h-1) in the ACK vCount. We poll it
    # (only valid BETWEEN blits, so do it now before streaming), then compute t_vsync =
    # the perf_counter instant the FPGA raster will next be at line 0.
    def next_vsync():
        v = _read_ack_vcount(sock, addr)
        if v is None or v >= raster_lines:
            return None
        now = time.perf_counter()
        # raster lines remaining until it wraps to source line 0 (blanking included)
        return now + (raster_lines - v) * raster_line
    t_vsync = None
    for _ in range(20):
        t_vsync = next_vsync()
        if t_vsync is not None:
            break
    if t_vsync is None:
        print("(no vCount lock, falling back to free-run pacing)")
        t_vsync = time.perf_counter()
    else:
        print(f"phase lock: next FPGA vsync in {(t_vsync-time.perf_counter())*1e3:.2f}ms")
    print(f"pacing: {args.pace}, line_period={line_period*1e6:.1f}us {lpd} line/dgram, "
          f"lead {args.lead} lines, phase-locked to FPGA raster, resync {args.resync_hz}Hz")
    if args.frames < 30:
        print("NOTE: a line ring holds 32 lines, not a picture - it only shows something "
              "while frames keep coming. Use --frames 600 or more to judge the result.")

    frames = args.frames
    resync_period = 1.0 / args.resync_hz if args.resync_hz > 0 else 1e18
    next_resync = time.perf_counter() + resync_period
    lead_t = args.lead * raster_line                      # writer runs this far AHEAD
    for f in range(frames):
        # each frame targets a vsync instant; advance t_vsync one frame at a time.
        # The writer must LEAD the raster by `lead` lines (not be synchronous with it -
        # synchronous = writer overwrites the line the reader is reading right now, so the
        # reader only ever sees a tiny stale window = the ~17-line repeat we saw). So start
        # streaming lead_t BEFORE the vsync: line 0 lands while the raster is still in the
        # previous frame's blanking, and stays `lead` lines ahead throughout.
        t_start = t_vsync - lead_t
        # if t_start is already in the past (startup / after a resync jump), don't blast -
        # snap the schedule forward to now so we keep the per-line cadence.
        now = time.perf_counter()
        if t_start < now:
            t_start = now
        _pace_until(t_start - args.header_gap)
        sock.sendto(struct.pack("<BIBH", CMD_BLIT_FIELD_VSYNC, f + 1, 0, args.vsync), addr)
        # stream the h lines timed so line L lands ~lead lines before the raster reaches L.
        t_line = t_start
        sent = 0
        while sent < h:
            n = min(lpd, h - sent)
            off = sent * line_bytes
            try:
                sock.sendto(frame[off:off + n * line_bytes], addr)
            except OSError:
                pass                                       # kernel TX buffer full; skip
            sent += n
            t_line += period
            _pace_until(t_line)
        t_vsync += frame_period                           # next frame's vsync (predicted)

        # --- LOOSE RESYNC (~resync_hz): re-read vCount between frames, correct t_vsync ---
        # We're now in the inter-frame gap (blitting just fell). Poll the true raster line
        # and nudge t_vsync toward it, absorbing the PC<->FPGA clock drift.
        if time.perf_counter() >= next_resync:
            nv = next_vsync()
            if nv is not None:
                # snap t_vsync to the nearest predicted vsync consistent with nv
                k = round((nv - t_vsync) / frame_period)
                corrected = nv - k * frame_period
                drift_us = (corrected - t_vsync) * 1e6
                t_vsync = corrected
                if args.verbose:
                    print(f"resync @f{f+1}: drift {drift_us:+.1f}us corrected")
            next_resync = time.perf_counter() + resync_period
        if args.verbose and f % 60 == 0:
            print(f"frame {f+1}")
    print(f"blitrace: {frames} frame(s) {w}x{h}, phase-locked -> {addr[0]}:{addr[1]}")
    # Final status: ACK status bit0 set = the last video frame was NOT fully valid.
    try:
        sock.sendto(struct.pack("<B", CMD_GET_STATUS), addr)
        print(decode_reply(sock.recvfrom(64)[0]))
    except OSError:
        print("(no final status)")


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
    br = sub.add_parser("blitrace",
        help="BEAM-RACE paced blit (open-loop rate match): streams a frame's lines at a "
             "fixed cadence tuned to the FPGA raster consumption so the line-ring tracks "
             "(no over/underrun). Tune --lead; watch GL=/LT= on the FPGA UART")
    br.add_argument("--width", type=int, default=320)
    br.add_argument("--height", type=int, default=240)
    br.add_argument("--file", default=None, help="native image (runs switchres); omit for a gradient")
    br.add_argument("--group", type=int, default=2, help="source lines per datagram (2 = sweet spot; keep datagram <= MTU)")
    br.add_argument("--pattern", choices=["bars", "hbars", "gradient"], default="bars",
                    help="bars=vertical colour bars, hbars=horizontal (reveals ring persistence), gradient")
    br.add_argument("--header-gap", type=float, default=0.0005,
                    help="seconds of quiet before each frame's BLIT header (lets blitting fall)")
    br.add_argument("--lead", type=int, default=16,
                    help="raster lines the writer starts ahead of the beam. Read the result back "
                         "as LT= on the FPGA UART (LT is lower than --lead by the network path "
                         "delay, ~2-4 lines); aim for LT around 0x0C..0x12")
    br.add_argument("--pace", choices=["raster", "frame"], default="raster",
                    help="raster = send lines at the raster's own line rate then idle through "
                         "vertical blanking (constant lead; default). frame = spread the lines "
                         "evenly over the whole frame period (old behaviour)")
    br.add_argument("--vtotal", type=int, default=750, help="FPGA output raster total lines (720p: 750)")
    br.add_argument("--vactive", type=int, default=720, help="FPGA output raster active lines (720p: 720)")
    br.add_argument("--resync-hz", type=float, default=2.0,
                    help="how often to re-read the FPGA vCount and correct phase drift (0=never)")
    br.add_argument("--frames", type=int, default=600, help="frames to stream (600 = 10 s)")
    br.add_argument("--vsync", type=int, default=1, help=">0 = beam-race target line")
    br.add_argument("--refresh", type=float, default=60.0, help="refresh Hz (sets line cadence)")
    br.add_argument("--monitor", default="arcade_15")
    br.add_argument("--dotclock-min", dest="dotclock_min", type=float, default=25.0)
    br.add_argument("--verbose", action="store_true")
    bs = sub.add_parser("blitstream", help="continuous animated frames (stream/double-buffer test)")
    bs.add_argument("--width", type=int, default=100)
    bs.add_argument("--height", type=int, default=75)
    bs.add_argument("--frames", type=int, default=600)
    bs.add_argument("--fps", type=float, default=30.0)
    bs.add_argument("--chunk", type=int, default=1440)
    bs.add_argument("--delay", type=float, default=0.001, help="seconds between datagrams")
    bs.add_argument("--vsync", type=int, default=0, help=">0 = beam-race mode")
    args = p.parse_args()

    if args.cmd in ("blitimg", "blitstream", "blitfile", "blitrace"):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(args.timeout)
        dispatch = {"blitimg": send_blitimg, "blitstream": send_blitstream,
                    "blitfile": send_blitfile, "blitrace": send_blitrace}
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
