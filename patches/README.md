# GroovyMAME patches

Client patches for GroovyMAME's nogpu renderer (`-video mister`), one file per feature so
each can be discussed and merged on its own. Base: substring/GroovyMAME 4ce01b9
(libretro-driver). Apply in the order of the table, each with `git apply -p1 <file>`.

## OS compatibility

| Patch | Option | Linux | Windows | macOS | Depends on |
|---|---|---|---|---|---|
| `groovymame-mister-rgb565.patch` | `-mister_rgb_mode rgb565` | yes | yes | yes | - |
| `groovymame-mister-pacing.patch` | `-mister_pacing <F>` | yes (fq qdisc) | no: option ignored, message | no: option ignored, message | rgb565 |
| `groovymame-mister-qoi.patch` | `-mister_compression qoi` | yes | yes | yes | rgb565 |
| `groovymame-mister-linepacing.patch` | `-mister_linepacing 1` | yes (fq qdisc, `SO_TXTIME`) | no: option ignored, message | no: option ignored, message | rgb565, pacing, qoi |

"yes" for Windows and macOS means portable code (no OS call added), not tested: only
the libretro driver on Linux was compiled. Where a patch is "no", GroovyMAME runs as
without it (frames sent in one burst), it does not fail.

Linux pacing (both pacing patches) needs the fq qdisc on the interface that sends to
the receiver, with a flow limit above one frame of datagrams. fq_codel, the default,
accepts the settings and silently ignores them:

    tc qdisc replace dev <if> root fq flow_limit 1000

Not persistent across a reboot or a link reset (see `docs/groovymame_client.md`).

## Which pacing

- raw (`-mister_compression none`): `-mister_pacing 1.0` or `-mister_linepacing 1`
- qoi: `-mister_linepacing 1` only. `-mister_pacing` paces bytes, and QOI lines have
  very different sizes: the flat lines arrive far too early (HW 2026-11-06).
- lz4 / lz4hc: no line boundaries, neither pacing applies per line (and Groovy_TaNGer
  does not decode lz4).

Without any pacing (Windows, macOS, or Linux without fq), a beam-racing receiver with
a small ring is outrun in 320-px modes: black band in the middle of the picture.

## Status

| Patch | Compiled (libretro driver, Linux) | Run on hardware |
|---|---|---|
| rgb565 | yes | yes (Groovy_TaNGer) |
| pacing | yes | yes, 320x224 perfect (2026-11-01) |
| qoi | yes | yes, with `-mister_pacing`: only 32 lines shown, decoder FIFO overflows; needs line pacing (2026-11-06) |
| linepacing | syntax only | no |
