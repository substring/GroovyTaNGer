# Merged design — network + HDMI (Phase 3a)

One bitstream with **both** halves: the proven Ethernet stack *and* the dynamic
video pipeline. A `CMD_SWITCHRES` over UDP retunes the live HDMI output.

```
UDP RX → parser → groovy_switchres → {idiv,fbdiv,odiv,N} ─┐
                                     native modeline ──────┤ (×N scale, on new result)
                                                           ▼
        rpll_sel_encode → rpll_tmds_dyn → CLKDIV/5 → pix_clk
        video_timing_gen(modeline) → test_pattern_gen → DVI_TX → HDMI
```

- **Power-up shows a default 720p** test pattern (so the two halves' coexistence —
  2 rPLLs, RMII + TMDS pins, shared clk/rst — is provable on its own).
- A `switchres` command recomputes the rPLL coefficients + super-res N and retunes
  the display, blanking for a ~3 ms settle (we never wait on the rPLL LOCK — it
  doesn't assert in dynamic mode).
- No real pixels yet (test pattern) and no ×N pixel replicator yet (Phase 3b);
  the modeline is scaled by N so even low-res super-res modes show the pattern at
  the right output resolution. Sync polarity is hardcoded **positive** for now
  (TODO: from the modeline) — test with positive-sync modes.

## Build (Gowin IDE)
1. Open `groovy.gprj`.
2. **Project → Configuration → Synthesize**: Verilog Language = **System Verilog
   2017**, **Multiple File Compilation Unit** = ON (the top is SV; mixes with the
   Verilog cores).
3. **Project → Configuration → Dual-Purpose Pin**: enable **Use DONE/READY/SSPI as
   regular IO** (led[0]=C13/DONE, led[1]=A13/READY, rst=T10/SSPI).
4. Synthesize → Place & Route → flash `impl/pnr/groovy.fs`.
   - If P&R fails to place two rPLLs, the TMDS rPLL may collide with PLL_6M; we'd
     then pin the rPLL sides via constraints.

## Test (PC at 192.168.15.15/24, board 192.168.15.14)
```bash
# power-up: 720p bars on the monitor; network still answers:
python3 tools/gm_test_sender.py --host 192.168.15.14 features      # GTF1 reply
python3 tools/gm_test_sender.py --host 192.168.15.14 srresult      # GTSR reply

# switch the live display to 800x600@60 (positive sync):
python3 tools/gm_test_sender.py --host 192.168.15.14 switchres --pclk 40.0 \
  --hactive 800 --hbegin 840 --hend 968 --htotal 1056 \
  --vactive 600 --vbegin 601 --vend 605 --vtotal 628
# ... and to 1024x768@60 (positive sync):
python3 tools/gm_test_sender.py --host 192.168.15.14 switchres --pclk 65.0 \
  --hactive 1024 --hbegin 1048 --hend 1184 --htotal 1344 \
  --vactive 768 --vbegin 771 --vend 777 --vtotal 806
```
Expect the monitor to switch resolution to each, still showing our color bars.

LEDs (active-low, bit index = physical Dock LED): `[5]`=heartbeat `[4]`=eth ready
`[3]`=rx_seen `[2]`=session `[1]`=pix_clk alive `[0]`=**frame received**.

## Rung 5 — network video (BLIT pixels -> double-buffered VRAM -> scaler -> HDMI)
Default output is **800x600@60 (~40 MHz pixel)** with a **100x75 native** frame
scaled **x8** to fill it. `groovy_blit_rx` accumulates pixel datagrams to
`bytes_len = 100*75*bpp`, two VRAM banks ping-pong (write one / display the other,
swap in vblank, frameskip), and `groovy_pixel_reader` (5-stage pipelined) upscales
to the raster. Do **not** send SWITCHRES for this (output stays at the default).

Why 800x600 not 720p: at 74.25 MHz the read+BRAM path is too tight on the GW2A and
pixels flicker; 40 MHz has the margin to be clean. (DDR3 + higher res is later.)

```bash
# board .14, PC .15 (re-add 192.168.15.15 after sleep!).
python3 tools/gm_test_sender.py --host 192.168.15.14 blitimg     # one 100x75 frame
python3 tools/gm_test_sender.py --host 192.168.15.14 blitstream  # continuous (animated bar)
```
Expect: a **gradient** (red ->right, green ->down, 8x8 white origin marker) for
`blitimg`, and a **smooth white bar sweeping** for `blitstream` - stable, no tearing
or flicker. `led[0]` lights when a full frame is received. (`blitimg` = INIT rgb565
+ BLIT header + the 15000-byte frame; `blitstream` paces frames continuously.)

Limitations (next steps): fixed 160x90 + power-of-2 scale (arbitrary super-res N
and SWITCHRES-driven sizing TODO); single-buffer (tearing) -> beam-racing; BRAM
only -> DDR3 for full-size arcade frames.
