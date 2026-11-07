# tools

Host-side helpers. Wire formats per [../docs/protocol_verified.md](../docs/protocol_verified.md).

## `gm_test_sender.py` — protocol test client

Speaks the Groovy_MiSTer protocol to the board (default port 32100) without GroovyMAME:
one command at a time to isolate a step, or a whole paced stream. No build step.

```bash
./gm_test_sender.py --host 192.168.15.14 version
./gm_test_sender.py --host 192.168.15.14 features
./gm_test_sender.py --host 192.168.15.14 init --rate 48000 --chan 2 --rgb 0
./gm_test_sender.py --host 192.168.15.14 blitfile picture.png        # + its modeline
./gm_test_sender.py --host 192.168.15.14 blitrace --video video.mp4 --audio video \
    --frames 3600 --beacon                                          # beam-raced video
./gm_test_sender.py --host 192.168.15.14 close
```

`./gm_test_sender.py --help` and `<command> --help` list every command and option.

## `gw_build.sh` — headless Gowin build

```bash
tools/gw_build.sh rtl/board/tang_primer_20k/gwline/gwline.gprj
```
Synthesis + place and route + bitstream with `gw_sh`, no GUI; the bitstream lands in
`impl/pnr/<name>.fs` next to the `.gprj`.

## `net/` — fq qdisc for GroovyMAME's pacing

`-mister_pacing` / `-mister_linepacing` need the `fq` qdisc on the interface that sends
the stream: `90-groovy-fq` (NetworkManager dispatcher) or `groovy-fq.network.example`
(systemd-networkd). See `docs/groovymame_client.md` and `patches/README.md`.

## `qoiline/` — QOI per line (C reference)

`qoiline.h` is the single-header encoder/decoder of `docs/qoi_line_format.md` (MIT), used by
`patches/groovymame-mister-qoi.patch` (a copy) and as the golden model of
`rtl/generic/compression/qoi_line_decoder.v`. `make qoiline_test qoi_line_decoder_tb` runs
its self-test and the Verilog bench. `qoiline_size.c` prints the coded size of every line
of raw RGB24 frames, in RGB888 or RGB565:

    gcc -O2 -o qoiline_size tools/qoiline/qoiline_size.c tools/qoiline/qoiline.c
    ffmpeg -i in.mp4 -an -f rawvideo -pix_fmt rgb24 - | ./qoiline_size 320 224 565

## `gen_gwline_stream.py`, `gen_gwline_frames.py` — simulation streams

Build complete Ethernet frames (checksums, FCS) of a GroovyMAME session for the
`gwline` benches, which clock them into the real `udp.sv` over RMII. `make test-gwline`
runs them; `gen_gwline_stream.py` documents every option.
