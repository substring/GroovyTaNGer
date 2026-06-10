# Phase 1 — LED blink (first flashable bring-up)

The smallest design that proves the **toolchain → board → programming → clock**
path before any HDMI/Ethernet work (spec §9, Phase 0/1). Blinks the Dock LED at
~1 Hz from the 27 MHz clock.

## Files
- `led_blink.v` — top (`Clock` → H11, `IO_voltage` → L14)
- `led_blink.cst` — pin constraints (**[VERIFY]** before flashing)
- `build.tcl` — `gw_sh` command-line build

## Pins (from the Sipeed reference)
| Signal | Pin | Note |
|---|---|---|
| `Clock` | `H11` | 27 MHz crystal (core board) |
| `IO_voltage` | `L14` | LED (Dock ext board) |

Source: <https://wiki.sipeed.com/hardware/en/tang/tang-primer-20k/examples/led.html>
**[VERIFY] confirm against your board revision before flashing** — a wrong
`IO_LOC` on a power/clock pin can damage the board.

## Build (you have Gowin EDA; board not connected yet)

Command line:
```bash
cd rtl/board/tang_primer_20k/bringup
gw_sh build.tcl          # -> impl/pnr/*.fs
```
Or GUI: New Project → device `GW2A-LV18PG256C8/I7` → add `led_blink.v` +
`led_blink.cst` → Synthesize → Place & Route.

**Building successfully (producing a `.fs`) is the milestone you can hit right
now without the board.** It validates the RTL, the constraints syntax, and the
device part string.

## Flash (once the board is connected)
```bash
# SRAM (volatile, fastest for testing):
openFPGALoader -b tangprimer20k impl/pnr/led_blink.fs
# or use Gowin Programmer.
```
Expected: the L14 LED blinks ~1 Hz. If it's solid on/off instead, the LED
polarity or `HALF_PERIOD` is off — harmless, adjust and re-flash.

## Verified in simulation
The divider logic is checked by `sim/tb/led_blink_tb.v` (`make led_blink_tb`),
which runs with a tiny `HALF_PERIOD` and confirms the output toggles on schedule.
This doesn't replace on-board testing but catches logic mistakes early.
