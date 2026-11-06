/* SPDX-License-Identifier: MIT
 * qoiline_size: per-line coded size with qoiline (header included), for RGB888 or RGB565.
 * Reads raw RGB24 frames (W x H) on stdin; for RGB565 every pixel is first truncated to
 * 5:6:5 as the GroovyMAME rgb565 patch does. Prints "frame line bytes" per line.
 *
 *   ffmpeg -i in.mp4 -an -f rawvideo -pix_fmt rgb24 - | ./qoiline_size 320 224 565 > lines.txt
 */
#include "qoiline.h"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s width height 888|565 < rgb24 frames\n", argv[0]);
        return 2;
    }
    int w = atoi(argv[1]), h = atoi(argv[2]);
    int fmt = atoi(argv[3]) == 565 ? QOILINE_RGB565 : QOILINE_RGB888;
    int bpp = qoiline_bpp(fmt);
    unsigned char *f = malloc((size_t)w * h * 3);
    uint8_t *line = malloc((size_t)w * bpp), *coded = malloc(qoiline_bound(w, fmt));
    if (w <= 0 || h <= 0 || !f || !line || !coded) return 2;

    for (int fr = 0; fread(f, 1, (size_t)w * h * 3, stdin) == (size_t)w * h * 3; fr++)
        for (int y = 0; y < h; y++) {
            const unsigned char *p = f + (size_t)y * w * 3;
            for (int x = 0; x < w; x++, p += 3) {
                if (fmt == QOILINE_RGB888) {
                    line[3 * x] = p[2]; line[3 * x + 1] = p[1]; line[3 * x + 2] = p[0];
                } else {
                    unsigned v = ((p[0] & 0xF8u) << 8) | ((p[1] & 0xFCu) << 3) | (p[2] >> 3);
                    line[2 * x] = (uint8_t)v; line[2 * x + 1] = (uint8_t)(v >> 8);
                }
            }
            printf("%d %d %zu\n", fr, y, qoiline_encode(line, w, fmt, coded));
        }
    return 0;
}
