# HDMI path: DVI_TX IP + HDMI-only probe

- `dvi_tx/`: the Gowin DVI_TX IP used by every design (proprietary, git-ignored; see
  `dvi_tx/README.md` to provide it).
- `hdmi_probe.gprj` / `hdmi_probe_top.v`: a 720p picture from pure logic (no DDR3, no
  Ethernet), the reference used by `docs/hdmi_ddr3_interference.md` to tell an HDMI-path
  problem from one caused by the rest of a design.

## Build and flash the probe
Enable *Project -> Configuration -> Dual-Purpose Pin -> Use SSPI as regular IO*
(`I_rst_n` = T10), or build headless with `tools/gw_build.sh hdmi_probe.gprj`, then:
```bash
openFPGALoader -b tangprimer20k impl/pnr/hdmi_probe.fs
```

## Dynamic rPLL lessons (measured during the video bring-up)
The bring-up designs that proved these were removed at release (tag `pre-release-purge`).
- **The rPLL `LOCK` output does NOT assert in dynamic mode** (`DYN_*_SEL="true"`) even
  though the clock is correct, so never gate on it: `groovy_modeline_ctl` uses a fixed
  settle delay, not a lock wait.
- Dwell long enough (~seconds) per mode for the **monitor** to re-sync; switching too
  fast looks like "no signal".
- `rpll_sel_encode`: IDSEL = 64 - IDIV, FBDSEL = 64 - FBDIV, ODSEL is a table (verified
  against apicula's dynamic example).
