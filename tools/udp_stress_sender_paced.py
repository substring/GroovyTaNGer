#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Groovy_Tang - sequence-number UDP stress sender for the isolated udpstress test
# target (rtl/board/tang_primer_20k/udpstress/). Paces datagrams at a configurable
# rate instead of an unpaced tight loop, so packet loss can be measured as a function
# of send rate (see tools/udp_loss_sweep.py, which drives this script across a range
# of rates and tabulates the results). Sends a 32-bit little-endian sequence number
# as the first 4 bytes of each 1280-byte UDP payload; the board's udpstress bitstream
# decodes and reports RX=/GAP=/LAST=/RW=/RM=/HL=/DL= over its debug UART (115200 8N1,
# /dev/ttyUSB1).
#
# The default rate (--rate-factor 1.0) matches the REAL gwline datagram rate
# (~69.4us/line, 2 lines/datagram = ~138.8us/packet, ~7200 pkt/s), calibrated from
# groovy_lineram_realscale_tb.v and tools/gm_test_sender.py's minimal sender.
#
# Examples:
#   udp_stress_sender_paced.py 50000                  # 50000 packets at the real rate
#   udp_stress_sender_paced.py 50000 --rate-factor 0.5  # half the real rate
#   udp_stress_sender_paced.py 50000 --pps 3000       # explicit 3000 packets/sec
import argparse, socket, struct, time

HOST = "192.168.15.14"
PORT = 32100
PAYLOAD_LEN = 1280
BASE_PACKET_PERIOD = 69444.0 * 2 / 1e9   # seconds; 2 lines/datagram at 69.444us/line
BASE_PPS = 1.0 / BASE_PACKET_PERIOD


def main():
    p = argparse.ArgumentParser(
        description="Paced UDP sequence-number sender for udpstress loss testing.")
    p.add_argument("count", type=int, nargs="?", default=1_000_000,
                    help="number of packets to send (default: 1000000)")
    rate = p.add_mutually_exclusive_group()
    rate.add_argument("--rate-factor", type=float, default=1.0,
                       help="multiplier on the real gwline rate (~7200 pkt/s); "
                            "e.g. 0.5 = half rate, 2.0 = double rate (default: 1.0)")
    rate.add_argument("--pps", type=float,
                       help="explicit target rate in packets/sec (overrides --rate-factor)")
    p.add_argument("--quiet", action="store_true", help="suppress progress lines")
    args = p.parse_args()

    pps = args.pps if args.pps else BASE_PPS * args.rate_factor
    packet_period = 1.0 / pps

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    addr = (HOST, PORT)
    pad = bytes(PAYLOAD_LEN - 4)

    t0 = time.perf_counter()
    t_next = t0
    for seq in range(args.count):
        pkt = struct.pack("<I", seq) + pad
        try:
            sock.sendto(pkt, addr)
        except OSError:
            pass
        t_next += packet_period
        now = time.perf_counter()
        if now < t_next:
            time.sleep(t_next - now)
        if not args.quiet and seq % 100000 == 0:
            print(f"  sent {seq}/{args.count}")
    t1 = time.perf_counter()
    actual_pps = args.count / (t1 - t0)
    mbps = args.count * PAYLOAD_LEN / (t1 - t0) / 1e6
    if not args.quiet:
        print(f"done: {args.count} packets sent in {t1-t0:.2f}s "
              f"(target {pps:.0f} pkt/s, actual {actual_pps:.0f} pkt/s, {mbps:.1f} MB/s)")
    else:
        # machine-readable single line for the sweep driver
        print(f"SENT count={args.count} target_pps={pps:.1f} actual_pps={actual_pps:.1f} mbps={mbps:.2f}")


if __name__ == "__main__":
    main()
