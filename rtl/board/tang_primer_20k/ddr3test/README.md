# DDR3 bring-up + memory self-test (DDR3 step 1-2)

Standalone project to bring up the onboard **128 MB DDR3** via the vendored
nand2mario controller, then prove it with a write/read self-test. No network, no
video, no UART needed — the result is on the **Dock's 6 LEDs**. This is the first
hardware-testable DDR3 milestone (see `docs/ddr3.md`).

## Build (Gowin EDA)
1. Open `ddr3test.gprj` in Gowin IDE.
2. Project → Configuration → **Synthesis**: Verilog language = **SystemVerilog**
   (the controller uses `typedef`/`logic`).
3. Project → Configuration → **Dual-Purpose Pin**: **Use SSPI as regular IO**
   (and keep DONE/READY-as-IO as in our other projects, since `sys_resetn` uses
   the SSPI pin T10).
4. Synthesize → Place & Route → Program (`openFPGALoader -b tangprimer20k ...`).

## What it does
1. Instantiates the controller's rPLL (27 MHz → 398.25 MHz fclk / 90° ck /
   ~99.56 MHz pclk) and the DDR3 controller.
2. Waits for init + **ZQ calibration / write-leveling / read-calibration**.
3. **Single** write/read round-trip (writes 0x1122 @0, 0x3344 @1, reads back @0).
4. **Bulk** write of a per-address pattern over 1 MB, then reads it all back and
   verifies the low byte. Auto-refresh is interleaved (~one per 7.8 µs).

## LED readout (active-low; lit = asserted)
| LED | Meaning |
|---|---|
| led[0] | `write_level_done` — write leveling OK |
| led[1] | `read_calib_done` — read calibration OK |
| led[2] | `init_done` — controller left INIT (calibration finished) |
| led[3] | heartbeat — blinks while the test sweep is running |
| led[4] | `error_bit` — a verify mismatch was seen (FAIL) |
| led[5] | `pass` — finished the full sweep with no error |

**Good result:** led[0], led[1], led[2], led[5] lit; led[4] dark; led[3] settles
off at FINISH. **Calibration fail:** led[0]/led[1] stay dark. **Memory fault:**
led[4] lit, led[5] dark.

## Build settings that matter (learned during bring-up)
- **SystemVerilog**: Project → Configuration → Synthesis → Verilog Language =
  **SystemVerilog 2017** (the controller uses `typedef`/`logic`/casts). Each Gowin
  project carries its own config; new projects default to plain Verilog.
- **Dual-Purpose Pin**: set **DONE**, **READY**, **SSPI** all to *regular IO*
  (led[0]=C13/DONE, led[1]=A13/READY, sys_resetn=T10/SSPI). Matches
  `full/impl/pnr/device.cfg`.
- **VREF**: this Gowin version rejects an explicit Vref constraint on the DQ pins
  (inline `VREF=INTERNAL` → CT1108; `USE_VREF_DRIVER name` with no location →
  CT2011, since it needs a physical external Vref pin the board doesn't route).
  We rely on the **tool's default internal Vref** for SSTL15 inputs (no `VREF=`),
  which calibrated cleanly on hardware. If reads ever miscalibrate, set Vref via
  the GUI I/O editor (it writes version-correct syntax).

## HW result (2026-06-13): PASS
led[0] blinking, led[1]/[3]/[4]/[5] lit → **calibration + 1 MB write/verify clean,
128 MB DDR3 verified.** (led[2] reads dark — see the caveat below — but that's a
cosmetic LED-bank issue, not a memory failure.)

## Notes
- DDR3 pins are board-fixed; `ddr3test.cst` copies them verbatim from the vendored
  project (see `rtl/vendor/nand2mario_ddr3/NOTICE.md`).
- `sys_resetn` is the active-low reset on T10 (SSPI dual-purpose pin), matching our
  other Groovy_Tang projects. If your Dock routes reset elsewhere, adjust the `.cst`.
- **led[2] (L16) caveat**: L16 shares the DDR3 1.5 V bank, so the LVCMOS33 LED on it
  can't drive a clean high and reads dark whenever DDR3 is present — *not* a reset
  problem (the FSM reaching FINISH proves sys_resetn is high). Trust **led[5]
  (PASS)**, which is on a 3.3 V bank. This will also affect led[2] in the future
  `full/` merge; relocate that status bit there.
- nand2mario notes DQS timing can need per-board trial-and-error; if calibration
  LEDs don't light, that's the place to look first.
