// ndi-sender — feeds one NDI source from raw frames on FIFOs.
//
// ffmpeg decodes a stream from MediaMTX and writes raw video (UYVY422) and raw
// audio (s16le) to two FIFOs; this pushes them to the network as NDI. Video and
// audio run on their own threads. Clocking is left off: the source is already
// live, so frames are sent as they arrive instead of being rate-limited twice.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include "Processing.NDI.Lib.h"

static NDIlib_send_instance_t g_send = NULL;
static volatile sig_atomic_t g_stop = 0;

static void on_signal(int s) { (void)s; g_stop = 1; }

// Reads exactly n bytes; 0 on EOF/error.
static int read_full(int fd, void *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, (char *)buf + got, n - got);
        if (r <= 0) return 0;
        got += (size_t)r;
    }
    return 1;
}

typedef struct { const char *path; int w, h, fn, fd; } video_cfg;
typedef struct { const char *path; int rate, ch, samples; } audio_cfg;

static void *video_thread(void *arg) {
    video_cfg *c = (video_cfg *)arg;
    int fd = open(c->path, O_RDONLY);
    if (fd < 0) { fprintf(stderr, "ndi-sender: cannot open video fifo %s\n", c->path); g_stop = 1; return NULL; }

    size_t frame_bytes = (size_t)c->w * (size_t)c->h * 2;   // UYVY422 = 2 bytes/pixel
    uint8_t *buf = (uint8_t *)malloc(frame_bytes);
    if (!buf) { g_stop = 1; close(fd); return NULL; }

    NDIlib_video_frame_v2_t f;
    memset(&f, 0, sizeof(f));
    f.xres = c->w;
    f.yres = c->h;
    f.FourCC = NDIlib_FourCC_video_type_UYVY;
    f.frame_rate_N = c->fn;
    f.frame_rate_D = c->fd;
    f.picture_aspect_ratio = (float)c->w / (float)c->h;
    f.frame_format_type = NDIlib_frame_format_type_progressive;
    f.timecode = NDIlib_send_timecode_synthesize;
    f.line_stride_in_bytes = c->w * 2;

    long n = 0;
    while (!g_stop && read_full(fd, buf, frame_bytes)) {
        f.p_data = buf;                       // send_video_v2 is synchronous: safe to reuse
        NDIlib_send_send_video_v2(g_send, &f);
        if (++n == 1) fprintf(stderr, "ndi-sender: first video frame sent (%dx%d)\n", c->w, c->h);
    }
    free(buf);
    close(fd);
    g_stop = 1;
    fprintf(stderr, "ndi-sender: video ended after %ld frames\n", n);
    return NULL;
}

static void *audio_thread(void *arg) {
    audio_cfg *c = (audio_cfg *)arg;
    int fd = open(c->path, O_RDONLY);
    if (fd < 0) { fprintf(stderr, "ndi-sender: cannot open audio fifo %s\n", c->path); return NULL; }

    size_t block = (size_t)c->samples * (size_t)c->ch * sizeof(int16_t);
    int16_t *raw = (int16_t *)malloc(block);
    float *planar = (float *)malloc((size_t)c->samples * (size_t)c->ch * sizeof(float));
    if (!raw || !planar) { free(raw); free(planar); close(fd); return NULL; }

    NDIlib_audio_frame_interleaved_16s_t src;
    memset(&src, 0, sizeof(src));
    src.sample_rate = c->rate;
    src.no_channels = c->ch;
    src.no_samples  = c->samples;
    src.timecode    = NDIlib_send_timecode_synthesize;
    src.reference_level = 0;
    src.p_data = raw;

    NDIlib_audio_frame_v2_t dst;
    memset(&dst, 0, sizeof(dst));
    dst.sample_rate = c->rate;
    dst.no_channels = c->ch;
    dst.no_samples  = c->samples;
    dst.timecode    = NDIlib_send_timecode_synthesize;
    dst.p_data = planar;
    dst.channel_stride_in_bytes = c->samples * (int)sizeof(float);

    while (!g_stop && read_full(fd, raw, block)) {
        NDIlib_util_audio_from_interleaved_16s_v2(&src, &dst);
        NDIlib_send_send_audio_v2(g_send, &dst);
    }
    free(raw);
    free(planar);
    close(fd);
    return NULL;
}

int main(int argc, char **argv) {
    const char *name = "Turbo Receiver";
    video_cfg v = { NULL, 1920, 1080, 25, 1 };
    audio_cfg a = { NULL, 48000, 2, 1024 };

    for (int i = 1; i < argc - 1; i++) {
        if      (!strcmp(argv[i], "--name"))     name = argv[++i];
        else if (!strcmp(argv[i], "--video"))    v.path = argv[++i];
        else if (!strcmp(argv[i], "--audio"))    a.path = argv[++i];
        else if (!strcmp(argv[i], "--width"))    v.w = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--height"))   v.h = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fps-num"))  v.fn = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fps-den"))  v.fd = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rate"))     a.rate = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--channels")) a.ch = atoi(argv[++i]);
    }
    if (!v.path) { fprintf(stderr, "usage: ndi-sender --name N --video FIFO [--audio FIFO] --width W --height H\n"); return 2; }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    if (!NDIlib_initialize()) { fprintf(stderr, "ndi-sender: NDIlib_initialize failed\n"); return 1; }

    NDIlib_send_create_t cs;
    memset(&cs, 0, sizeof(cs));
    cs.p_ndi_name = name;
    cs.p_groups = NULL;
    cs.clock_video = false;   // source is already live; don't rate-limit twice
    cs.clock_audio = false;

    g_send = NDIlib_send_create(&cs);
    if (!g_send) { fprintf(stderr, "ndi-sender: NDIlib_send_create failed\n"); NDIlib_destroy(); return 1; }
    fprintf(stderr, "ndi-sender: NDI source \"%s\" is live\n", name);

    pthread_t vt, at;
    pthread_create(&vt, NULL, video_thread, &v);
    if (a.path) pthread_create(&at, NULL, audio_thread, &a);

    pthread_join(vt, NULL);
    if (a.path) pthread_join(at, NULL);

    NDIlib_send_destroy(g_send);
    NDIlib_destroy();
    return 0;
}
