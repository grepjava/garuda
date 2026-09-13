"""Raw ASGI responses of a fixed size, for benchmarks/body_sizes.sh.

GET /<bytes> answers with that many random bytes. Each body is built on first
use and kept, so the application does almost nothing per request and what the
benchmark sees is the server moving the body: copying it out of the `bytes`
object into the connection's write buffer, and writing it to the socket.
"""

import os

_bodies = {}


async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return

    name = scope["path"].strip("/")
    size = int(name) if name.isdigit() else 0
    body = _bodies.get(size)
    if body is None:
        body = _bodies[size] = os.urandom(size)
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-length", str(size).encode()),
                            (b"content-type", b"application/octet-stream")]})
    await send({"type": "http.response.body", "body": body})
