/* SPDX-License-Identifier: MIT
 * qoiline self-test: encode/decode round trip on many line kinds, both formats, plus
 * corruption checks. Built with -DQOI_REF_H="path/qoi.h" (the reference qoi.h from
 * qoiformat.org / phoboslab, MIT), it also checks that every QOI-coded RGB888 line is
 * byte-for-byte what standard QOI codes for the same 1-line image.
 *
 * With --vectors DIR it writes instead the stimulus of sim/tb/qoi_line_decoder_tb.v:
 *   DIR/in.hex     coded lines back to back, one byte per line of the file
 *   DIR/lines.hex  per coded line: bit 17 = corrupted (qoiline_decode refuses it),
 *                  bit 16 = RGB565, bits 15..0 = width; ends with FFFFFFFF
 *   DIR/px.hex     the decoded pixels of the good lines, as the decoder outputs them
 *                  ({r8,g8,b8} or {8'd0,r5,g6,b5})
 * Some lines are deliberately corrupted (flipped bytes, wrong lengths, raw length
 * mismatch, length 0) to check that the decoder flags exactly the lines the C model
 * refuses and keeps its line framing.
 *
 *   make qoiline_test qoi_line_decoder_tb      (top-level Makefile)
 */
#include "qoiline.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef QOI_REF_H
#define QOI_IMPLEMENTATION
#define QOI_NO_STDIO
#include QOI_REF_H
#endif

static unsigned rng = 12345;
static unsigned rnd(void) { rng = rng * 1103515245u + 12345u; return rng >> 16; }

static int fails = 0, lines = 0, raw_lines = 0, ref_checked = 0;

/* fill one line of `kind` in wire format */
static void make_line(uint8_t *s, int w, int fmt, int kind)
{
    int bpp = qoiline_bpp(fmt);
    for (int x = 0; x < w; x++) {
        int r, g, b;
        switch (kind) {
        case 0: r = g = b = 0; break;                                   /* black */
        case 1: r = 200; g = 30; b = 90; break;                         /* flat colour */
        case 2: r = g = b = (x * 255) / (w > 1 ? w - 1 : 1); break;     /* grey ramp */
        case 3: r = (x & 1) ? 255 : 10; g = (x & 1) ? 0 : 200; b = 77; break; /* dither */
        case 4: r = rnd() & 255; g = rnd() & 255; b = rnd() & 255; break;      /* noise */
        case 5: { int c = (x / 16) % 8; r = (c & 4) ? 255 : 0; g = (c & 2) ? 255 : 0;
                  b = (c & 1) ? 255 : 0; } break;                       /* colour bars */
        case 6: r = 128 + (int)(rnd() % 5) - 2; g = 64 + (int)(rnd() % 9) - 4;
                b = 32 + (int)(rnd() % 3) - 1; break;                   /* small noise */
        default: { static const int pal[5][3] = { {0,0,0}, {255,255,255}, {255,0,0},
                   {16,32,240}, {90,200,40} }; int c = rnd() % 5;
                   if (rnd() & 3) c = (x / 7) % 5;
                   r = pal[c][0]; g = pal[c][1]; b = pal[c][2]; } break; /* palette art */
        }
        uint8_t *d = s + (size_t)x * bpp;
        if (fmt == QOILINE_RGB888) { d[0] = (uint8_t)b; d[1] = (uint8_t)g; d[2] = (uint8_t)r; }
        else {
            unsigned v = ((unsigned)(r >> 3) << 11) | ((unsigned)(g >> 2) << 5) | (unsigned)(b >> 3);
            d[0] = (uint8_t)v; d[1] = (uint8_t)(v >> 8);
        }
    }
}

#ifdef QOI_REF_H
static void check_ref(const uint8_t *s, int w, const uint8_t *coded)
{
    unsigned hdr = coded[0] | (coded[1] << 8);
    if (hdr & QOILINE_HDR_RAW) return;
    uint8_t *rgb = malloc((size_t)w * 3);
    for (int x = 0; x < w; x++) {
        rgb[3 * x] = s[3 * x + 2]; rgb[3 * x + 1] = s[3 * x + 1]; rgb[3 * x + 2] = s[3 * x];
    }
    qoi_desc desc = { (unsigned)w, 1, 3, QOI_SRGB };
    int len = 0;
    uint8_t *q = qoi_encode(rgb, &desc, &len);
    size_t n = hdr & QOILINE_LEN_MASK;
    /* standard file = 14-byte header + data + 8-byte end marker */
    if (!q || (size_t)len != 14 + n + 8 || memcmp(q + 14, coded + 2, n)) {
        printf("FAIL: RGB888 line (w=%d) differs from reference qoi.h\n", w);
        fails++;
    }
    ref_checked++;
    free(q);
    free(rgb);
}
#endif

static void one(int w, int fmt, int kind)
{
    int bpp = qoiline_bpp(fmt);
    uint8_t *s = malloc((size_t)w * bpp), *c = malloc(qoiline_bound(w, fmt));
    uint8_t *o = malloc((size_t)w * bpp);
    make_line(s, w, fmt, kind);
    size_t n = qoiline_encode(s, w, fmt, c);
    long m = qoiline_decode(c, n, w, fmt, o);
    lines++;
    if (n < 3 || n > qoiline_bound(w, fmt) || m != (long)n || memcmp(s, o, (size_t)w * bpp)) {
        printf("FAIL: round trip fmt=%d w=%d kind=%d (n=%zu m=%ld)\n", fmt, w, kind, n, m);
        fails++;
    }
    if (c[1] & 0x80) raw_lines++;
    /* truncated input and a wrong width must be refused */
    if (n > 2 && qoiline_decode(c, n - 1, w, fmt, o) != -1) {
        printf("FAIL: truncated line accepted fmt=%d w=%d kind=%d\n", fmt, w, kind);
        fails++;
    }
    if (w > 1 && qoiline_decode(c, n, w - 1, fmt, o) != -1) {
        printf("FAIL: line accepted with a smaller width fmt=%d w=%d kind=%d\n", fmt, w, kind);
        fails++;
    }
#ifdef QOI_REF_H
    if (fmt == QOILINE_RGB888) check_ref(s, w, c);
#endif
    free(s); free(c); free(o);
}

static int write_vectors(const char *dir)
{
    char path[1024];
    snprintf(path, sizeof path, "%s/in.hex", dir);     FILE *fi = fopen(path, "w");
    snprintf(path, sizeof path, "%s/lines.hex", dir);  FILE *fl = fopen(path, "w");
    snprintf(path, sizeof path, "%s/px.hex", dir);     FILE *fp = fopen(path, "w");
    if (!fi || !fl || !fp) { perror(dir); return 1; }
    static const int fixed_w[] = { 1, 2, 62, 63, 64, 320, 512, 640 };
    int nlines = 0, nbad = 0;

    /* hand-made lines the encoder never produces but a decoder must take: an index to
     * the pixel just before (the encoder would code a run), right after it is written.
     * Pixel (r, g, b) = (10, 20, 30), hash 9, three times. */
    static const uint8_t hand888[] = { 6, 0, 0xFE, 10, 20, 30, 0x09, 0x09 };
    static const uint8_t hand565[] = { 5, 0, 0xFE, 0x9E, 0x52, 0x09, 0x09 };
    for (int k = 0; k < 2; k++) {
        const uint8_t *c = k ? hand565 : hand888;
        size_t len = k ? sizeof hand565 : sizeof hand888;
        int fmt = k ? QOILINE_RGB565 : QOILINE_RGB888;
        uint8_t o[9];
        if (qoiline_decode(c, len, 3, fmt, o) != (long)len) { printf("FAIL: hand line %d\n", k); return 1; }
        for (size_t i = 0; i < len; i++) fprintf(fi, "%02x\n", c[i]);
        fprintf(fl, "%08x\n", (k << 16) | 3);
        for (int x = 0; x < 3; x++) fprintf(fp, "%06x\n", k ? 0x529Eu : 0x0A141Eu);
        nlines++;
    }
    for (int n = 0; n < 1600; n++) {
        int fmt = (n & 1) ? QOILINE_RGB565 : QOILINE_RGB888;
        int w = n < 128 ? fixed_w[(n >> 1) % 8] : 1 + (int)(rnd() % 700);
        int bpp = qoiline_bpp(fmt);
        uint8_t *s = malloc((size_t)w * bpp), *c = malloc(qoiline_bound(w, fmt) + 64);
        uint8_t *o = malloc((size_t)w * bpp);
        make_line(s, w, fmt, (int)(rnd() % 8));
        size_t len = qoiline_encode(s, w, fmt, c);
        unsigned hdr = c[0] | (c[1] << 8);
        if (n >= 128) switch (rnd() % 16) {              /* corruptions, ~3/8 of the lines */
        case 0: case 1: if (len > 2) c[2 + rnd() % (len - 2)] ^= (uint8_t)(1u << (rnd() % 8)); break;
        case 2: if ((hdr & QOILINE_LEN_MASK) > 1) { hdr--; len--; } break;      /* one short */
        case 3: hdr++; c[len++] = (uint8_t)rnd(); break;                        /* one extra */
        case 4: hdr ^= QOILINE_HDR_RAW; break;                                  /* raw flag */
        case 5: if (rnd() % 4 == 0) { hdr = 0; len = 2; } break;                /* length 0 */
        default: break;
        }
        c[0] = (uint8_t)hdr; c[1] = (uint8_t)(hdr >> 8);
        long m = qoiline_decode(c, len, w, fmt, o);
        int bad = m < 0;
        if (!bad && m != (long)len) { printf("FAIL: vector line %d length\n", n); return 1; }
        for (size_t i = 0; i < len; i++) fprintf(fi, "%02x\n", c[i]);
        fprintf(fl, "%08x\n", (bad << 17) | ((fmt == QOILINE_RGB565) << 16) | w);
        if (!bad)
            for (int x = 0; x < w; x++) {
                const uint8_t *q = o + (size_t)x * bpp;
                unsigned v = fmt == QOILINE_RGB565 ? (unsigned)(q[0] | (q[1] << 8))
                                                   : (unsigned)((q[2] << 16) | (q[1] << 8) | q[0]);
                fprintf(fp, "%06x\n", v);
            }
        nlines++; nbad += bad;
        free(s); free(c); free(o);
    }
    fprintf(fl, "ffffffff\n");
    fclose(fi); fclose(fl); fclose(fp);
    printf("qoiline_test: %d vector lines (%d corrupted) in %s\n", nlines, nbad, dir);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 3 && !strcmp(argv[1], "--vectors")) return write_vectors(argv[2]);

    static const int widths[] = { 1, 2, 3, 61, 62, 63, 64, 124, 256, 320, 512, 640, 1024 };
    const int fmts[] = { QOILINE_RGB888, QOILINE_RGB565 };
    for (unsigned f = 0; f < 2; f++)
        for (unsigned i = 0; i < sizeof widths / sizeof widths[0]; i++)
            for (int k = 0; k < 8; k++)
                for (int rep = 0; rep < 20; rep++)
                    one(widths[i], fmts[f], k);

    /* reserved op 0xFF and an empty header are refused */
    uint8_t bad[4] = { 2, 0, 0xFF, 0 }, out[8];
    if (qoiline_decode(bad, 4, 1, QOILINE_RGB565, out) != -1) { printf("FAIL: 0xFF accepted\n"); fails++; }
    uint8_t empty[2] = { 0, 0 };
    if (qoiline_decode(empty, 2, 1, QOILINE_RGB565, out) != -1) { printf("FAIL: empty accepted\n"); fails++; }

    printf("qoiline_test: %d lines (%d raw), %d checked against reference qoi.h: %s\n",
           lines, raw_lines, ref_checked, fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
