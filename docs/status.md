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
   audited 2026-10-30, see `docs/protocol_conformance_2026-10.md`. GroovyMAME speaks its own
   dialect (CMD_BLIT_VSYNC 6, RGB888 only) that gwline rejects; ACK frame counter = 0 and
   audio bit semantics block a stock client; raw RGB888 does not fit 100 Mbit for most
   modes (decision: RGB565 client patch and/or LZ4). Fix order in that document.
   Done since (sim only): CMD 6, ACK frame counter / vCount / audio bit, RGB888 B,G,R
   order, frame size from SWITCHRES. Client side: `patches/groovymame-mister-rgb565.patch`
   and `patches/groovymame-mister-pacing.patch` (kernel pacing via the fq qdisc, so the
   RGB565 burst does not overflow the 32-line ring), all in `docs/groovymame_client.md`,
   including the frame-delay constraint (fd >= ~8.9 for a 262-line mode).
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
   half-height fields (odd/even lines, half-line offset between fields). Many HDMI->VGA
   converters reject or deinterlace interlaced input; the analog RGB path (item 10) has no
   such issue: the CRT gets exactly our syncs (field toggle + half-line VSYNC shift, mirrored
   in the composite sync), at modest clocks (640x480i ~12-13.5 MHz).
6. **Clear the line ring when the stream stops**: if no line arrives for more than N video
   frames (N to define), blank the ring. Today the last ring lap stays on screen: after a
   stream ends the UART shows `GL=0060` = 96 output lines (32 source lines) still valid.
7. **Screensaver based on the GroovyArcade logo** when no stream is coming (after the ring
   is cleared). The user maintains GroovyArcade: the logo is theirs and they choose its
   licence (ask which one to state in the repo when the asset is added).
8. **HDMI audio**: add an open HDMI encoder (data islands) **next to** the Gowin DVI_TX,
   both kept and selectable; then advertise/select the audio output (HDMI or jack, with a
   default) in protocol v2 (planned in `docs/protocol_v2_features.md`).
9. *(low priority)* **Adjustable audio latency**: if an HDMI->VGA converter adds video lag,
   delay the sound to match. The audio buffer can do it: a configurable pre-roll / fixed
   delay in samples (build parameter first, then maybe a v2 protocol setting).
10. **Analog RGB out through the Dock's RGB LCD connector** (user idea, 2026-10-24; parallel
   LVCMOS RGB, not LVDS): a
   native-clock path to the CRT with no HDMI 25 MHz floor and no converter lag. The
   connector carries RGB565 + HS/VS/DE + pixel clock in LVCMOS 3.3 V: R L9 N8 N9 N7 N6,
   G D11 A11 B11 P7 R7 D10, B B12 C12 B13 A14 B14, DCLK R9, HS A15, VS D14, DE E15 (Sipeed
   `TangPrimer-20K-example/RGB_lcd`, whose 480x272 example already runs at ~9 MHz). No pin
   clash with Ethernet, audio or LEDs. FPGA side: route the ring's RGB565 + our timing to
   these pins (composite sync on HS for SCART/JAMMA), pixel clock from the dynamic PLL.
   Hardware: 40-pin 0.5 mm FPC -> 2.54 mm breakout (pinout to confirm on the Dock
   schematic / Sipeed screen datasheet), a resistor DAC per channel for 0.7 Vpp into 75 ohm,
   ideally a video buffer amp, or an ADV7123/ADV7125 module. Ready-made option noted by the
   user: the ALIENTEK **ATK-RGB2VGA** module (RGB LCD FPC -> VGA) - check that its FPC
   pinout matches the Dock's and how many bits per colour it takes before buying.
   Modeline limits on this path: none from the connector itself (plain I/O: any porches,
   sync widths, polarities, interlace). Real ones: (a) pixel-clock precision - the integer
   rPLL from 27 MHz cannot hit every clock exactly (refresh e.g. 59.94 instead of 60.00,
   matters for GroovyMAME sync; fractional-N later), low clocks are fine; (b) the ring's
   line slots are 512 source pixels (arcade widths go to ~768: wider slots = more BSRAM);
   (c) the electronics after the FPC (an active module may limit bandwidth or expect LCD
   timings) and the monitor's own H/V ranges.
11. *(option)* **RGB888 end to end**: today the whole path is RGB565 (`blit_rx` packs the
   host's RGB888 to 565 to fit the ring), and the Dock's RGB LCD connector only wires 5/6/5
   data lines, so it can never output more than 565. 888 would need (a) a 24-bit ring (about
   +50 % BSRAM for the 32 lines; 33/46 used today) and (b) for the CRT, 24 data pins from the
   Dock's free expansion pins to our own DAC (e.g. an ADV7123 module) instead of the FPC; DVI
   already carries 8 bits per colour. 565 covers most arcade boards (4-6 bits per channel);
   later games' gradients would show banding.
12. **CRT output: a real trade-off to choose (and document for users)**:
   - **"pure VGA" through the RGB LCD connector**: RGB565 at most (the FPC wires 5/6/5),
     but native pixel clock, no converter lag, interlace exactly as generated;
   - **RGB888 through HDMI + an HDMI->VGA converter**: full 8 bits per colour (once the ring
     is 24-bit, item 11), but the converter may impose a ~25 MHz minimum (super-resolution),
     add lag (audio latency, item 9) and reject or deinterlace interlaced modes.
   (RGB888 *and* native analog would need our own DAC on free pins, item 11.)

13. **Information overlay (user, 2026-10-30)**: for ~10 s, show the requested resolution,
   refresh rate, line rate, scale factors and pixel clock over the picture, white pixel-font
   text with a 1-px black outline, drawn in source pixels (40 columns max with an 8-px font).
   Mockups made with three console fonts (VGA 8x8, VGA 8x16, Terminus Bold 8x16 - Terminus
   is OFL, the safest licence to embed); font and position still to choose. Font ROM ~1.5 KB
   (one BSRAM), 2x40-char text buffer, numbers via `binary_to_bcd.v`. Shown at start-up and on
   every mode change (once SWITCHRES drives the geometry).
14. **Dock buttons for the overlay, maybe a real OSD (user, 2026-10-30)**: S0 (T10) is our
   reset; S1 = T3 (both Sipeed examples agree) would show/hide the overlay. The other three
   disagree between Sipeed examples (LiteX: T2 D7 C7; test_board: T4 E8 E9) - check on the
   board over the UART before using them. These pins sit on the DDR3's 1.5 V bank: declare them
   LVCMOS15. Needs a ~10 ms debounce. Later: a small OSD menu driven by the buttons.

## Next session (from the first GroovyMAME run on the CRT, 2026-10-30)

1. **Raster timings + pixel clock from the SWITCHRES modeline** (item 4): the picture is
   shifted because the raster keeps the fixed mode-3 timings; target = modeline porches
   and totals at pclk x N (super-resolution, N so that pclk x N >= ~25 MHz), dynamic PLL.
2. **Interlace** (item 5): does not work at all with GroovyMAME.
3. **Audio crackle in the treble** with GroovyMAME: read `AU=`/`AL=` on the UART (g4ge)
   during a run first; see `docs/groovymame_client.md`.

## Parked

**DDR3 full-frame path (`gwddr3net`)**: the network -> DDR3 -> HDMI path is bit-exact (port
rework `groovy_gwddr3_port.v`), but whenever the DDR3 controller runs the HDMI output shows
crawling wrong pixels on some colours. Full investigation and next ideas:
`docs/hdmi_ddr3_interference.md`.
