# Human notes

In loving memory of https://github.com/psakhis

Hey! Let me describe things briefly before al the AI loghorrea coming after ...

This project is an implementation of GroovyMiSTer protocol on a different FPGA (Sipeed Tang Primer 20k with dock, very cheap compared to a full blown DE10 for MiSTer).

## Key points

- the Primer 20k only has 100Mb/s ethernet. And trust me, it's VERY challenging and does set limits everywhere
- HDMI output for now only, audio on jack.
- RGB565, will dig later for RGB888 bu it will be a real probelm in the current state
- Can't use the embedded DDR3 because of interferences on HDMI (bummer)
- interlaced works, and switches with no black screen from or to progressive
- no DDR3 + 100Mb/s ethernet + limited BSRAM = forget 640x480i for now
- requires quite some patches on top of GroovyMAME (tested on 0.289) on Linux only. Sorry about others, but network pacing is a pita to implement anywhere else and it IS mandatory here
- overall compatible with the native Groovymister protocol, but I need to fully check that
- only supported compression protocol : QOI. Can't use dictionnary based compression because of of memory limits. So yes, groovymame patch provided
- In other words : works like a charm for anything that used sprites on progressive resolutions. Not yet suited for PS1 and later
- I know nothing about Verilog or anything regarding FPGA programming, I'm blessing Claude Opus 5.5 that got its hands dirty for all the coding part
- video glitches from time to time, I can only blame GroovyMAME for not being right on time when sending frame lines. But considering beam race is not implemented, this is the best we can have
- the board sits at 192.168.15.14 (MAC: 06:00:AA:BB:0C:DD), add an alias over your NIC to communicate with it
- use `openFPGALoader` to flash through JTAG, for example : `openFPGALoader -b tangprimer20k mycode.fs` (add `-f` to flash to SPI and have it for good until next flash)
- GM sends the native mode, the FPGA does the required scaling internally to output a signal which dot clock >= 25MHz (yeah, HDMI specs, sorry ...)

All in all, I really wanna stress that the limited resources on this FPGA implied some heavy liftings here and there. Having 1Gb/s and 512MB DDR3 would have made my life oh so much easier, but anyway, the challenge was (and still is) really interesting.

Just know that it all relies on a 32 lines ring buffer, not a full frame stored in BSRAM, that 100Mb/s is 10 times slower than 1Gb/s to receive data, and you start to get an idea of the real time constraints I've been facing all along this project ...

Claude wrote a number of python tools to test the project that are extremly useful (like stream a video to the board).

So yes it's on HDMI for now, using the LCD connector will require some bard to convert to VGA, that's part of my todo. I used a cheap chinese HDMI2VGA that worked flawlessly, really.

## GroovyMAME options to set

Once patches are applied, use `-video mister -mister_ip 192.168.15.14 -mister_rgb_mode rgb565 -mister_linepacing -aspect 4:3 -mister_compression qoi`.

It is very useful to use your crt_range from the command line if you don't have GM installed and setup for your CRT. Here is mine: `-monitor custom -crt_range0 15625.0-15750.0,49.5-65.0,4.727,4.655,6.982,0.063,0.190,1.143,0,0,192,288,448,576 `

# Groovy_TaNGer

FPGA receiver for the **Sipeed Tang Primer 20K Dock** (Gowin GW2A-LV18), speaking the
Groovy_MiSTer protocol: GroovyMAME (`-video mister`) sends each line over 100 Mb/s
Ethernet and the board shows it on HDMI as it arrives (beam-race through a 32-line BRAM
ring), with the audio on the Dock's jack.

## Where things are

| What | Where |
|---|---|
| Current state, open points, resume point | [docs/status.md](docs/status.md) |
| Running GroovyMAME against the board (patches, fq qdisc, pacing, options) | [docs/groovymame_client.md](docs/groovymame_client.md), [patches/README.md](patches/README.md) |
| The release design (FPGA top) | [rtl/board/tang_primer_20k/gwline/](rtl/board/tang_primer_20k/gwline/) (`gwline_top.sv`) |
| Beam-race design | [docs/beamrace_design.md](docs/beamrace_design.md), [docs/beamracing.md](docs/beamracing.md) |
| QOI per line (format, encoder, decoder) | [docs/qoi_line_format.md](docs/qoi_line_format.md), [tools/qoiline/](tools/qoiline/) |
| Protocol conformance | [docs/protocol_verified.md](docs/protocol_verified.md), [docs/protocol_conformance_2026-10.md](docs/protocol_conformance_2026-10.md) |
| DDR3 path (parked: it disturbs HDMI) | [docs/ddr3.md](docs/ddr3.md), [docs/hdmi_ddr3_interference.md](docs/hdmi_ddr3_interference.md), `gwddr3net/`, `gwddr3video/` |
| Host tools (protocol test client, video streamer, headless build) | [tools/README.md](tools/README.md) |
| The original June 2026 specification (historical) | [docs/original_spec.md](docs/original_spec.md) |

Repository layout: `rtl/core` (protocol, ring, audio, modeline control), `rtl/generic`
(video timing, QOI decoder), `rtl/vendor` (Sipeed UDP stack, Gowin primitive wrappers,
UART TX), `rtl/board/tang_primer_20k` (board tops), `sim/tb` (self-checking benches).

## Building the bitstream

The Gowin DVI_TX IP is proprietary and not in the repository: generate it first (see
`rtl/board/tang_primer_20k/video/dvi_tx/README.md`). Then, with Gowin EDA installed:

```bash
tools/gw_build.sh rtl/board/tang_primer_20k/gwline/gwline.gprj
openFPGALoader -b tangprimer20k rtl/board/tang_primer_20k/gwline/impl/pnr/gwline.fs
```

`VIDEO_MODE` in `gwline_top.sv` picks the raster: 4 (default) follows GroovyMAME's
modeline; 0 is a fixed 1280x720 for HDMI screens that refuse 15 kHz modes.

## Running the tests

Requires [Icarus Verilog](https://github.com/steveicarus/iverilog) and
[Verilator](https://www.veripool.org/verilator/):

```bash
make test                                  # every unit bench (fast)
make test-gwline                           # full-top benches of gwline (several minutes)
make wave TB=groovy_packet_parser_tb       # build a .vcd for GTKWave
```

## License

GPL-2.0-or-later. See [LICENSE](LICENSE), which also lists the vendored third-party code
(Apache-2.0) and the Gowin proprietary IP.
