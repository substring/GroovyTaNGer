/* SPDX-License-Identifier: MIT
 * qoiline - QOI coding of single video lines, for line-by-line (beam-racing) receivers.
 * Reference implementation of docs/qoi_line_format.md, plain C99, no dependency.
 *
 * One call codes ONE line: the QOI state (previous pixel, 64-entry cache) restarts at
 * every line, and the result is a 2-byte header + payload (QOI-coded, or the raw line
 * when coding would not make it shorter). Pixels are in the Groovy_MiSTer wire format
 * selected by CMD_INIT rgbMode:
 *   QOILINE_RGB888 (0): 3 bytes per pixel, byte order B, G, R
 *   QOILINE_RGB565 (2): 2 bytes per pixel, 16-bit little-endian, R in bits 15..11
 * RGB888 lines are coded exactly as standard QOI codes the same RGB pixels.
 *
 * Used by the GroovyMAME encoder patch, by the measurement tool and as the golden model
 * of the Verilog decoder (rtl/generic/compression/qoi_line_decoder.v).
 *
 * Single header, as qoi.h: in ONE C or C++ file,
 *   #define QOILINE_IMPLEMENTATION
 *   #include "qoiline.h"
 * (qoiline.c does just that for the tools here). The GroovyMAME patch carries a copy of
 * this file: change both together.
 *
 * MIT rather than the project's GPL so the encoder can go into any sender.
 */
#ifndef QOILINE_H
#define QOILINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define QOILINE_RGB888 0
#define QOILINE_RGB565 2

#define QOILINE_HDR_RAW   0x8000u   /* header bit 15: payload is the raw line */
#define QOILINE_LEN_MASK  0x7FFFu   /* header bits 14..0: payload bytes */

/* bytes per pixel of a format (0 = unsupported format) */
int qoiline_bpp(int fmt);

/* largest coded line: header + raw line */
size_t qoiline_bound(int width, int fmt);

/* Code one line of `width` wire-format pixels into dst (at least qoiline_bound bytes).
 * Returns the bytes written (header included), 0 on bad arguments. */
size_t qoiline_encode(const uint8_t *src, int width, int fmt, uint8_t *dst);

/* Decode one line from src (avail bytes) into width wire-format pixels at dst.
 * Returns the bytes consumed (header included), or -1 if the line is corrupted
 * (truncated, wrong pixel count, reserved op). Like the hardware decoder, dst is
 * fully written only on success. */
long qoiline_decode(const uint8_t *src, size_t avail, int width, int fmt, uint8_t *dst);

#ifdef __cplusplus
}
#endif

#endif /* QOILINE_H */

#ifdef QOILINE_IMPLEMENTATION
#ifndef QOILINE_IMPLEMENTED
#define QOILINE_IMPLEMENTED

#include <string.h>

#define QOIL_OP_INDEX 0x00
#define QOIL_OP_DIFF  0x40
#define QOIL_OP_LUMA  0x80
#define QOIL_OP_RUN   0xC0
#define QOIL_OP_RGB   0xFE
#define QOIL_OP_RGBA  0xFF   /* reserved: never sent, a decoder rejects it */
#define QOIL_MASK_2   0xC0

/* green difference in red/blue units for RGB565 (green has one more bit): vg >> 1.
 * Chosen by measurement 2026-11-06 (docs/qoi_line_format.md). Must match the Verilog
 * decoder. Overridable only to repeat that measurement. */
#ifndef QOILINE_565_VG_SHIFT
#define QOILINE_565_VG_SHIFT 1
#endif

typedef struct { int r, g, b; } qoil_px;

typedef struct {
    int wr, wg, wb;     /* channel widths */
    int vg_shift;       /* vg' = vg >> vg_shift */
    int bpp;
} qoil_fmt;

static int qoil_get_fmt(int fmt, qoil_fmt *f)
{
    if (fmt == QOILINE_RGB888) {
        f->wr = 8; f->wg = 8; f->wb = 8; f->vg_shift = 0; f->bpp = 3;
    } else if (fmt == QOILINE_RGB565) {
        f->wr = 5; f->wg = 6; f->wb = 5; f->vg_shift = QOILINE_565_VG_SHIFT; f->bpp = 2;
    } else
        return 0;
    return 1;
}

int qoiline_bpp(int fmt)
{
    qoil_fmt f;
    return qoil_get_fmt(fmt, &f) ? f.bpp : 0;
}

size_t qoiline_bound(int width, int fmt)
{
    return 2 + (size_t)width * (size_t)qoiline_bpp(fmt);
}

static qoil_px qoil_unpack(const uint8_t *s, const qoil_fmt *f)
{
    qoil_px p;
    if (f->bpp == 3) {
        p.b = s[0]; p.g = s[1]; p.r = s[2];
    } else {
        unsigned v = s[0] | (s[1] << 8);
        p.r = v >> 11; p.g = (v >> 5) & 63; p.b = v & 31;
    }
    return p;
}

static void qoil_pack(qoil_px p, uint8_t *d, const qoil_fmt *f)
{
    if (f->bpp == 3) {
        d[0] = (uint8_t)p.b; d[1] = (uint8_t)p.g; d[2] = (uint8_t)p.r;
    } else {
        unsigned v = ((unsigned)p.r << 11) | ((unsigned)p.g << 5) | (unsigned)p.b;
        d[0] = (uint8_t)v; d[1] = (uint8_t)(v >> 8);
    }
}

/* x read as a signed w-bit value (x taken modulo 2^w) */
static int qoil_sw(int x, int w)
{
    int h = 1 << (w - 1);
    return ((x + h) & ((1 << w) - 1)) - h;
}

static int qoil_hash(qoil_px p)
{
    return (p.r * 3 + p.g * 5 + p.b * 7 + 255 * 11) % 64;
}

/* the pixel of QOI_OP_RGB: r, g, b for RGB888 (as standard QOI, NOT the B, G, R wire
 * order), the 16-bit little-endian word for RGB565 */
static void qoil_put_rgb(qoil_px p, uint8_t *d, const qoil_fmt *f)
{
    if (f->bpp == 3) { d[0] = (uint8_t)p.r; d[1] = (uint8_t)p.g; d[2] = (uint8_t)p.b; }
    else qoil_pack(p, d, f);
}

static qoil_px qoil_get_rgb(const uint8_t *s, const qoil_fmt *f)
{
    qoil_px p;
    if (f->bpp == 3) { p.r = s[0]; p.g = s[1]; p.b = s[2]; }
    else p = qoil_unpack(s, f);
    return p;
}

static int qoil_same(qoil_px a, qoil_px b)
{
    return a.r == b.r && a.g == b.g && a.b == b.b;
}

/* QOI payload of one line into d, at most `limit` bytes. Returns its length, or 0 when
 * it would reach `limit` (the caller then sends the line raw). */
static size_t qoil_encode_payload(const uint8_t *src, int width, const qoil_fmt *f, uint8_t *d, size_t limit)
{
    qoil_px cache[64];
    uint8_t valid[64];
    qoil_px prev = { 0, 0, 0 };
    size_t n = 0;
    int run = 0;

    memset(valid, 0, sizeof valid);
    for (int x = 0; x < width; x++) {
        qoil_px p = qoil_unpack(src + (size_t)x * f->bpp, f);

        if (qoil_same(p, prev)) {
            run++;
            if (run == 62 || x == width - 1) {
                if (n + 1 >= limit) return 0;
                d[n++] = (uint8_t)(QOIL_OP_RUN | (run - 1));
                run = 0;
            }
            continue;
        }
        if (run) {
            if (n + 1 >= limit) return 0;
            d[n++] = (uint8_t)(QOIL_OP_RUN | (run - 1));
            run = 0;
        }

        int h = qoil_hash(p);
        if (valid[h] && qoil_same(cache[h], p)) {
            if (n + 1 >= limit) return 0;
            d[n++] = (uint8_t)(QOIL_OP_INDEX | h);
        } else {
            cache[h] = p; valid[h] = 1;
            int vr = qoil_sw(p.r - prev.r, f->wr);
            int vg = qoil_sw(p.g - prev.g, f->wg);
            int vb = qoil_sw(p.b - prev.b, f->wb);
            int vgp = vg >> f->vg_shift;             /* arithmetic shift */
            int dr = qoil_sw(vr - vgp, f->wr);
            int db = qoil_sw(vb - vgp, f->wb);

            if (vr >= -2 && vr <= 1 && vg >= -2 && vg <= 1 && vb >= -2 && vb <= 1) {
                if (n + 1 >= limit) return 0;
                d[n++] = (uint8_t)(QOIL_OP_DIFF | ((vr + 2) << 4) | ((vg + 2) << 2) | (vb + 2));
            } else if (vg >= -32 && vg <= 31 && dr >= -8 && dr <= 7 && db >= -8 && db <= 7) {
                if (n + 2 >= limit) return 0;
                d[n++] = (uint8_t)(QOIL_OP_LUMA | (vg + 32));
                d[n++] = (uint8_t)(((dr + 8) << 4) | (db + 8));
            } else {
                if (n + 1 + (size_t)f->bpp >= limit) return 0;
                d[n++] = QOIL_OP_RGB;
                qoil_put_rgb(p, d + n, f);
                n += f->bpp;
            }
        }
        prev = p;
    }
    return n;
}

size_t qoiline_encode(const uint8_t *src, int width, int fmt, uint8_t *dst)
{
    qoil_fmt f;
    if (!qoil_get_fmt(fmt, &f) || width <= 0) return 0;
    size_t raw = (size_t)width * f.bpp;
    if (raw > QOILINE_LEN_MASK) return 0;

    /* QOI only when strictly shorter than the raw line */
    size_t n = qoil_encode_payload(src, width, &f, dst + 2, raw);
    unsigned hdr;
    if (n) {
        hdr = (unsigned)n;
    } else {
        memcpy(dst + 2, src, raw);
        n = raw;
        hdr = QOILINE_HDR_RAW | (unsigned)raw;
    }
    dst[0] = (uint8_t)hdr;
    dst[1] = (uint8_t)(hdr >> 8);
    return n + 2;
}

long qoiline_decode(const uint8_t *src, size_t avail, int width, int fmt, uint8_t *dst)
{
    qoil_fmt f;
    if (!qoil_get_fmt(fmt, &f) || width <= 0 || avail < 2) return -1;
    unsigned hdr = src[0] | (src[1] << 8);
    size_t len = hdr & QOILINE_LEN_MASK;
    size_t raw = (size_t)width * f.bpp;
    if (len == 0 || len + 2 > avail) return -1;
    const uint8_t *s = src + 2;

    if (hdr & QOILINE_HDR_RAW) {
        if (len != raw) return -1;
        memcpy(dst, s, raw);
        return (long)(len + 2);
    }

    /* the decoder writes the cache for every pixel it outputs (QOI rule); an index to an
     * entry not written in this line cannot come from the encoder: corrupted line */
    qoil_px cache[64];
    uint8_t valid[64];
    qoil_px p = { 0, 0, 0 };
    size_t i = 0;
    int x = 0;
    memset(valid, 0, sizeof valid);

    while (x < width) {
        if (i >= len) return -1;
        int b1 = s[i++];
        int run = 1;
        if (b1 == QOIL_OP_RGB) {
            if (i + f.bpp > len) return -1;
            p = qoil_get_rgb(s + i, &f);
            i += f.bpp;
        } else if (b1 == QOIL_OP_RGBA) {
            return -1;
        } else if ((b1 & QOIL_MASK_2) == QOIL_OP_INDEX) {
            if (!valid[b1 & 63]) return -1;
            p = cache[b1 & 63];
        } else if ((b1 & QOIL_MASK_2) == QOIL_OP_DIFF) {
            p.r = (p.r + ((b1 >> 4) & 3) - 2) & ((1 << f.wr) - 1);
            p.g = (p.g + ((b1 >> 2) & 3) - 2) & ((1 << f.wg) - 1);
            p.b = (p.b + (b1 & 3) - 2) & ((1 << f.wb) - 1);
        } else if ((b1 & QOIL_MASK_2) == QOIL_OP_LUMA) {
            if (i >= len) return -1;
            int b2 = s[i++];
            int vg = (b1 & 63) - 32;
            int vgp = vg >> f.vg_shift;
            p.r = (p.r + vgp + ((b2 >> 4) & 15) - 8) & ((1 << f.wr) - 1);
            p.g = (p.g + vg) & ((1 << f.wg) - 1);
            p.b = (p.b + vgp + (b2 & 15) - 8) & ((1 << f.wb) - 1);
        } else {
            run = (b1 & 63) + 1;
        }
        if (x + run > width) return -1;
        cache[qoil_hash(p)] = p;
        valid[qoil_hash(p)] = 1;
        for (int k = 0; k < run; k++, x++)
            qoil_pack(p, dst + (size_t)x * f.bpp, &f);
    }
    if (i != len) return -1;       /* bytes left over: not the line we were sent */
    return (long)(len + 2);
}

#endif /* QOILINE_IMPLEMENTED */
#endif /* QOILINE_IMPLEMENTATION */
