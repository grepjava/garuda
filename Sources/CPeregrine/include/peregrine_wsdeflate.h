/* Raw deflate for WebSocket permessage-deflate (RFC 7692).
 *
 * A message is compressed with a sync flush, so it ends on a byte boundary with
 * the empty stored block 00 00 ff ff, which the sender strips and the receiver
 * puts back. There is no zlib or gzip wrapper, and the compression context may
 * carry from one message to the next -- which is what makes a stream of small,
 * similar messages compress at all.
 */
#ifndef PEREGRINE_WSDEFLATE_H
#define PEREGRINE_WSDEFLATE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* window_bits 9..15, mem_level 1..9. NULL when zlib cannot make one. */
void *pg_ws_deflate_new(int window_bits, int mem_level);
/* window_bits 8..15: at least the window the peer compresses with. */
void *pg_ws_inflate_new(int window_bits);
void pg_ws_deflate_free(void *z);
void pg_ws_inflate_free(void *z);
/* Forget the context, for no_context_takeover. 0 on success. */
int pg_ws_deflate_reset(void *z);
int pg_ws_inflate_reset(void *z);

/* Compresses `in` with a sync flush into `out`. Returns 1 when `out` filled and
 * the call should be repeated with the input not yet consumed, 0 when the
 * flush is complete, -1 on error. */
int pg_ws_deflate_run(void *z, const uint8_t *in, size_t n,
                      uint8_t *out, size_t cap, size_t *consumed, size_t *produced);
/* Inflates `in` into `out`. Returns 1 when `out` filled, 0 when all of `in` is
 * consumed, 2 when the peer ended its deflate stream (the context must then be
 * reset before the next message), -1 when `in` is not valid deflate. */
int pg_ws_inflate_run(void *z, const uint8_t *in, size_t n,
                      uint8_t *out, size_t cap, size_t *consumed, size_t *produced);

#ifdef __cplusplus
}
#endif

#endif /* PEREGRINE_WSDEFLATE_H */
