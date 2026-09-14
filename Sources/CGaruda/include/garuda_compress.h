#ifndef GARUDA_COMPRESS_H
#define GARUDA_COMPRESS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * Response body compression.
 *
 * gzip comes from zlib, which is linked: it is on every system this builds
 * on. brotli and zstd are loaded with dlopen the first time they are asked
 * for, so a machine without them still runs -- it just offers gzip -- and a
 * wheel does not have to carry either library.
 *
 * One streaming interface over all three. Swift drives it in a loop: feed
 * input, give it output space, call again while it says there is more.
 * ------------------------------------------------------------------------- */

#define PG_ENC_IDENTITY 0
#define PG_ENC_GZIP     1
#define PG_ENC_BR       2
#define PG_ENC_ZSTD     3

/* What to do with the input once it has been taken. */
#define PG_ENC_CONTINUE 0   /* buffer it; output whenever the codec likes */
#define PG_ENC_FLUSH    1   /* everything so far must be decodable by the peer */
#define PG_ENC_FINISH   2   /* end the stream */

/* 1 when the codec can be used in this process. */
int pg_enc_available(int codec);

/* A new stream, or NULL when the codec is unavailable or out of memory. */
void *pg_enc_new(int codec);
void pg_enc_free(void *enc);

/* Takes up to `n` bytes of `in` and writes up to `cap` bytes to `out`.
 *
 * Returns 0 when all of the input has been taken and whatever `mode` asked for
 * is complete, 1 when it must be called again with fresh output space (and
 * the input that was not yet consumed), and -1 when the codec failed.
 *
 * `*consumed` and `*produced` say how far it got either way. */
int pg_enc_run(void *enc, const uint8_t *in, size_t n, int mode,
               uint8_t *out, size_t cap, size_t *consumed, size_t *produced);

#ifdef __cplusplus
}
#endif

#endif
