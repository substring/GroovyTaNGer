# Vendored: nand2mario DDR3 controller (Tang Primer 20K)

Low-latency **DDR3-800** PHY/controller for the GW2A-18C, vendored **verbatim**
from nand2mario's project. It gives Groovy_Tang a 128 MB framebuffer to lift the
BRAM ceilings (capacity + the ~40 MHz read wall) — see `docs/ddr3.md`.

- Source: https://github.com/nand2mario/ddr3-tang-primer-20k → `src/`
- Upstream author: **nand2mario** (originally written for NESTang)
- License: **Apache-2.0** (see `LICENSE` in this directory)
- Tested upstream on SKHynix H5TQ1G63EFR-PBC (the Tang Primer 20K's DDR3 part)

## Files
| File | Origin | Role |
|---|---|---|
| `ddr3_controller.v` | nand2mario | The controller: ZQ cal, write-leveling, read-cal, dynamic ODT. Single 16-bit word port (`rd`/`wr`/`refresh`, `din`/`dout`/`dout128`, `busy`/`data_ready`). |
| `uart_tx_V2.v` | nand2mario | UART TX helper for the bring-up self-test (debug only). |
| `print.v` | nand2mario | ``print`` macro + UART byte queue (`` `include "print.v" ``, debug only). |
| `gowin_rpll.v` | **Gowin IP** | rPLL config: 27 MHz → 398.25 MHz fclk + 90° ck + ~99.5 MHz pclk. **Gowin proprietary, not GPL** — regenerable; see header. |
| `tang20k_reference.cst` | nand2mario | Upstream DDR3 pin map — **reference only**; our pins live in our board `.cst`. |

Not vendored: upstream `ddr3_top.v` (their test top) and `ddr3.sdc` — our own
bring-up top and SDC live under `rtl/board/tang_primer_20k/`.

## License compatibility
Groovy_Tang is **GPL-2.0-or-later**. Apache-2.0 is incompatible with GPLv2 but
compatible with **GPLv3**; the "or later" lets the combined work be used under
GPLv3. Apache-2.0 NOTICE/attribution is preserved here — do not strip these
files' license headers. `gowin_rpll.v` is Gowin proprietary IP (not GPL, not
ours to relicense); see the root `LICENSE` "Gowin Proprietary IP" section.

## Local use
Vendored unmodified (only provenance header banners added). Our integration —
the bring-up top, the DDR3 PLL wiring, the framebuffer line-buffer adapter — lives
outside this directory under `rtl/board/tang_primer_20k/` and `rtl/core/`.
