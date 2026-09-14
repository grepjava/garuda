"""Applications for scripts/compress-test.sh.

One ASGI and one WSGI application, each with a route per case the compression
decision has to get right. Every compressible body is the same text, so the
test can compare what it decodes against one expected file.
"""

import asyncio
import gzip

TEXT = b"".join(b"line %d of a compressible response\n" % i for i in range(2000))
PLAIN = [(b"content-type", b"text/plain; charset=utf-8")]


async def _lifespan(receive, send):
    while True:
        message = await receive()
        if message["type"] == "lifespan.startup":
            await send({"type": "lifespan.startup.complete"})
        elif message["type"] == "lifespan.shutdown":
            await send({"type": "lifespan.shutdown.complete"})
            return


async def asgi(scope, receive, send):
    if scope["type"] == "lifespan":
        await _lifespan(receive, send)
        return

    path = scope["path"]
    headers = list(PLAIN)
    body = TEXT

    if path == "/stream":
        # The first piece has to reach the client while the application is
        # still asleep, which is what flushing each message is for.
        await send({"type": "http.response.start", "status": 200, "headers": headers})
        await send({"type": "http.response.body", "body": TEXT[:100], "more_body": True})
        await asyncio.sleep(1.5)
        await send({"type": "http.response.body", "body": TEXT[100:], "more_body": False})
        return
    if path == "/pieces":
        await send({"type": "http.response.start", "status": 200, "headers": headers})
        step = len(TEXT) // 10 + 1
        for i in range(0, len(TEXT), step):
            await send({"type": "http.response.body", "body": TEXT[i:i + step],
                        "more_body": True})
        await send({"type": "http.response.body", "body": b"", "more_body": False})
        return

    if path == "/small":
        body = b"tiny"
        headers.append((b"content-length", b"4"))
    elif path == "/png":
        headers = [(b"content-type", b"image/png")]
    elif path == "/encoded":
        headers.append((b"content-encoding", b"gzip"))
        body = gzip.compress(TEXT)
    elif path == "/no-transform":
        headers.append((b"cache-control", b"public, no-transform"))
    elif path == "/vary":
        headers.append((b"vary", b"Accept-Encoding"))
    elif path == "/declared":
        headers.append((b"content-length", str(len(TEXT)).encode()))
    elif path == "/events":
        headers = [(b"content-type", b"text/event-stream")]
    elif path == "/etag":
        headers.append((b"etag", b'"v1"'))
    elif path == "/weak-etag":
        headers.append((b"etag", b'W/"v1"'))

    await send({"type": "http.response.start", "status": 200, "headers": headers})
    await send({"type": "http.response.body", "body": body})


def wsgi(environ, start_response):
    path = environ["PATH_INFO"]
    headers = [("Content-Type", "text/plain; charset=utf-8")]
    half = len(TEXT) // 2

    if path == "/list":
        start_response("200 OK", headers)
        return [TEXT[:half], TEXT[half:]]
    if path == "/gen":
        start_response("200 OK", headers)
        return (TEXT[i:i + 5000] for i in range(0, len(TEXT), 5000))
    if path == "/write":
        write = start_response("200 OK", headers)
        write(TEXT[:1000])
        return [TEXT[1000:]]
    if path == "/small":
        start_response("200 OK", headers)
        return [b"tiny"]
    if path == "/png":
        start_response("200 OK", [("Content-Type", "image/png")])
        return [TEXT]
    if path == "/etag":
        start_response("200 OK", headers + [("ETag", '"v1"')])
        return [TEXT]
    start_response("200 OK", headers)
    return [TEXT]


if __name__ == "__main__":
    import sys
    sys.stdout.buffer.write(TEXT)
