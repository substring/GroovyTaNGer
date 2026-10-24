# Groovy_Tang — status and resume point (2026-10-24, evening)

Branch: `ddr3-audit` (not pushed). Everything below is committed.

## What works on the board

**Beam-race video over the network, BRAM line ring (`gwline`)**: a real game video
(640x480 59.94 fps capture) plays from the PC to the HDMI screen line by line, ~14 source
lines ahead of the raster, with no frame buffer: smooth, no visible glitch. 10-minute runs
hold the lock (LT=14) with no drift.

- Ring: `rtl/core/groovy_linering.v` (writer never waits, free-running raster, per-slot
  line tags). Network: `udp.sv` fixes (back-to-back frames, header-FIFO reject test,
  TX framing race, 1 ms TX hold-off), `groovy_udp_rx_framer.v`, `groovy_tx_arbiter.v`.
- **Audio on the Dock's 3.5 mm jack**: CMD_AUDIO PCM -> 4096-word buffer -> PT8211 DAC
  (`rtl/core/groovy_audio.v`; WS low = right, heard on the board). A game video plays
  with its soundtrack in sync: "ça marche super bien".
- **Raster beacon** (protocol extension `CMD_SET_BEACON`, code 11, opt-in): the FPGA pushes
  its raster phase once per video frame; the sender locks on the kernel receive timestamp
  (phase error a few us). See `docs/protocol_v2_features.md`.

## How to run it again

```bash
sudo ip addr add 192.168.15.15/24 dev enp6s0        # PC on the board's subnet (temporary)
openFPGALoader -b tangprimer20k rtl/board/tang_primer_20k/gwline/impl/pnr/gwline.fs
python3 tools/gm_test_sender.py --host 192.168.15.14 blitrace --video video.mp4 --audio video --frames 3600 --beacon
```
Build first if `impl/` is empty: `tools/gw_build.sh rtl/board/tang_primer_20k/gwline/gwline.gprj`
(retry on "License verification failed"). `--audio tone` = 440 Hz left / 660 Hz right
(channel check). The PC's 192.168.15.15 address can vanish when the link resets
(NetworkManager): re-add it. After a USB re-enumeration the UART is back at 9600 bauds:
`stty -F /dev/ttyUSB1 115200 raw -echo`. Other sources: `--anim scroll --image <png>`,
`--anim bars`, `--pattern hbars`. Ctrl+C prints the summary. A line ring shows nothing once
the stream stops: a blank screen at the end is normal. Debug UART: `/dev/ttyUSB1` 115200
(`GL=02D0` = all 720 lines valid, `LT` = writer lead, `TO`/`RJ` must stay 0, `AL` audio
buffer level, `AU` audio underruns). If the board
stops answering, button S0 resets it without reflashing.

## Tests

- `make test`: all benches pass.
- Full-top end-to-end benches (Verilator, real tops + real `udp.sv` over RMII):
  `sim/tb/gwline_top_e2e_tb.sv` (pixel-exact output, RMII TX decoder checking every frame
  the FPGA sends, beacons) and `sim/tb/gwddr3net_top_e2e_tb.sv`. Streams come from
  `tools/gen_gwline_stream.py` (`--beacon`, `--status-burst N`).

## Open, in the order agreed with the user

1. **Audio clock drift**: the DAC plays at the PHY's 50 MHz crystal rate, the host sends
   at the raster rate (27 MHz crystal): over long sessions the buffer will slowly fill or
   drain. Needs rate adaptation (or reporting the level so the host adapts). Not done.
2. **Conformance with the original Groovy_MiSTer protocol** before plugging GroovyMAME in:
   re-check `docs/protocol_verified.md` against what the FPGA does now (known gap: the ACK
   always reports `fpga frame=0`).
3. **Isolated short frames**: ~1 frame in 2000-3600 with a few lines missing mid-stream
   (invisible; likely one lost pixel datagram). Not investigated.
4. **Toward a 15 kHz CRT** (user, 2026-10-24): the output is 720p today. Native modes need
   the dynamic geometry on gwline (CMD_SWITCHRES -> modeline + PLL; `groovy_switchres`,
   `groovy_pll_solver`, `superres_factor.v` exist). Open question: do the HDMI->VGA
   converters accept a low pixel clock (~6.7 MHz for 320x240 @ 15 kHz)? If they need the
   ~25 MHz HDMI minimum, replicate pixels horizontally (super-resolution: same line and
   frame rates, the CRT sees no difference). Test on the user's real converter.
5. **Interlaced modes** still to validate: SWITCHRES `interlace` flag and the BLIT `field`
   byte are decoded by the parser but not used; the ring and the raster must handle two
   half-height fields (odd/even lines, half-line offset between fields).
6. **Clear the line ring when the stream stops**: if no line arrives for more than N video
   frames (N to define), blank the ring. Today the last ring lap stays on screen: after a
   stream ends the UART shows `GL=0060` = 96 output lines (32 source lines) still valid.
7. **Screensaver based on the GroovyArcade logo** when no stream is coming (after the ring
   is cleared). Logo asset and its licence to check before embedding it.
8. **HDMI audio**: add an open HDMI encoder (data islands) **next to** the Gowin DVI_TX,
   both kept and selectable; then advertise/select the audio output (HDMI or jack, with a
   default) in protocol v2 (planned in `docs/protocol_v2_features.md`).

## Parked

**DDR3 full-frame path (`gwddr3net`)**: the network -> DDR3 -> HDMI path is bit-exact (port
rework `groovy_gwddr3_port.v`), but whenever the DDR3 controller runs the HDMI output shows
crawling wrong pixels on some colours. Full investigation and next ideas:
`docs/hdmi_ddr3_interference.md`.
