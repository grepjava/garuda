/* permessage-deflate: see garuda_wsdeflate.h. */

#include "garuda_wsdeflate.h"

#include <limits.h>
#include <stdlib.h>
#include <zlib.h>

/* Level 5, as for HTTP gzip: most of the ratio, little of the time. */
#define WS_LEVEL 5

void *pg_ws_deflate_new(int window_bits, int mem_level) {
    /* zlib cannot make a raw stream with an 8-bit window; the negotiation
     * refuses to promise one. */
    if (window_bits < 9) window_bits = 9;
    if (window_bits > 15) window_bits = 15;
    if (mem_level < 1) mem_level = 1;
    if (mem_level > 9) mem_level = 9;
    z_stream *z = calloc(1, sizeof *z);
    if (!z) return NULL;
    if (deflateInit2(z, WS_LEVEL, Z_DEFLATED, -window_bits, mem_level,
                     Z_DEFAULT_STRATEGY) != Z_OK) {
        free(z);
        return NULL;
    }
    return z;
}

void *pg_ws_inflate_new(int window_bits) {
    if (window_bits < 8) window_bits = 8;
    if (window_bits > 15) window_bits = 15;
    z_stream *z = calloc(1, sizeof *z);
    if (!z) return NULL;
    if (inflateInit2(z, -window_bits) != Z_OK) {
        free(z);
        return NULL;
    }
    return z;
}

void pg_ws_deflate_free(void *z) {
    if (!z) return;
    deflateEnd((z_stream *)z);
    free(z);
}

void pg_ws_inflate_free(void *z) {
    if (!z) return;
    inflateEnd((z_stream *)z);
    free(z);
}

int pg_ws_deflate_reset(void *z) { return deflateReset((z_stream *)z) == Z_OK ? 0 : -1; }
int pg_ws_inflate_reset(void *z) { return inflateReset((z_stream *)z) == Z_OK ? 0 : -1; }

int pg_ws_deflate_run(void *zp, const uint8_t *in, size_t n,
                      uint8_t *out, size_t cap, size_t *consumed, size_t *produced) {
    z_stream *z = (z_stream *)zp;
    static const uint8_t nothing = 0;
    if (n > UINT_MAX) n = UINT_MAX;
    if (cap > UINT_MAX) cap = UINT_MAX;
    z->next_in = (Bytef *)(n > 0 ? in : &nothing);
    z->avail_in = (uInt)n;
    z->next_out = out;
    z->avail_out = (uInt)cap;
    int rc = deflate(z, Z_SYNC_FLUSH);
    *consumed = n - z->avail_in;
    *produced = cap - z->avail_out;
    /* Z_BUF_ERROR is "no progress possible", which after a completed flush is
     * simply done. */
    if (rc != Z_OK && rc != Z_BUF_ERROR) return -1;
    return z->avail_out == 0 ? 1 : 0;
}

int pg_ws_inflate_run(void *zp, const uint8_t *in, size_t n,
                      uint8_t *out, size_t cap, size_t *consumed, size_t *produced) {
    z_stream *z = (z_stream *)zp;
    static const uint8_t nothing = 0;
    if (n > UINT_MAX) n = UINT_MAX;
    if (cap > UINT_MAX) cap = UINT_MAX;
    z->next_in = (Bytef *)(n > 0 ? in : &nothing);
    z->avail_in = (uInt)n;
    z->next_out = out;
    z->avail_out = (uInt)cap;
    int rc = inflate(z, Z_SYNC_FLUSH);
    *consumed = n - z->avail_in;
    *produced = cap - z->avail_out;
    switch (rc) {
    case Z_STREAM_END:
        return 2;
    case Z_OK:
        return z->avail_out == 0 ? 1 : 0;
    case Z_BUF_ERROR:
        if (z->avail_in == 0) return 0;
        return z->avail_out == 0 ? 1 : -1;
    default:
        return -1;
    }
}
