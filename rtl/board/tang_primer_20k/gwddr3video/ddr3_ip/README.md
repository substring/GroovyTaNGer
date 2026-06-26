# Gowin DDR3 Memory Interface IP (regenerate locally)

`ddr3_mi.v` is the **encrypted Gowin DDR3 Memory Interface IP** — proprietary, generated
by the Gowin IP wizard. It is **gitignored** (like the DVI_TX IP); regenerate it locally
before building `gwddr3video`. The committed `ddr3_mi.ipc` is the exact config to reproduce.

## Why this IP
The Tang Primer 20K's DDR3 has a marginal LOW DQS byte lane that NO simple controller
(nand2mario, ZiyangYE slowDDR3, per-lane rclksel) could read reliably (~50% byte errors).
The Gowin official IP does **hardware per-byte-lane read-eye training** (`init_calib_complete`,
`eye_calib_*`), which trains the marginal lane out → clean reads (HW-verified: 0 errors over
76800 words). This IP is the controller that makes the DDR3 framebuffer actually work.

## Requirements
- **Gowin EDA PRO / licensed edition** (e.g. `GOWIN_EDA_1.9.12.03`). The free **Education**
  edition does NOT include the DDR3 Memory Interface IP — you must use the licensed toolchain
  (Sipeed provides a registration server).

## Regenerate (GUI wizard)
1. Open the project's device target: **GW2A-18C**, part `GW2A-LV18PG256C8/I7`.
2. Tools → IP Core Generator → Soft IP Core → Memory Control → DDRx SDRAM →
   **DDR3 Memory Interface**.
3. Output: File Name `ddr3_mi`, Module `DDR3_Memory_Interface_Top`, create in THIS folder
   (`ddr3_ip/`), language Verilog.
4. Config (matches the committed `ddr3_mi.ipc`):
   - **User Interface**: Native (Controller) — *not* AXI4.
   - **Memory Clock**: 400 MHz, **CLK Ratio**: 1:4.
   - **DQ Width** 16, **Row** 13, **Bank** 3, **Column** 10, **Burst** BL8.
   - Leave RTT/ODT/timings at the 1Gb x16 DDR3-800 defaults (see `ddr3_mi.ipc` for exact tRCD/tRC/etc.).
5. Generate → produces `ddr3_mi.v` (+ `temp/`). Build `gwddr3video.gprj`.

## Clocking (already wired in gwddr3video_top.v)
- `clk` = 27 MHz board ref; `memory_clk` = **302.4 MHz** from `mem_pll.v`
  (the proven Sipeed PLL: IDIV4/FBDIV55/ODIV2); `pll_lock` = mem_pll lock.
- The IP outputs `clk_out` (~75 MHz user clock) — the fetch domain. Gate user logic on
  `init_calib_complete`. Refresh is handled inside the IP.
