# Vendored: nand2mario UART TX (Tang Primer 20K)

- Source: https://github.com/nand2mario/ddr3-tang-primer-20k -> `src/`
- Upstream author: **nand2mario**
- License: **Apache-2.0** (see `LICENSE` in this directory)

## Files
| File | Origin | Role |
|---|---|---|
| `uart_tx_V2.v` | nand2mario | UART TX used for the debug line on /dev/ttyUSB1 (gwline, gwddr3net). |

The rest of that project (the DDR3 controller, its rPLL and test helpers) was used
during the DDR3 bring-up and removed at release (tag `pre-release-purge`); the DDR3
designs now use the Gowin DDR3 Memory Interface IP.

## License compatibility
Groovy_Tang is **GPL-2.0-or-later**. Apache-2.0 is incompatible with GPLv2 but
compatible with **GPLv3**; the "or later" lets the combined work be used under GPLv3.
Apache-2.0 NOTICE/attribution is preserved here: do not strip the file's license header.

## Local use
Vendored unmodified (only a provenance header banner added).
