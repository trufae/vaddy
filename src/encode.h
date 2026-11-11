#ifndef VADDY_ENCODE_H
#define VADDY_ENCODE_H
#include <zlib.h>
#include <zstd.h>
#include <stdlib.h>

struct vaddy_encoder {
    z_stream gzip;
    ZSTD_CCtx *zstd;
    int kind, consumed, written, finished;
};
static void *vaddy_encoder_new(int kind, int level) {
    struct vaddy_encoder *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->kind = kind;
    if (kind == 1) {
        if (deflateInit2(&e->gzip, level == -2 ? Z_DEFAULT_COMPRESSION : level, Z_DEFLATED,
                        31, 8, level == -2 ? Z_HUFFMAN_ONLY : Z_DEFAULT_STRATEGY) != Z_OK) { free(e); return NULL; }
    } else {
        e->zstd = ZSTD_createCCtx();
        if (!e->zstd || ZSTD_isError(ZSTD_CCtx_setParameter(e->zstd, ZSTD_c_compressionLevel, level)) ||
            ZSTD_isError(ZSTD_CCtx_setParameter(e->zstd, ZSTD_c_checksumFlag, 1))) {
            ZSTD_freeCCtx(e->zstd); free(e); return NULL;
        }
    }
    return e;
}
static void vaddy_encoder_free(struct vaddy_encoder *e) {
    if (!e) return;
    if (e->kind == 1) deflateEnd(&e->gzip);
    else ZSTD_freeCCtx(e->zstd);
    free(e);
}
// Flush each supplied block so SSE and slow producers remain incremental.
// Input/output consumption is explicit: neither codec can grow application queues.
static int vaddy_encoder_step(struct vaddy_encoder *e, const void *input, int length,
                              void *output, int capacity, int finish) {
    e->consumed = e->written = 0;
    if (e->kind == 1) {
        e->gzip.next_in = (Bytef *)input; e->gzip.avail_in = (uInt)length;
        e->gzip.next_out = output; e->gzip.avail_out = (uInt)capacity;
        int result = deflate(&e->gzip, finish ? Z_FINISH : Z_SYNC_FLUSH);
        e->consumed = length - (int)e->gzip.avail_in;
        e->written = capacity - (int)e->gzip.avail_out;
        e->finished = result == Z_STREAM_END;
        return result == Z_OK || result == Z_BUF_ERROR || result == Z_STREAM_END ? 0 : -1;
    }
    ZSTD_inBuffer in = {input, (size_t)length, 0};
    ZSTD_outBuffer out = {output, (size_t)capacity, 0};
    size_t result = ZSTD_compressStream2(e->zstd, &out, &in, finish ? ZSTD_e_end : ZSTD_e_flush);
    e->consumed = (int)in.pos; e->written = (int)out.pos;
    e->finished = finish && result == 0;
    return ZSTD_isError(result) ? -1 : 0;
}
#endif
