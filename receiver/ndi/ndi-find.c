// ndi-find — lists NDI sources visible on the network. Used to verify the
// sender from a terminal, without needing NDI Video Monitor's GUI.
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "Processing.NDI.Lib.h"

int main(int argc, char **argv) {
    int wait_ms = (argc > 1) ? atoi(argv[1]) : 4000;
    if (!NDIlib_initialize()) { fprintf(stderr, "NDIlib_initialize failed\n"); return 1; }

    NDIlib_find_create_t fc;
    memset(&fc, 0, sizeof(fc));
    fc.show_local_sources = true;
    NDIlib_find_instance_t finder = NDIlib_find_create_v2(&fc);
    if (!finder) { fprintf(stderr, "find_create failed\n"); NDIlib_destroy(); return 1; }

    NDIlib_find_wait_for_sources(finder, (uint32_t)wait_ms);
    uint32_t n = 0;
    const NDIlib_source_t *src = NDIlib_find_get_current_sources(finder, &n);
    printf("NDI sources found: %u\n", n);
    for (uint32_t i = 0; i < n; i++)
        printf("  [%u] %s   (%s)\n", i, src[i].p_ndi_name,
               src[i].p_url_address ? src[i].p_url_address : "-");

    NDIlib_find_destroy(finder);
    NDIlib_destroy();
    return n > 0 ? 0 : 3;
}
