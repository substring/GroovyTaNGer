#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Groovy_Tang - live UART watchdog for the gwline beam-race debug line.
#
# Reads /dev/ttyUSB1 continuously and parses the debug frame:
#   RD=.... WL=.... GP=.... RL=.... HF=. UR=. OV=. SE=.
# Prints a line ONLY when a WATCHED field CHANGES (default: OV and UR), so the exact
# MOMENT a fault appears (e.g. OV 0->F) is caught with full context, instead of staring
# at a firehose or a frozen post-mortem snapshot. Also prints a periodic heartbeat so
# you see it's alive and the steady-state values.
#
# Usage:
#   tools/uart_watch.py                 # watch OV and UR transitions
#   tools/uart_watch.py --watch OV      # only OV
#   tools/uart_watch.py --all           # print every distinct debug frame
import argparse, re, sys, time

FIELD_RE = re.compile(
    rb"RD=([0-9A-F]{4}) WL=([0-9A-F]{4}) GP=([0-9A-F]{4}) RL=([0-9A-F]{4}) "
    rb"HF=([0-9A-F]) UR=([0-9A-F]) OV=([0-9A-F])(?: SE=([0-9A-F]))?")
NAMES = ["RD", "WL", "GP", "RL", "HF", "UR", "OV", "SE"]


def main():
    p = argparse.ArgumentParser(description="Live UART watchdog for gwline OV/UR faults")
    p.add_argument("--dev", default="/dev/ttyUSB1")
    p.add_argument("--watch", default="OV,UR", help="comma list of fields to alert on change")
    p.add_argument("--all", action="store_true", help="print every distinct frame")
    p.add_argument("--seconds", type=float, default=0, help="stop after N s (0 = forever)")
    p.add_argument("--heartbeat", type=float, default=2.0, help="print steady state every N s")
    args = p.parse_args()
    watch = [w.strip().upper() for w in args.watch.split(",") if w.strip()]

    t0 = time.perf_counter()
    last = {}
    last_hb = 0.0
    buf = b""
    # line-buffered read of the tty
    with open(args.dev, "rb", buffering=0) as f:
        # put the port in a sane raw mode via stty done by the caller; we just read.
        print(f"watching {args.dev} fields={watch} (Ctrl-C to stop)", file=sys.stderr)
        while True:
            if args.seconds and (time.perf_counter() - t0) > args.seconds:
                break
            chunk = f.read(256)
            if not chunk:
                time.sleep(0.005)
                continue
            buf += chunk
            # keep buffer bounded
            if len(buf) > 4096:
                buf = buf[-2048:]
            for m in FIELD_RE.finditer(buf):
                vals = {NAMES[i]: (m.group(i + 1).decode() if m.group(i + 1) else "-")
                        for i in range(len(NAMES))}
                now = time.perf_counter() - t0
                if args.all:
                    print(f"[{now:7.3f}] " + " ".join(f"{k}={vals[k]}" for k in NAMES))
                else:
                    changed = [w for w in watch if last.get(w) != vals.get(w)]
                    if changed and last:  # skip the very first frame
                        tag = ",".join(f"{w}:{last.get(w)}->{vals[w]}" for w in changed)
                        print(f"[{now:7.3f}] CHANGE {tag}  | " +
                              " ".join(f"{k}={vals[k]}" for k in NAMES))
                    elif now - last_hb >= args.heartbeat:
                        print(f"[{now:7.3f}] ...     " +
                              " ".join(f"{k}={vals[k]}" for k in NAMES))
                        last_hb = now
                last = vals
            # drop consumed bytes up to the last complete match region
            cut = buf.rfind(b"SE=")
            if cut > 0:
                buf = buf[cut:]


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
