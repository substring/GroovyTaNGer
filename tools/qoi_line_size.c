// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - per-line QOI size measurement, written from the QOI specification
// (qoiformat.org). Reads raw RGB24 frames (W x H) on stdin, encodes every line of every frame as its own QOI stream (state reset per line, as the FPGA would), prints
// one line per source line: frame, line, bytes. No QOI header/end marker counted.
// Build: gcc -O2 -o qoi_line_size tools/qoi_line_size.c
// Use:   ffmpeg -i in.mp4 -an -f rawvideo -pix_fmt rgb24 - | ./qoi_line_size 640 480 > lines.txt
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int qoi_line(const unsigned char *p, int w) {
    unsigned char idx[64][4]; memset(idx, 0, sizeof idx);
    int pr = 0, pg = 0, pb = 0, run = 0, n = 0;
    for (int x = 0; x < w; x++) {
        int r = p[3*x], g = p[3*x+1], b = p[3*x+2], a = 255;
        if (r == pr && g == pg && b == pb) { run++; if (run == 62 || x == w-1) { n++; run = 0; } continue; }
        if (run) { n++; run = 0; }
        int h = (r*3 + g*5 + b*7 + a*11) % 64;
        if (idx[h][0] == r && idx[h][1] == g && idx[h][2] == b && idx[h][3] == a) n += 1;
        else {
            idx[h][0] = r; idx[h][1] = g; idx[h][2] = b; idx[h][3] = a;
            signed char vr = r - pr, vg = g - pg, vb = b - pb;
            signed char vgr = vr - vg, vgb = vb - vg;
            if (vr > -3 && vr < 2 && vg > -3 && vg < 2 && vb > -3 && vb < 2) n += 1;
            else if (vgr > -9 && vgr < 8 && vg > -33 && vg < 32 && vgb > -9 && vgb < 8) n += 2;
            else n += 4;
        }
        pr = r; pg = g; pb = b;
    }
    return n;
}
int main(int argc, char **argv) {
    int w = atoi(argv[1]), h = atoi(argv[2]);
    unsigned char *f = malloc((size_t)w*h*3);
    for (int fr = 0; fread(f, 1, (size_t)w*h*3, stdin) == (size_t)w*h*3; fr++)
        for (int y = 0; y < h; y++) printf("%d %d %d\n", fr, y, qoi_line(f + (size_t)y*w*3, w));
    return 0;
}
