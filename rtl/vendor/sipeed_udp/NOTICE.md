# Vendored: Sipeed / ZiyangYE RMII UDP stack

These files are vendored **verbatim** from Sipeed's Tang Primer 20K examples,
RMII + IPv4/UDP/ARP engine for the RTL8201 PHY. They let Groovy_Tang receive and
send UDP without writing an Ethernet MAC from scratch (spec §6.4, roadmap Phase 5).

- Source: https://github.com/sipeed/TangPrimer-20K-example  → `Ethernet/verilog_UDP/`
- Upstream author: **ZiyangYE** — https://github.com/ZiyangYE/Verilog_TCP
- License: **Apache-2.0** (see `LICENSE` in this directory)

## Files
| File | Origin | Role |
|---|---|---|
| `udp.sv` | Sipeed/ZiyangYE | RMII MAC + ARP + IPv4 + UDP; byte-stream RX/TX interface |
| `rmii.svh` | Sipeed | RMII SystemVerilog interface |
| `PLL_6M.v` | Sipeed (Gowin IP) | rPLL: 27 MHz → 6 MHz / 1 MHz (the udp block's `clk1m`) |
| `top_loopback_reference.sv` | Sipeed | the original loopback top — kept as a reference only |

## License compatibility
Groovy_Tang is **GPL-2.0-or-later**. Apache-2.0 is incompatible with GPLv2 but
compatible with **GPLv3**; the "or later" lets the combined work be used under
GPLv3. Apache-2.0 NOTICE/attribution is preserved here. Do not strip these files'
license headers.

## Local use
Not modified. Our integration lives outside this directory
(`rtl/board/tang_primer_20k/eth/groovy_eth_top.sv`), which instantiates `udp` and
bridges its byte stream into `groovy_packet_parser` / `groovy_session` /
`groovy_ack_*`.
