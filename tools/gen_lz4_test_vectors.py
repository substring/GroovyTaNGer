#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Groovy_Tang - generate real LZ4 block-format test vectors for sim/tb/lz4_decoder_tb.v.
#
# Uses python-lz4's block API (raw block format, store_size=False - no length prefix,
# matching the wire format: our blit_csize already carries the compressed length
# separately, same as GroovyMAME's command.compressed_data_size). Covers both
# compression paths GroovyMAME actually uses (src/osd/modules/render/drawnogpu.cpp):
#   - LZ4_compress_HC      -> python-lz4 mode='high_compression'
#   - LZ4_compress_default -> python-lz4 mode='default', acceleration=1
# so the decoder is proven against a real, independent LZ4 implementation, not just
# round-tripped against our own encoder.
import argparse, os, random
import lz4.block as lb

def write_hex(path, data):
    with open(path, "w") as f:
        for b in data:
            f.write(f"{b:02x}\n")

def gen_case(outdir, name, data, mode="high_compression", acceleration=None):
    kwargs = {"mode": mode, "store_size": False}
    if acceleration is not None:
        kwargs["acceleration"] = acceleration
    comp = lb.compress(bytes(data), **kwargs)
    dec = lb.decompress(comp, uncompressed_size=len(data))
    assert dec == bytes(data), f"{name}: python roundtrip mismatch"
    write_hex(os.path.join(outdir, f"lz4_{name}_comp.hex"), comp)
    write_hex(os.path.join(outdir, f"lz4_{name}_plain.hex"), dec)
    print(f"{name}: comp_len={len(comp)} plain_len={len(dec)}")
    return len(comp), len(dec)


def main():
    p = argparse.ArgumentParser(
        description="Generate LZ4 test vectors (hex files) for lz4_decoder_tb.v.")
    p.add_argument("outdir")
    args = p.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    random.seed(42)
    d1 = [1, 2, 3, 4, 5] * 40 + [9] * 200 + list(range(256)) * 2
    gen_case(args.outdir, "repeats", d1)

    random.seed(1)
    d2 = [random.randint(0, 255) for _ in range(2000)]
    gen_case(args.outdir, "random", d2)

    d3 = []
    for line in range(240):
        for col in range(320):
            bar = (col * 8) // 320
            val = (bar * 37) & 0xFF
            d3 += [val, (val + line) & 0xFF]
    gen_case(args.outdir, "bars320x240", d3)

    d4 = [5, 5, 5, 5] * 100 + list(range(64)) * 10 + [200] * 50
    gen_case(args.outdir, "fastmode", d4, mode="default", acceleration=1)


if __name__ == "__main__":
    main()
