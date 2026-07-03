#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Groovy_Tang - beam-race pacing PROOF OF CONCEPT (no FPGA, time-driven sim).
#
# Validates the pacing ALGORITHM before committing it to Verilog (each gwline rebuild is
# ~6 min). This is a TIME-DRIVEN simulation: a virtual microsecond clock advances in fixed
# steps; at every step each pointer moves according to ITS OWN clock, so nothing "runs
# away" (the flaw in the earlier model, where the raster advanced on the sender's time
# even while the writer was stalled).
#
# TWO INDEPENDENT CLOCKS (this is the whole point):
#   * PIXEL clock (FPGA raster) - reads one source line every pix_line_period. The display
#     runs on THIS. It is the reference; it never stalls.
#   * SENDER clock (PC) - emits line packets. Its timing has ERROR (busy-spin = tiny,
#     OS-sleep = large + biased). The --fpga-ppm makes the pixel clock differ from the
#     sender's nominal rate, so the two drift apart over time.
#
# RING MODEL:
#   * N line slots. written / read are MONOTONIC counters (never reset per frame) = the
#     fix. slot = line mod N. --naive-counter uses per-frame indices that wrap to 0 each
#     frame -> reproduces the freeze bug (the guard's subtraction lies at the wrap).
#   * OVERWRITE guard: writer may commit line L only if (L - read) < N (else it would
#     clobber a slot the reader still needs).
#   * UNDERRUN: the raster reaches a line that isn't written yet.
#
# FEEDBACK: every 1/corr_hz s the sender reads the FPGA's reported level and nudges its
# send rate toward mid-buffer (models the FPGA-reports-level closed loop).
#
# Zero UNDERRUN and zero OVERFLOW over the run = the scheme works.
#
# Usage:
#   tools/beamrace_poc.py                              # 32-line ring, busy-spin -> PASS
#   tools/beamrace_poc.py --nlines 8 --naive-counter   # reproduce the freeze
#   tools/beamrace_poc.py --jitter-us 2000             # OS-sleep-class timer -> FAIL
#   tools/beamrace_poc.py --no-feedback --fpga-ppm 300 # open loop + drift -> eventual lap
#   tools/beamrace_poc.py --selftest                   # run the built-in scenario matrix
import argparse, random


def simulate(args, verbose=True):
    # --- time base (everything in seconds; STEP is the sim granularity) ---
    line_period = 1.0 / (args.refresh * args.height)      # ideal seconds per source line
    pix_line_period = line_period / (1 + args.fpga_ppm * 1e-6)  # actual raster line time
    STEP = pix_line_period / 8.0                          # fine enough to catch events
    total_lines = args.height * args.frames
    sim_horizon = total_lines * line_period * 3.0         # safety stop

    N, H = args.nlines, args.height
    grace_lines = args.grace_frames * H     # ignore incidents during startup settling
    rng = random.Random(args.seed)
    # freeze detector: if the writer makes zero progress for this long (while frames
    # remain), it's TRAPPED (the naive-counter wrap bug) - a distinct failure from a
    # transient over/underrun. Measured in sim seconds; a few frames of total stall.
    stall_limit = 3 * H * line_period
    last_written = 0
    last_progress_t = 0.0
    frozen = False

    # --- state ---
    written = 0            # monotonic: highest source line committed to the ring
    read = 0               # monotonic: source line the raster has reached
    have_frame = False     # SYNC/FILL done, raster running
    underruns = overflows = 0

    # raster clock: counts pixel-clock time since scanout started
    raster_t = 0.0         # seconds of raster time elapsed (only advances once have_frame)

    # sender schedule (sender clock): next emit time, on the SIM clock
    t = 0.0
    next_emit = 0.0
    rate_scale = 1.0
    next_corr = 0.0
    corr_period = (1.0 / args.corr_hz) if args.corr_hz > 0 else 1e18

    def guard_lap(next_line):
        # would writing next_line clobber a slot the reader still needs?
        if args.naive_counter:
            # BUG: compare per-frame indices; at wrap read=0 while writer is high -> lies
            w_idx = next_line % H
            r_idx = read % H
            ahead = (w_idx - r_idx) % H
            return ahead >= N and next_line >= N
        return (next_line - read) >= N     # monotonic: always the true gap

    steps = int(sim_horizon / STEP)
    for _ in range(steps):
        if written >= total_lines and read >= total_lines:
            break
        t += STEP

        # freeze detection: writer trapped (no progress) while frames remain
        if written > last_written:
            last_written = written
            last_progress_t = t
        elif written < total_lines and (t - last_progress_t) > stall_limit:
            frozen = True
            break

        # ---- RASTER advances on the PIXEL clock (independent, never stalls) ----
        if have_frame:
            raster_t += STEP
            new_read = int(raster_t / pix_line_period)
            if new_read > read:
                # for every line the raster crossed, check underrun BEFORE moving read.
                # Ignore the startup transient (first `grace` lines) - SYNC/FILL settling
                # is not a steady-state incident; we measure the running regime.
                for L in range(read + 1, new_read + 1):
                    if L < total_lines and L > written and L > grace_lines:
                        underruns += 1     # raster reached an unwritten line
                read = new_read

        # ---- SENDER emits packs on ITS clock (with timer error) ----
        while t >= next_emit:
            placed = 0
            for _ in range(args.pack):
                if written >= total_lines:
                    break
                if guard_lap(written):     # writing line `written` next
                    if written > grace_lines:   # ignore SYNC/FILL startup transient
                        overflows += 1
                    break
                written += 1
                placed += 1
                if not have_frame and written >= args.margin_start:
                    have_frame = True      # release the raster now
            # closed-loop level correction. rate_scale multiplies the INTER-EMIT PERIOD:
            # buffer too FULL (err>0) -> SLOW DOWN -> longer period -> rate_scale > 1.
            # buffer too EMPTY (err<0) -> speed up -> shorter period -> rate_scale < 1.
            # A small gain + a DEADBAND (only correct when off by more than a couple of
            # lines) keeps it from oscillating - a hard proportional term chatters. This
            # is a coarse stand-in; the REAL controller gets tuned on HW with real latency.
            if not args.no_feedback and t >= next_corr:
                level = written - read
                err = level - (N // 2)
                if abs(err) > args.deadband:
                    rate_scale = max(0.9, min(1.1, 1.0 + args.gain * err))
                else:
                    rate_scale = 1.0
                next_corr = t + corr_period
            # schedule the next emit (sender clock) with timer error
            nominal = args.pack * line_period * rate_scale
            jitter = rng.uniform(-args.jitter_us, args.jitter_us) * 1e-6
            bias = args.bias_us * 1e-6
            next_emit += max(STEP, nominal + jitter + bias)

    ok = (underruns == 0) and (overflows == 0) and (not frozen)
    if verbose:
        tag = (f"ring={N} pack={args.pack} margin={args.margin_start} "
               f"jitter=±{args.jitter_us:g}us bias={args.bias_us:+g}us "
               f"{'open-loop' if args.no_feedback else f'fb{args.corr_hz:g}Hz'} "
               f"{'NAIVE' if args.naive_counter else 'monotonic'} "
               f"fpga={args.fpga_ppm:+d}ppm")
        print(f"=== {tag} ===")
        print(f"  final level {written-read} lines (written={written} read={read})"
              f"{'  [WRITER FROZEN]' if frozen else ''}")
        print(f"  UNDERRUNS={underruns}  OVERFLOWS={overflows}  -> {'PASS ✅' if ok else 'FAIL ✖'}")
    return ok, underruns, overflows, frozen


def selftest():
    """Scenario matrix: prove the model reproduces the bug AND validates the fix."""
    base = dict(height=240, refresh=60.0, frames=120, pack=2, margin_start=16,
                corr_hz=30.0, gain=0.001, deadband=2, grace_frames=3,
                fpga_ppm=50, jitter_us=5.0, bias_us=0.0,
                no_feedback=False, naive_counter=False, seed=1)
    def mk(**over):
        d = dict(base); d.update(over); return argparse.Namespace(**d)

    cases = [
        ("A. BUG: naive counter + ring 8 (the freeze)",       mk(nlines=8, naive_counter=True),  "FAIL"),
        ("B. FIX: monotonic + ring 32 + busy-spin(5us)",      mk(nlines=32),                     "PASS"),
        ("C. FIX holds even at ring 16",                      mk(nlines=16),                     "PASS"),
        ("D. OS-sleep jitter (2000us) breaks pacing",         mk(nlines=32, jitter_us=2000),     "FAIL"),
        ("E. OS-sleep BIAS (+1000us/emit) = systematic drift",mk(nlines=32, bias_us=1000),       "FAIL"),
        ("F. open-loop + 300ppm drift eventually laps",       mk(nlines=32, no_feedback=True, fpga_ppm=300, frames=600), "FAIL"),
        ("G. closed-loop absorbs the same 300ppm drift",      mk(nlines=32, fpga_ppm=300, frames=600), "PASS"),
    ]
    print("BEAM-RACE PoC self-test (each line: scenario -> result vs expected)\n")
    allgood = True
    for name, ns, expect in cases:
        ok, ur, ov, frozen = simulate(ns, verbose=False)
        got = "PASS" if ok else "FAIL"
        mark = "✅" if got == expect else "❌ UNEXPECTED"
        if got != expect: allgood = False
        why = " FROZEN" if frozen else ""
        print(f"  {name:52s} -> {got:4s} (expected {expect}) {mark}   [UR={ur} OV={ov}{why}]")
    print(f"\n  self-test {'OK - model behaves as designed ✅' if allgood else 'MISMATCH - model still wrong ✖'}")
    return allgood


def main():
    p = argparse.ArgumentParser(description="Beam-race pacing PoC (time-driven, no FPGA)")
    p.add_argument("--selftest", action="store_true", help="run the scenario matrix")
    p.add_argument("--nlines", type=int, default=32)
    p.add_argument("--height", type=int, default=240)
    p.add_argument("--refresh", type=float, default=60.0)
    p.add_argument("--frames", type=int, default=120)
    p.add_argument("--pack", type=int, default=2)
    p.add_argument("--margin-start", type=int, default=16)
    p.add_argument("--corr-hz", type=float, default=30.0, help="level-correction rate (PoC found 30Hz = zero incidents)")
    p.add_argument("--gain", type=float, default=0.001, help="feedback proportional gain (soft)")
    p.add_argument("--deadband", type=int, default=2, help="don't correct within +/- this many lines")
    p.add_argument("--grace-frames", type=int, default=3, help="ignore incidents during startup settling")
    p.add_argument("--fpga-ppm", type=int, default=50, help="pixel vs sender clock mismatch")
    p.add_argument("--jitter-us", type=float, default=5.0, help="per-emit random timer error (busy-spin~5, OS-sleep~2000)")
    p.add_argument("--bias-us", type=float, default=0.0, help="systematic sender-clock error per emit")
    p.add_argument("--no-feedback", action="store_true")
    p.add_argument("--naive-counter", action="store_true")
    p.add_argument("--seed", type=int, default=1)
    args = p.parse_args()
    if args.selftest:
        selftest()
    else:
        simulate(args)


if __name__ == "__main__":
    main()
