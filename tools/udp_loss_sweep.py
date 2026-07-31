#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Groovy_Tang - sweeps the udpstress send rate across a range and tabulates the real
# measured packet loss at each point, to characterize the 100Mb/s link's saturation
# curve (see memory/udpstress-bandwidth-saturation.md for the single-point finding
# this generalizes: 0.64% loss at 3600 pkt/s vs 11.84% at 7200 pkt/s).
#
# Uses a network-triggered soft reset (a magic seq=0xFFFFFFFF datagram, decoded by
# groovy_udpstress_top.sv into a counter reset) between each measurement point instead
# of a physical S0 button press, so the whole sweep runs unattended.
#
# Requires: the udpstress bitstream already flashed and the UART port readable.
#
# Usage:
#   udp_loss_sweep.py                              # default sweep, 20000 pkts/point
#   udp_loss_sweep.py --count 50000                 # more packets per point (slower, tighter CI)
#   udp_loss_sweep.py --rates 0.25,0.5,0.75,1.0,1.5  # custom rate-factor list
import argparse, re, socket, struct, subprocess, sys, time

HOST = "192.168.15.14"
PORT = 32100
PAYLOAD_LEN = 1280
BASE_PACKET_PERIOD = 69444.0 * 2 / 1e9   # seconds; 2 lines/datagram at 69.444us/line
BASE_PPS = 1.0 / BASE_PACKET_PERIOD
RESET_CMD_SEQ = 0xFFFFFFFF
UART_DEV = "/dev/ttyUSB1"
UART_BAUD = 115200

FIELD_RE = re.compile(
    rb"RX=([0-9A-F]{8}) GAP=([0-9A-F]{8}) LAST=([0-9A-F]{8}) REJ=([0-9A-F]{4}) "
    rb"HD=([0-9A-F]{4})")


def send_reset(sock, addr):
    pad = bytes(PAYLOAD_LEN - 4)
    sock.sendto(struct.pack("<I", RESET_CMD_SEQ) + pad, addr)


def send_burst(sock, addr, count, pps):
    period = 1.0 / pps
    pad = bytes(PAYLOAD_LEN - 4)
    t0 = time.perf_counter()
    t_next = t0
    for seq in range(count):
        try:
            sock.sendto(struct.pack("<I", seq) + pad, addr)
        except OSError:
            pass
        t_next += period
        now = time.perf_counter()
        if now < t_next:
            time.sleep(t_next - now)
    return time.perf_counter() - t0


def flush_and_read_uart(settle=0.3, read_window=1.5):
    # settle: let the last debug frame finish transmitting/repeating before sampling
    time.sleep(settle)
    subprocess.run(["stty", "-F", UART_DEV, str(UART_BAUD), "raw", "-echo"], check=True)
    # drain whatever's stale in the buffer first (see memory/uart-flush-before-read.md -
    # skipping this produced hours of phantom "stuck counter" readings this session)
    with open(UART_DEV, "rb", buffering=0) as f:
        import os
        os.set_blocking(f.fileno(), False)
        t_end = time.perf_counter() + 0.2
        while time.perf_counter() < t_end:
            try:
                f.read(65536)
            except (BlockingIOError, OSError):
                pass
        # now read fresh
        os.set_blocking(f.fileno(), True)
        buf = b""
        t_end = time.perf_counter() + read_window
        while time.perf_counter() < t_end:
            chunk = f.read(256)
            if chunk:
                buf += chunk
            m = FIELD_RE.search(buf)
            if m:
                return {
                    "RX": int(m.group(1), 16),
                    "GAP": int(m.group(2), 16),
                    "LAST": int(m.group(3), 16),
                    "REJ": int(m.group(4), 16),
                    "HD": int(m.group(5), 16),
                }
    return None


def main():
    p = argparse.ArgumentParser(description="Sweep udpstress send rate and tabulate loss.")
    p.add_argument("--count", type=int, default=20000,
                    help="packets per measurement point (default: 20000)")
    p.add_argument("--rates", type=str, default="0.25,0.5,0.75,1.0,1.25,1.5",
                    help="comma-separated list of rate factors relative to the real "
                         "gwline rate (~7200 pkt/s) (default: 0.25,0.5,0.75,1.0,1.25,1.5)")
    args = p.parse_args()

    rate_factors = [float(x) for x in args.rates.split(",")]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    addr = (HOST, PORT)

    results = []
    print(f"{'rate_factor':>11} {'target_pps':>10} {'sent':>8} {'RX':>8} {'GAP':>8} "
          f"{'loss%':>7} {'MB/s':>6}")
    for rf in rate_factors:
        pps = BASE_PPS * rf
        send_reset(sock, addr)
        # The reset command must NOT be part of the timed burst flow - give it a full
        # second of quiet time to land and settle (independent of the target send
        # rate) before starting the real, separately-paced burst. Confirm the board
        # actually saw the reset (RX==1, the reset packet itself, GAP==0) before
        # trusting the upcoming measurement; a race here silently corrupted an earlier
        # sweep (a too-short gap let burst traffic arrive before/during the reset,
        # producing a nonsensical 0% loss point at high rate).
        time.sleep(1.0)
        confirm = flush_and_read_uart(settle=0.0, read_window=1.0)
        if confirm is None or confirm["RX"] != 1 or confirm["GAP"] != 0:
            print(f"{rf:11.2f} {pps:10.0f}  -- reset not confirmed clean "
                  f"({confirm}), skipping this point --")
            continue
        elapsed = send_burst(sock, addr, args.count, pps)
        stats = flush_and_read_uart()
        if stats is None:
            print(f"{rf:11.2f} {pps:10.0f}  -- UART read timed out, skipping --")
            continue
        # subtract the reset command's own +1 to rx_cnt so RX reflects only the burst
        rx, gap = stats["RX"] - 1, stats["GAP"]
        loss_pct = gap / (rx + gap) * 100 if (rx + gap) else float("nan")
        mbps = args.count * PAYLOAD_LEN / elapsed / 1e6
        results.append((rf, pps, args.count, rx, gap, loss_pct, mbps))
        print(f"{rf:11.2f} {pps:10.0f} {args.count:8d} {rx:8d} {gap:8d} "
              f"{loss_pct:6.2f}% {mbps:6.1f}")

    print("\n=== SUMMARY (rate_factor, target pkt/s, MB/s, loss%) ===")
    for rf, pps, count, rx, gap, loss_pct, mbps in results:
        print(f"  {rf:5.2f}x  {pps:7.0f} pkt/s  {mbps:5.1f} MB/s  ->  {loss_pct:5.2f}% loss")


if __name__ == "__main__":
    main()
