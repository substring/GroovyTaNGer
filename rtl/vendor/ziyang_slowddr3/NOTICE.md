# Vendored: ZiyangYE / General-Slow-DDR3-Interface

- **Upstream:** https://github.com/ZiyangYE/General-Slow-DDR3-Interface
- **License:** BSD-3-Clause (see `LICENSE`)
- **Vendored:** 2026-06-26, verbatim (no source edits to `slowDDR3.v`).

## Why we vendored this
The nand2mario controller's high-speed (DDR3-800) source-synchronous read path suffers a
per-byte-lane DQS skew on our Tang Primer 20K that calibration cannot close (~32% of read
words corrupted; see memory notes ddr3-byte-lane-skew). This controller runs the DDR3 much
slower (DDR-100 system / 50 MHz DDR clock, stable at DDR-80 on Gowin GW2A-C per the upstream
table), giving a much WIDER read eye with STATIC timing and no DQS training — a different bet
to get correct reads.

## Files
- `slowDDR3.v` — pre-compiled Verilog (SpinalHDL v1.6.0 output), 100 MHz / 128Mx16b DDR3.
  THE module we instantiate. **Do not hand-edit** — regenerate from the `.scala` if config
  must change (e.g. `clkFreq` in `slowDDR3Cfg`).
- `slowDDR3.scala` — SpinalHDL source (for regeneration / reference only; needs SpinalHDL).
- `slowDDR3_tb.v` — upstream testbench (needs a Micron DDR3 model to simulate).
- `LICENSE` — BSD-3-Clause.

## Interface (module `slowDDR3`)
- Clocks/reset: `clk` (100 MHz sys), `inv_clk` (inverted `clk`), `resetn` (active-low).
- User read:  hold `sysIO_dataRd_ready=1` + `sysIO_address[26:0]` (with `sysIO_dataWr_valid=0`)
              -> data returns as a `sysIO_dataRd_valid` pulse + `sysIO_dataRd_payload[15:0]`.
- User write: `sysIO_dataWr_valid=1` + `sysIO_address` + `sysIO_dataWr_payload[15:0]`,
              wait for `sysIO_dataWr_ready`. Write wins if read+write collide.
- `sysIO_initFin` = init done. Refresh is automatic (no caller action needed).
- DDR3 PHY pins: `phyIO_dq[15:0]` (inout), `phyIO_dqs_p/n[1:0]` (inout), `phyIO_clk_p/n`,
  `phyIO_address[13:0]`, `phyIO_bank[2:0]`, `phyIO_cas/ras/we/cke/odt/cs/rst_n`, `phyIO_dm[1:0]`.
  Map these to the board DDR3 pins in the `.cst` (compare against the nand2mario DDR3_* names).
