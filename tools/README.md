# tools — protocol bring-up helpers

Host-side utilities for exercising the Groovy_MiSTer protocol against any
GroovyMister receiver (a real MiSTer now, Groovy_Tang once its Ethernet/blit
path exists). Wire formats per [../docs/protocol_verified.md](../docs/protocol_verified.md).

## `gm_test_app.c` — 15 kHz color-bar display

Self-contained C client (no libgroovymister needed). Sends `CMD_INIT` (raw
RGB888), `CMD_SWITCHRES` to a **15 kHz 240p** modeline (6.700 MHz, 320×240,
hfreq 15.73 kHz, 60 Hz), then streams an SMPTE-style color-bar test image every
frame until Ctrl+C (then `CMD_CLOSE`). Prints the ACK status it gets back.

```bash
cc -O2 -Wall -o gm_test_app gm_test_app.c
./gm_test_app <device-ip> [port]      # port defaults to 32100
```

The modeline and image are compile-time constants at the top of the file — easy
to change (e.g. another 15 kHz resolution, or interlaced). Assumes a
little-endian host.

## `gm_test_sender.py` — one packet at a time

Sends a single control packet and decodes the reply. Good for isolating one
validation rung. No build step.

```bash
./gm_test_sender.py --host <ip> version
./gm_test_sender.py --host <ip> init --rate 48000 --chan 2 --rgb 0
./gm_test_sender.py --host <ip> status
./gm_test_sender.py --host <ip> switchres --pclk 6.7 \
    --hactive 320 --hbegin 336 --hend 364 --htotal 426 \
    --vactive 240 --vbegin 244 --vend 247 --vtotal 262 --interlace 0
./gm_test_sender.py --host <ip> blit --frame 1 --field 0 --vsync 0
```

## Status
Both build/run and emit correct on-wire bytes (verified locally). **Not yet
tested against a live receiver** — that happens when a MiSTer or the Groovy_Tang
Ethernet path is available (validation ladder Rungs 1–5).
