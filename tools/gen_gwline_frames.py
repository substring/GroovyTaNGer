#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Groovy_Tang - build real Ethernet frames (CMD_INIT + CMD_BLIT_FIELD_VSYNC + pixel
# payload datagrams) for sim/tb/gwline_ring_e2e_tb.v, with correct UDP checksum +
# Ethernet FCS, so they can be replayed byte-exact through a real udp.sv instance via
# RMII (same technique as groovy_udpstress_udpsv_realframe_tb.v). Every pixel encodes
# its own (source_line, col) as its RGB565 value, so the testbench can check the
# ring's final content against ground truth with no ambiguity.
import argparse, struct, zlib, sys

SRC_MAC = bytes.fromhex("3c7c3fc32c22")   # PC sender (arbitrary, matches earlier captures)
DST_MAC = bytes.fromhex("0600aabb0cdd")   # FPGA MAC (from gwline_top.sv mac_adr param)
SRC_IP  = "192.168.15.15"
DST_IP  = "192.168.15.14"                 # matches gwline_top.sv ip_adr param
SRC_PORT = 32101
DST_PORT = 32100                          # gwline_top.sv OUR_PORT
RGB_MODE_RGB565 = 2                       # groovy_session.v: cfg_rgb_mode==2 -> 2 bytes/pixel

def ip_to_bytes(s):
    return bytes(int(x) for x in s.split("."))

def udp_checksum(src_ip, dst_ip, src_port, dst_port, payload):
    length = 8 + len(payload)
    pseudo = ip_to_bytes(src_ip) + ip_to_bytes(dst_ip) + bytes([0, 17]) + struct.pack(">H", length)
    udp_hdr_for_sum = struct.pack(">HHHH", src_port, dst_port, length, 0)
    data = pseudo + udp_hdr_for_sum + payload
    if len(data) % 2:
        data += b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i+1]
        s = (s & 0xFFFF) + (s >> 16)
    s = ~s & 0xFFFF
    return 0xFFFF if s == 0 else s

def build_udp_frame(payload, ident=0x0001, dst_ip=None, dst_port=None, dst_mac=None):
    """dst_* default to the receiver (DST_IP:DST_PORT); pass others for a foreign datagram"""
    dst_ip = DST_IP if dst_ip is None else dst_ip
    dst_port = DST_PORT if dst_port is None else dst_port
    dst_mac = DST_MAC if dst_mac is None else dst_mac
    udp_len = 8 + len(payload)
    csum = udp_checksum(SRC_IP, dst_ip, SRC_PORT, dst_port, payload)
    udp_hdr = struct.pack(">HHHH", SRC_PORT, dst_port, udp_len, csum)
    ip_total_len = 20 + udp_len
    ip_hdr_nosum = struct.pack(">BBHHHBBH4s4s",
        0x45, 0x00, ip_total_len, ident, 0x4000, 0x40, 17, 0,
        ip_to_bytes(SRC_IP), ip_to_bytes(dst_ip))
    s = 0
    for i in range(0, len(ip_hdr_nosum), 2):
        s += (ip_hdr_nosum[i] << 8) | ip_hdr_nosum[i+1]
        s = (s & 0xFFFF) + (s >> 16)
    ip_csum = ~s & 0xFFFF
    ip_hdr = struct.pack(">BBHHHBBH4s4s",
        0x45, 0x00, ip_total_len, ident, 0x4000, 0x40, 17, ip_csum,
        ip_to_bytes(SRC_IP), ip_to_bytes(dst_ip))
    eth_hdr = dst_mac + SRC_MAC + struct.pack(">H", 0x0800)
    frame = eth_hdr + ip_hdr + udp_hdr + payload
    if len(frame) < 60:
        frame += b"\x00" * (60 - len(frame))
    fcs = struct.pack("<I", zlib.crc32(frame) & 0xFFFFFFFF)
    return frame + fcs

def cmd_init(lz4=0, sound_rate=0, sound_chan=2, rgb_mode=RGB_MODE_RGB565):
    return bytes([2, lz4, sound_rate, sound_chan, rgb_mode])

def cmd_blit_field_vsync(frame_no, field=0, vsync=0):
    return struct.pack("<BIBH", 7, frame_no, field, vsync)

def gen_pixel_pattern(src_w, src_h):
    # unique-per-(line,col) RGB565 value: {line[7:0], col[7:0]} - lets the testbench
    # verify EXACTLY which source line/col ended up in which ring slot, unambiguously.
    out = bytearray()
    for line in range(src_h):
        for col in range(src_w):
            v = ((line & 0xFF) << 8) | (col & 0xFF)
            out += struct.pack("<H", v)
    return bytes(out)

def main():
    p = argparse.ArgumentParser(
        description="Generate real Ethernet/IP/UDP frames (CMD_INIT + CMD_BLIT + pixel "
                     "data) for gwline_ring_e2e_tb.v.")
    p.add_argument("outdir")
    p.add_argument("--width", type=int, default=320)
    p.add_argument("--height", type=int, default=240)
    p.add_argument("--chunk", type=int, default=1280, help="payload bytes per pixel datagram")
    args = p.parse_args()

    pixdata = gen_pixel_pattern(args.width, args.height)
    frames = []
    frames.append(("INIT", build_udp_frame(cmd_init())))
    frames.append(("BLIT_HDR", build_udp_frame(cmd_blit_field_vsync(1))))
    for off in range(0, len(pixdata), args.chunk):
        frames.append(("PIX", build_udp_frame(pixdata[off:off + args.chunk])))

    manifest = []
    for idx, (label, fbytes) in enumerate(frames):
        fname = f"{args.outdir}/frame_{idx:04d}_{label}.hex"
        with open(fname, "w") as f:
            for b in fbytes:
                f.write(f"{b:02x}\n")
        manifest.append((idx, label, len(fbytes)))
    with open(f"{args.outdir}/frames_manifest.txt", "w") as f:
        for idx, label, ln in manifest:
            f.write(f"{idx} {label} {ln}\n")
    print(f"generated {len(frames)} frames ({args.width}x{args.height}, "
          f"{args.chunk}B chunks, {len(pixdata)} pixel bytes, rgb_mode={RGB_MODE_RGB565})")
    print(f"first bytes of pixel data (line0,col0..3): {pixdata[:8].hex()}")


if __name__ == "__main__":
    main()
