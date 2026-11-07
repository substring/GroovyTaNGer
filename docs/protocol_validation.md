# Groovy_Tang — step-by-step protocol validation ladder

Goal: bring up the Groovy_MiSTer protocol **one capability at a time**, and for
each one have a **closed-loop confirmation** that the FPGA actually applied the
setting — not just "it compiled" or "no error". Each rung is validated first in
**simulation** (feed the exact wire bytes, check outputs) and then on
**hardware** (real PC client + observable result).

Legend: ☐ todo · ◐ sim-verified · ● hardware-confirmed.
References: `original_spec.md` §5 (protocol), §9 (roadmap phases).

---

## Rung 0 — Verify the protocol against the real source (prerequisite)

Our `groovy_packet_parser.v` currently encodes **inferences** from the spec.
Before validating anything on the wire, confirm them against the authoritative
Groovy_MiSTer source so we're validating the right thing.

- ☐ Read `api/groovymister.{cpp,h}` (client) + `hps_linux/.../groovy.cpp`
  (receiver) and pin down, with citations:
  - ACK struct: exact fields, `packed`?, endianness (vs our 13-byte LE assumption)
  - BLIT variant disambiguation: **packet length** (our assumption) vs `lz4` mode + flag
  - INIT: any magic/version handshake beyond the 5 bytes?
  - GET_VERSION reply format (spec: "to confirm")
  - `frame_delta` wire encoding (spec does NOT define it — blocker for Rung 9)
  - timeout / re-sync rule for the header-less stream
  - GMC port 32105 purpose (spec Q6)
- ☐ Produce `docs/protocol_verified.md`: a diff of "spec/parser assumption vs.
  source truth", and fix `groovy_packet_parser.v` / `groovy_ack_sender.v` where
  they diverge.

**Confirms:** we are bit-for-bit compatible by construction, not by guess.

---

## Validation instrumentation (build once, reuse every rung)

- ☐ **PC test sender** (small Python/C UDP tool): emits ONE chosen packet
  (INIT / SWITCHRES / BLIT / …) with controllable fields, and prints the raw
  ACK bytes it gets back. Lets us validate each command in isolation, before
  involving GroovyMAME. (GroovyMAME is the final integration client, not the
  unit-test client.)
- ☐ **FPGA debug readback** (UART or on-chip ILA): expose internal state that
  the standard ACK does NOT carry — active `htotal/vtotal`, PLL `idiv/fbdiv/odiv`,
  PLL `lock`, mode-change FSM `ready/error`, RX byte counters. This is the
  primary "is the setting really in place?" window during bring-up.
- Rule: debug readback stays OUT of the wire protocol (UART/ILA only) so V1 stays
  strictly Groovy_MiSTer-compatible (spec §4).

---

## Rung 1 — Link + INIT handshake

- **Goal:** PC sends `CMD_INIT`; FPGA returns a well-formed 13-byte ACK.
- **FPGA needs:** eth_phy + mac_rx + ipv4/udp parser → packet_parser → ack_sender
  → udp_tx → mac_tx (spec §6.4, Phase 5).
- **Validate (sim):** ◐ INIT bytes → parser `init_valid` → ack_sender emits 13
  bytes (already have tbs for both halves; add an end-to-end RX→ACK tb).
- **Validate (HW):** test sender receives 13 bytes with sane `status_bits`.
- **Confirms:** the whole RX-parse-ACK-TX loop is alive.

## Rung 2 — GET_STATUS round-trip (the heartbeat)

- **Goal:** PC polls; ACK reports live `fpga_vga_frame` / `fpga_vga_vcount`.
- **FPGA needs:** video_timing_gen running; ACK wired to its counters.
- **Validate (sim):** ◐ drive timing_gen, GET_STATUS → ACK `vcount` tracks the
  raster; `frame` increments at frame_start.
- **Validate (HW):** repeated polls show `vcount` sweeping `0..vtotal-1` and
  `frame` rising → proves the raster is alive and the ACK mirrors it.
- **Confirms:** the ACK is a trustworthy validation channel for later rungs.

## Rung 3 — GET_VERSION

- **Goal:** PC reads version; FPGA replies in the verified format (Rung 0).
- **Validate (sim/HW):** ◐/● reply bytes match the format from source.

## Rung 4 — SWITCHRES: change mode / pixel clock  ⟵ the example we want first

- **Goal:** PC sends a new modeline + `pClock`; FPGA retimes and **confirms it**.
- **FPGA needs:** packet_parser (sr_* fields) → float `pClock`→kHz decoder →
  superres_factor → pll_solver → mode_change_fsm → rpll_gowin reconfig →
  video_timing_gen reload (spec §5.5, §7, §8; Phases 3/4).
- **Validate (sim):** ◐ feed two different SWITCHRES packets; check
  - solver picks coeffs whose achieved clock ≈ requested×N (pll_solver tb style),
  - mode_change_fsm runs solve→vblank→load→lock→reload→ready with no `error`,
  - timing_gen now produces the NEW htotal/vtotal.
- **Validate (HW) — "setting is in place":**
  1. **ACK cross-check:** after the switch, `fpga_vga_vcount` in the ACK now
     sweeps `0..NEW_vtotal-1` (its max reveals the active vtotal) → vertical
     timing reloaded.
  2. **Debug readback:** UART/ILA shows active `htotal/vtotal` == requested,
     `idiv/fbdiv/odiv` from the solver, and PLL `lock=1`, FSM `ready=1 error=0`.
  3. **Pixel-clock check:** measured refresh = pclk_out / (htotal×vtotal); compare
     to expected. PLL `lock` proves the clock reprogrammed; refresh proves its value.
  4. **Output check:** monitor / capture card / OSSC reports the new resolution
     and refresh.
- **Confirms:** end-to-end mode + pixel-clock change, with FPGA-side proof it applied.

## Rung 5 — First BLIT (raw RGB888)

- **Goal:** PC sends `CMD_BLIT_FIELD_VSYNC` + header-less pixel stream; image shows.
- **FPGA needs:** isBlitting state, byte counter → VRAM (ring_buffer/DDR3, Phase 7),
  read pipeline → super-res replicate → HDMI (Phase 2/6).
- **Validate (sim):** ◐ blit decode + byte-count completion returns to idle at the
  expected size (RGB888 = hActive×vActive×3).
- **Validate (HW):** correct image on screen; ACK `frame_echo` == sent frame#;
  `status_bits` vram_ready/vram_synced set.
- **Confirms:** the core video path PC→HDMI.

## Rung 6 — frame_dup

- **Goal:** BLIT with dup flag, no pixels → FPGA repeats the previous frame.
- **Validate (sim):** ◐ dup blit decodes with `blit_flag`, expects 0 pixel bytes.
- **Validate (HW):** image persists; frame counter advances; no corruption.

## Rung 7 — Audio (CMD_AUDIO)

- **Goal:** audio burst streamed → HDMI data-island audio.
- **FPGA needs:** sound_buffer + HDMI audio (Phase 10).
- **Validate (sim):** ◐ AUDIO size parsed; byte-count stream completes.
- **Validate (HW):** audible / analyzer shows audio InfoFrame + samples.

## Rung 8 — LZ4 blit

- **Goal:** compressed blit decodes to the same pixels as raw.
- **FPGA needs:** lz4_decoder port (Phase 8).
- **Validate (sim):** ◐ decode a GroovyMAME-produced LZ4 block; bytes == raw ref.
- **Validate (HW):** image identical to Rung 5 for the same source frame.

## Rung 9 — frame_delta   (BLOCKED on Rung 0: encoding unknown)

- **Goal:** delta-vs-previous-frame payload reconstructs the full frame.
- **Validate (sim):** ◐ once the wire format is known, decoded frame == full-frame ref.
- **Validate (HW):** moving content renders correctly with deltas enabled.

## Rung 10 — Interlaced (field 0/1)

- **Goal:** `CMD_BLIT_FIELD_VSYNC` field handling; interlaced output.
- **FPGA needs:** timing_gen half-line + AVI InfoFrame scan_info (Phase 9).
- **Validate (HW):** interlaced mode correct on a CRT/capture; `vga_f1` status toggles.

## Rung 11 — Loss / timeout resync

- **Goal:** a dropped pixel packet doesn't wedge the receiver.
- **Validate (sim):** ◐ truncated stream → timeout rule (Rung 0) returns to idle.
- **Validate (HW):** induce loss; subsequent frames recover.

## Rung 12 — Inputs (port 32101)

- **Goal:** FPGA emits joystick/PS2 reports to the PC.
- **Validate (HW):** test sender/client receives well-formed input packets.

---

### Closed-loop principle (applies to every rung)
"Setting is in place" is proven by **at least one FPGA-sourced signal**, not by
the PC merely having sent the command:
- the **ACK** (echoes, frame/vcount, status_bits) for anything the protocol exposes,
- the **debug readback** (UART/ILA) for internal state the protocol doesn't,
- the **physical output** (HDMI image/refresh/audio) for the end result.
