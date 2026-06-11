# Ethernet bring-up — Milestone B (receive GM commands + reply over UDP)

Receives Groovy_MiSTer UDP commands and **replies over UDP**. Built on Sipeed's
proven RMII+UDP stack (`rtl/vendor/sipeed_udp/`, Apache-2.0).

Datapath:
```
PHY ─ udp(RX) ─ groovy_packet_parser ─┬─ groovy_session (INIT/CLOSE state)
                                       ├─ groovy_ack_policy → groovy_ack_sender (13B ACK)
                                       └─ get_features_valid → groovy_features (12B descriptor)
                              reply addr (req_ip/req_port) from the IP header
                                       │
                       groovy_tx_arbiter ─ udp(TX) ─ PHY → PC
```
Replies implemented: **ACK** (after INIT / GET_STATUS / BLIT) and **FEATURES**
(v2.0.0 `CMD_GET_FEATURES`). Source port 32100; destination = the requester.

## LED panel (active-low; lit = true)
| LED | Meaning |
|---|---|
| `led[5]` | heartbeat (~1.6 Hz). Liveness of clock/bitstream. |
| `led[4]` | `ready` — udp stack initialized. |
| `led[3]` | `clk50m` running (blinks). |
| `led[2]` | `rx_seen` — any RX byte arrived (sticky). |
| `led[1]` | `tx_req_seen` — a reply was sent (sticky). |
| `led[0]` | `session_active` (INIT sets, CLOSE clears). |

## Build (Gowin IDE)
1. **Open** `groovy_eth.gprj` — all sources (vendored udp + parser/session/
   ack_policy/ack_sender/features/tx_arbiter + top), `.cst`, `.sdc` are listed;
   top = `groovy_eth_top`.
2. **Required settings** (Project → Configuration — a fresh clone lacks them; they
   live in the gitignored `impl/<proj>_process_config.json`):
   - **Synthesize → Verilog Language = System Verilog 2017**.
   - **Synthesize → Multiple File Compilation Unit = enabled** (the `rmii.svh`
     `` `ifndef `` guard needs one compilation unit, else "`rmii` already declared").
   - **Dual-Purpose Pin →** Use **DONE / READY / SSPI** as regular IO
     (`led[0]`=C13, `led[1]`=A13, `rst`=T10 are config pins; else P&R `PR2017/PR2028`).

   If you edit project files on disk while the project is open, **close it first**
   (Gowin overwrites its config/.gprj from memory on save).
3. **Synthesize → Place & Route** → `impl/pnr/groovy_eth.fs`.

`build.tcl` (gw_sh) is a fallback.

## Flash (volatile SRAM)
```bash
openFPGALoader -b tangprimer20k impl/pnr/groovy_eth.fs
```
(If it hangs at "Erase SRAM", move the Dock mode switch.)

## Test — now with real replies
```bash
# PC eth static IP 192.168.15.15/24 (board .14), cable board↔PC:
tools/gm_test_sender.py --host 192.168.15.14 features   # -> "FEATURES: protocol v2.0.0 | compression=RAW | rgb=RGB888|RGB565"
tools/gm_test_sender.py --host 192.168.15.14 init --rgb 0   # -> "ACK: frameEcho=0 ... "  + led[0] ON
tools/gm_test_sender.py --host 192.168.15.14 status     # -> "ACK: ... fpga vCount=<changing>"
tools/gm_test_sender.py --host 192.168.15.14 close      # led[0] OFF (no ACK on close)
```

## What success looks like
- `features` prints a decoded descriptor → **TX round-trip + v2.0.0 negotiation works.**
- `init`/`status` print an **ACK** (no more timeout) → ACK path works; `led[1]` lit.
- `led[0]` tracks INIT/CLOSE → RX/session still good.

ACK status fields (`fpga frame/vCount/status`) are placeholders until the video
pipeline exists (Rung 4+); only `vCount` changes (a counter) to show liveness.
