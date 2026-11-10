#ifndef VADDY_LOG_WRITER_H
#define VADDY_LOG_WRITER_H
#include <stdio.h>
#include <zlib.h>
/* Stream compression with a fixed buffer, including for large rolled files. */
static int vaddy_gzip_file(const char *source, const char *target) {
    FILE *input = fopen(source, "rb");
    if (!input) return -1;
    gzFile output = gzopen(target, "wb");
    if (!output) { fclose(input); return -1; }
    unsigned char buffer[65536];
    size_t count;
    int ok = 1;
    while ((count = fread(buffer, 1, sizeof buffer, input)) > 0) {
        if (gzwrite(output, buffer, (unsigned int)count) != (int)count) { ok = 0; break; }
    }
    if (ferror(input)) ok = 0;
    if (fclose(input)) ok = 0;
    if (gzclose(output) != Z_OK) ok = 0;
    return ok ? 0 : -1;
}
#endif
