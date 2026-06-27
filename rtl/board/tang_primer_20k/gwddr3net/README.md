# gwddr3net — networked DDR3 framebuffer (first networked picture)

The merge of the two proven halves of the project:

```
                 clk50m (network)                           pclk (~75 MHz)            pix_clk (74.25 MHz)
 PHY ─ udp ─ parser ─ session ─ blit_rx ─┐                  ┌─ ddr3_writer ─ adapter ─ DDR3 IP
 (RMII)                          (RGB565)  │  async FIFO     │       ▲
                                           └─ groovy_async ──┘       │ (port mux: writer until have_frame, then reader)
                                              _fifo  (CDC)           ▼
                                                          line-buffer reader ─ RGB565→888 ─ DVI_TX ─ HDMI
```

A `CMD_BLIT` + its pixel datagrams are accumulated by `groovy_blit_rx` into RGB565
pixels (50 MHz network domain). Each pixel `{word_addr = y*320+x, rgb565}` is pushed
through a Gray-pointer async FIFO (`groovy_async_fifo`) and drained on the DDR3 user
clock by `groovy_ddr3_writer`, which issues single-word writes through the existing
`groovy_gwddr3_adapter`. So the network fills the DDR3 framebuffer instead of the old
boot test pattern. When the first whole frame has arrived (`frame_done`), a sticky
`have_frame` flag (CDC'd to pclk) releases the line-buffer reader to scan it out to
720p over DVI.

**Static first picture:** single buffer, no double-buffering, no beam-race. The frame
is written once and displayed continuously; a re-sent frame is dropped at the FIFO
(the port mux has handed DDR3 to the reader). Double-buffer + beam-race come later
(see the roadmap).

## Geometry
320×240 RGB565 source → 4×(H) × 3×(V) line-buffer upscale → 1280×720 HDMI output.
Word address for pixel (x,y) = `y*320 + x`, base 0.

## Build
```
tools/gw_build.sh rtl/board/tang_primer_20k/gwddr3net/gwddr3net.gprj
```
The Gowin DDR3 IP (`../gwddr3video/ddr3_ip/ddr3_mi.v`) and DVI_TX
(`../video/dvi_tx/dvi_tx.v`) are encrypted Gowin IP — NOT committed; regenerate them
with the Gowin IP wizard (see each one's README). `impl/gwddr3net_process_config.json`
holds the per-project settings (SystemVerilog 2017, DONE/READY/SSPI as regular IO).

## Test (static picture)
The PC needs a static IP on the board's subnet first (drops on sleep):
```
sudo ip addr add 192.168.15.15/24 dev <iface>
```
Then send a 320×240 RGB565 test image (red→right / green→down gradient + an 8×8
white corner square as the orientation marker):
```
tools/gm_test_sender.py --host 192.168.15.14 blitimg --width 320 --height 240
```
`blitimg` sends its own INIT (rgbMode=2). A correct picture = the gradient fills the
screen with the white square in the top-left corner.

## LEDs (Dock physical-number convention)
board0 = DDR3 calib done · board1 = udp ready · board2 = have_frame ·
board3 = rx_seen · board4 = fetch_active · board5 = heartbeat

## Debug UART (M11 → /dev/ttyUSB1 @115200)
`RD=` frames received · `DP=` dropped pixels (FIFO full, want 0) · `HF=` have_frame ·
`NL=` max source line fetched last frame (~00F0=240 = fetch keeps up) ·
`CO=` max fetch column (~0140=320) · `RY=` udp ready · `SE=` rx_seen
