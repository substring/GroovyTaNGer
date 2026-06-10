# Groovy_Tang

FPGA CRT receiver for the **Sipeed Tang Primer 20K Dock** (Gowin GW2A-LV18),
a low-cost alternative to the DE10-Nano for the Groovy_MiSTer project.

See [groovy_tang_spec.md](groovy_tang_spec.md) for the full specification and
architecture (this is the living reference document — read it first).

## Status

Early bootstrap. The repository currently contains:

- The 4-layer RTL skeleton from spec §6.2 (`vendor` / `board` / `core` / `generic`).
- The **board-independent, simulatable core logic** with self-checking
  testbenches (no FPGA or vendor toolchain required to run them).
- Stubs with TODOs for the hardware/vendor-dependent modules, each pointing at
  its roadmap phase.

### What is implemented and simulation-verified

| Module | Path | Roadmap phase | Tested |
|---|---|---|---|
| Packet parser (8 Groovy commands) | `rtl/core/groovy_packet_parser.v` | Phase 6 | ✅ tb |
| ACK builder (13-byte status) | `rtl/core/groovy_ack_sender.v` | Phase 6/11 | ✅ tb |
| PLL solver (Gowin rPLL, bounded) | `rtl/core/groovy_pll_solver.v` | Phase 4/7 | ✅ tb |
| Dynamic video timing generator | `rtl/generic/video/video_timing_gen.v` | Phase 3 | ✅ tb |
| Super-resolution factor (N) | `rtl/generic/video/superres_factor.v` | Phase 3 | ✅ tb |
| LFSR | `rtl/generic/lfsr.v` | — | ✅ tb |
| Binary → BCD | `rtl/generic/binary_to_bcd.v` | — | ✅ tb |

### What is stubbed (needs board / Gowin EDA / vendor IP)

- `rtl/vendor/gowin/*` — rPLL reconfig, DDR3, BRAM, async FIFO, OSER10/ELVDS wrappers
- `rtl/board/tang_primer_20k/*` — top-level pin mapping + `.cst` constraints
- `rtl/generic/ethernet/*` — MAC RX/TX, IPv4/UDP (Phase 5)
- `rtl/generic/compression/lz4_decoder.v` — port of Psakhis `lz4.v` (Phase 8)
- HDMI — to be vendored from tangcore `hdmi2/` then forked for dynamic timing
  (Phase 2/3); see spec §6.5.

## Running the tests

Requires [Icarus Verilog](https://github.com/steveicarus/iverilog):

```bash
sudo apt-get install -y iverilog gtkwave   # one time
make test                                  # run every self-checking testbench
make wave TB=groovy_packet_parser_tb       # build a .vcd for GTKWave
```

Each testbench prints `PASS`/`FAIL` lines and exits non-zero on failure, so
`make test` is CI-friendly.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE). Vendored HDMI code retains its
original (MIT-like) license and attribution.
