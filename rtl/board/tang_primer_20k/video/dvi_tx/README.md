# Gowin DVI_TX IP (proprietary — NOT committed)

This directory needs the Gowin **DVI_TX** IP, which is encrypted/proprietary
Gowin IP and is therefore git-ignored (not redistributed under our GPL).

Get `dvi_tx.v` one of two ways:
1. **Gowin IP wizard**: Tools -> IP Core Generator -> Multimedia -> DVI_TX,
   8-bit RGB, generate; copy the produced `dvi_tx.v` here. OR
2. **Copy** from the Sipeed example: `TangPrimer-20K-example/HDMI/src/dvi_tx/dvi_tx.v`.

Module is `DVI_TX_Top` (ports: I_rst_n, I_serial_clk, I_rgb_clk, I_rgb_vs/hs/de,
I_rgb_r/g/b[7:0], O_tmds_clk_p/n, O_tmds_data_p/n[2:0]).
