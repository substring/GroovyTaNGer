// SPDX-License-Identifier: GPL-2.0-or-later
// Groovy_Tang - minimal GroovyMister test client.
//
// Talks the Groovy_MiSTer UDP protocol DIRECTLY (no libgroovymister dependency),
// per docs/protocol_verified.md. Works against any GroovyMister receiver: a real
// MiSTer today, Groovy_Tang once its Ethernet/blit path exists.
//
// What it does:
//   1. CMD_INIT   (raw RGB888, no audio)        -> reads the 13-byte ACK
//   2. CMD_SWITCHRES to a 15 kHz 240p modeline   (no ACK, per protocol)
//   3. streams a color-bar test image every frame via CMD_BLIT_FIELD_VSYNC
//      (raw, vSync=0 = auto frame delay) until Ctrl+C
//   4. CMD_CLOSE on exit
//
// Build:  cc -O2 -Wall -o gm_test_app gm_test_app.c
// Run:    ./gm_test_app <device-ip> [port]      (port defaults to 32100)
//
// NOTE: assumes a little-endian host (x86/ARM LE) — the protocol is LE and we
// memcpy native integers, exactly like the official client.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>

#define CMD_CLOSE            1
#define CMD_INIT             2
#define CMD_SWITCHRES        3
#define CMD_GET_STATUS       5
#define CMD_BLIT_FIELD_VSYNC 7

#define DATA_PORT 32100
#define MTU_PAYLOAD 1472          // 1500 - 20(IP) - 8(UDP)

// ---- 15 kHz 240p modeline (hfreq = 6.7MHz/426 = 15.73 kHz, vfreq = 60.0 Hz) ----
static const double   PCLK    = 6.700;   // MHz
static const uint16_t H_ACT   = 320, H_BEG = 336, H_END = 364, H_TOT = 426;
static const uint16_t V_ACT   = 240, V_BEG = 244, V_END = 247, V_TOT = 262;
static const uint8_t  INTERLACE = 0;     // progressive 240p

static volatile sig_atomic_t g_quit = 0;
static void on_sigint(int s) { (void)s; g_quit = 1; }

static int g_sock;
static struct sockaddr_in g_dst;

static int send_raw(const void *buf, size_t len) {
    return sendto(g_sock, buf, len, 0, (struct sockaddr *)&g_dst, sizeof(g_dst));
}

// Try to read a 13-byte ACK (short timeout). Returns 1 if an ACK was decoded.
static int read_ack(const char *tag) {
    unsigned char r[64];
    struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };
    setsockopt(g_sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    ssize_t n = recv(g_sock, r, sizeof(r), 0);
    if (n == 13) {
        uint32_t frameEcho, frame; uint16_t vCountEcho, vCount; uint8_t st;
        memcpy(&frameEcho, r + 0, 4);
        memcpy(&vCountEcho, r + 4, 2);
        memcpy(&frame, r + 6, 4);
        memcpy(&vCount, r + 10, 2);
        st = r[12];
        printf("[%s] ACK frameEcho=%u vCountEcho=%u | fpga frame=%u vCount=%u | "
               "status=0x%02x (ready=%d synced=%d vblank=%d f1=%d)\n",
               tag, frameEcho, vCountEcho, frame, vCount, st,
               st & 1, (st >> 2) & 1, (st >> 4) & 1, (st >> 5) & 1);
        return 1;
    }
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
        printf("[%s] no ACK (timeout)\n", tag);
    else if (n >= 0)
        printf("[%s] reply %zd bytes (unexpected)\n", tag, n);
    return 0;
}

static void cmd_init(void) {
    unsigned char p[5] = { CMD_INIT, 0 /*raw*/, 0 /*no audio*/, 0 /*chan*/, 0 /*RGB888*/ };
    send_raw(p, sizeof(p));
    read_ack("INIT");
}

static void cmd_switchres(void) {
    unsigned char p[26];
    p[0] = CMD_SWITCHRES;
    memcpy(&p[1],  &PCLK,  8);
    memcpy(&p[9],  &H_ACT, 2); memcpy(&p[11], &H_BEG, 2);
    memcpy(&p[13], &H_END, 2); memcpy(&p[15], &H_TOT, 2);
    memcpy(&p[17], &V_ACT, 2); memcpy(&p[19], &V_BEG, 2);
    memcpy(&p[21], &V_END, 2); memcpy(&p[23], &V_TOT, 2);
    p[25] = INTERLACE;
    send_raw(p, sizeof(p));
    printf("[SWITCHRES] %.3f MHz  %ux%u  hfreq=%.2f kHz  vfreq=%.2f Hz (no ACK expected)\n",
           PCLK, H_ACT, V_ACT, (PCLK * 1000.0) / H_TOT,
           (PCLK * 1e6) / ((double)H_TOT * V_TOT));
}

// Build SMPTE-style 8-bar color bars (RGB888) with a white overscan border.
static void make_color_bars(unsigned char *img) {
    static const unsigned char bar[8][3] = {
        {255,255,255}, {255,255,0}, {0,255,255}, {0,255,0},
        {255,0,255},   {255,0,0},   {0,0,255},   {0,0,0},
    };
    for (int y = 0; y < V_ACT; y++) {
        for (int x = 0; x < H_ACT; x++) {
            unsigned char r, g, b;
            int b8 = x / (H_ACT / 8);
            if (b8 > 7) b8 = 7;
            r = bar[b8][0]; g = bar[b8][1]; b = bar[b8][2];
            if (x < 2 || x >= H_ACT - 2 || y < 2 || y >= V_ACT - 2)  // border
                r = g = b = 255;
            size_t i = ((size_t)y * H_ACT + x) * 3;
            img[i] = r; img[i + 1] = g; img[i + 2] = b;
        }
    }
}

static void cmd_blit(uint32_t frame, const unsigned char *img, size_t bytes) {
    unsigned char hdr[8];
    uint8_t field = 0; uint16_t vsync = 0;     // progressive, auto frame delay
    hdr[0] = CMD_BLIT_FIELD_VSYNC;
    memcpy(&hdr[1], &frame, 4);
    hdr[5] = field;
    memcpy(&hdr[6], &vsync, 2);
    send_raw(hdr, sizeof(hdr));
    // header-less pixel stream, MTU-sized chunks
    size_t off = 0;
    while (off < bytes) {
        size_t n = bytes - off;
        if (n > MTU_PAYLOAD) n = MTU_PAYLOAD;
        if (send_raw(img + off, n) < 0) { perror("sendto pixels"); break; }
        off += n;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <device-ip> [port]\n", argv[0]);
        return 1;
    }
    const char *host = argv[1];
    int port = (argc > 2) ? atoi(argv[2]) : DATA_PORT;

    g_sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (g_sock < 0) { perror("socket"); return 1; }
    memset(&g_dst, 0, sizeof(g_dst));
    g_dst.sin_family = AF_INET;
    g_dst.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &g_dst.sin_addr) != 1) {
        fprintf(stderr, "bad IP: %s\n", host); return 1;
    }
    signal(SIGINT, on_sigint);

    size_t bytes = (size_t)H_ACT * V_ACT * 3;      // RGB888
    unsigned char *img = malloc(bytes);
    if (!img) { perror("malloc"); return 1; }
    make_color_bars(img);

    printf("Target %s:%d — color bars %ux%u RGB888 (%zu bytes/frame). Ctrl+C to quit.\n",
           host, port, H_ACT, V_ACT, bytes);

    cmd_init();
    cmd_switchres();
    usleep(50000);                                  // let the mode settle

    uint32_t frame = 0;
    while (!g_quit) {
        cmd_blit(++frame, img, bytes);
        if ((frame % 60) == 1) read_ack("BLIT");    // poll status ~once/sec
        usleep(16667);                              // ~60 fps
    }

    unsigned char close_cmd = CMD_CLOSE;
    send_raw(&close_cmd, 1);
    printf("\nsent CMD_CLOSE after %u frames. bye.\n", frame);
    free(img);
    close(g_sock);
    return 0;
}
