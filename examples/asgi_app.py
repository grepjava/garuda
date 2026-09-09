"""A small ASGI application used to exercise the server."""

import asyncio
import os

startup_ran = False

# The integration suite checks that lifespan shutdown actually runs, which it
# can only observe from outside the process.
SHUTDOWN_MARKER = os.environ.get("PEREGRINE_SHUTDOWN_MARKER")


async def app(scope, receive, send):
    global startup_ran

    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                startup_ran = True
                scope["state"]["shared"] = "from-lifespan"
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                if SHUTDOWN_MARKER:
                    with open(SHUTDOWN_MARKER, "w") as fh:
                        fh.write("clean\n")
                await send({"type": "lifespan.shutdown.complete"})
                return

    if scope["type"] == "websocket":
        await websocket_endpoint(scope, receive, send)
        return

    assert scope["type"] == "http"
    path = scope["path"]

    async def reply(body, status=200, headers=None, content_type=b"text/plain"):
        hdrs = [(b"content-type", content_type)]
        if headers:
            hdrs.extend(headers)
        await send({"type": "http.response.start", "status": status, "headers": hdrs})
        await send({"type": "http.response.body", "body": body})

    if path == "/":
        await reply(b"hello from peregrine asgi\n")

    elif path == "/echo":
        chunks = []
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            chunks.append(message.get("body", b""))
            if not message.get("more_body", False):
                break
        await reply(b"".join(chunks), content_type=b"application/octet-stream")

    elif path == "/pid":
        await reply(str(os.getpid()).encode())

    elif path == "/scope":
        interesting = {
            "type": scope["type"],
            "http_version": scope["http_version"],
            "method": scope["method"],
            "scheme": scope["scheme"],
            "path": scope["path"],
            "raw_path": scope["raw_path"].decode(),
            "query_string": scope["query_string"].decode(),
            "root_path": scope["root_path"],
            "client": list(scope["client"]) if scope.get("client") else None,
            "server": list(scope["server"]) if scope.get("server") else None,
            "state": dict(scope.get("state") or {}),
            "headers": {k.decode(): v.decode() for k, v in scope["headers"]},
            "startup_ran": startup_ran,
        }
        import json
        await reply(json.dumps(interesting, sort_keys=True).encode() + b"\n",
                    content_type=b"application/json")

    elif path == "/listpairs":
        # ASGI says "an iterable of [name, value] two-item iterables", and
        # plenty of frameworks build lists rather than tuples.
        await send({"type": "http.response.start", "status": 200,
                    "headers": [[b"content-type", b"text/plain"],
                                [b"x-shape", b"list"]]})
        await send({"type": "http.response.body", "body": b"list pairs\n"})

    elif path == "/stream":
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"text/plain")]})
        for i in range(5):
            await send({"type": "http.response.body",
                        "body": b"chunk-%d\n" % i, "more_body": True})
        await send({"type": "http.response.body", "body": b"", "more_body": False})

    elif path == "/firehose":
        # A producer that never awaits anything but send(). If send() does not
        # apply backpressure, the write buffer grows without bound whenever the
        # client reads slowly, and this is what makes that observable.
        total = int(scope["query_string"] or 64 * 1024 * 1024)
        block = b"x" * 65536
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"application/octet-stream"),
                                (b"content-length", str(total).encode())]})
        sent = 0
        while sent < total:
            n = min(len(block), total - sent)
            await send({"type": "http.response.body",
                        "body": block[:n], "more_body": True})
            sent += n
        await send({"type": "http.response.body", "body": b"", "more_body": False})

    elif path == "/slow":
        # Long enough that a shutdown started mid-request has to decide between
        # waiting for it and enforcing its deadline.
        seconds = float(scope["query_string"] or 30)
        await asyncio.sleep(seconds)
        await reply(b"eventually\n")

    elif path == "/sleep":
        await asyncio.sleep(0.25)
        await reply(b"slept\n")

    elif path == "/big":
        n = int(scope["query_string"] or 100000)
        await reply(b"x" * n, content_type=b"application/octet-stream")

    elif path == "/fixed":
        body = b"fixed length\n"
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"text/plain"),
                                (b"content-length", str(len(body)).encode())]})
        await send({"type": "http.response.body", "body": body})

    elif path == "/boom":
        raise RuntimeError("intentional asgi failure")

    else:
        await reply(b"not found\n", status=404)


async def websocket_endpoint(scope, receive, send):
    """Echo server, plus a few paths the integration suite needs."""
    path = scope["path"]

    message = await receive()
    assert message["type"] == "websocket.connect", message

    if path == "/ws-reject":
        await send({"type": "websocket.close", "code": 1008})
        return

    accept = {"type": "websocket.accept"}
    if path == "/ws-sub":
        offered = scope.get("subprotocols") or []
        if "chat" in offered:
            accept["subprotocol"] = "chat"
    await send(accept)

    if path == "/ws-scope":
        import json
        await send({"type": "websocket.send",
                    "text": json.dumps({
                        "type": scope["type"],
                        "scheme": scope["scheme"],
                        "path": scope["path"],
                        "subprotocols": scope.get("subprotocols"),
                        "client": list(scope["client"]) if scope.get("client") else None,
                    }, sort_keys=True)})

    while True:
        message = await receive()
        kind = message["type"]
        if kind == "websocket.disconnect":
            return
        if kind != "websocket.receive":
            continue
        if message.get("text") is not None:
            text = message["text"]
            if text == "close":
                await send({"type": "websocket.close", "code": 1000,
                            "reason": "asked to"})
                return
            await send({"type": "websocket.send", "text": "echo:" + text})
        else:
            await send({"type": "websocket.send", "bytes": b"echo:" + message["bytes"]})
