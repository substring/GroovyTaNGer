#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Groovy_Tang - sequence-number UDP stress sender for the isolated udpstress test
# target (rtl/board/tang_primer_20k/udpstress/), paced at the REAL gwline datagram
# rate (~69.4us/line, 2 lines/datagram = ~138.8us/packet, ~7200 pkt/s) instead of an
# unpaced tight loop, matching the actual sender used on real hardware
# (tools/gm_test_sender.py's minimal sender) and groovy_lineram_realscale_tb.v's
# calibration. Sends a 32-bit little-endian sequence number as the first 4 bytes of
# each 1280-byte UDP payload; the board's udpstress bitstream decodes and reports
# RX=/GAP=/LAST=/RW=/RM=/HL=/DL= over its debug UART (115200 8N1, /dev/ttyUSB1).
import socket, struct, sys, time

HOST = "192.168.15.14"
PORT = 32100
PAYLOAD_LEN = 1280
PACKET_PERIOD = 69444.0 * 2 / 1e9   # seconds; 2 lines/datagram at 69.444us/line
N = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
addr = (HOST, PORT)

pad = bytes(PAYLOAD_LEN - 4)
t0 = time.perf_counter()
t_next = t0
for seq in range(N):
    pkt = struct.pack("<I", seq) + pad
    try:
        sock.sendto(pkt, addr)
    except OSError:
        pass
    t_next += PACKET_PERIOD
    now = time.perf_counter()
    if now < t_next:
        time.sleep(t_next - now)
    if seq % 100000 == 0:
        print(f"  sent {seq}/{N}")
t1 = time.perf_counter()
print(f"done: {N} packets sent in {t1-t0:.2f}s ({N/(t1-t0):.0f} pkt/s, "
      f"{N*PAYLOAD_LEN/(t1-t0)/1e6:.1f} MB/s)")
