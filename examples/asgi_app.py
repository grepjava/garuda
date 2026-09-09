"""A small ASGI application used to exercise the server."""

import asyncio
import os

startup_ran = False

# What /lateread was given by the receive() it made after its response was
# already complete. ASGI says that is a disconnect.
late_receive = "nothing"

# The integration suite checks that lifespan shutdown actually runs, which it
# can only observe from outside the process.
SHUTDOWN_MARKER = os.environ.get("PEREGRINE_SHUTDOWN_MARKER")

# A lifespan handler that says it is done and then refuses to be cancelled.
# Only the feature test asks for it.
STUBBORN_LIFESPAN = os.environ.get("PEREGRINE_STUBBORN_LIFESPAN")


async def app(scope, receive, send):
    global startup_ran, late_receive

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
                if not STUBBORN_LIFESPAN:
                    return
                # Said its piece and then sat there, deaf to cancellation.
                # Waiting on this would mean no deadline at all.
                while True:
                    try:
                        await asyncio.sleep(3600)
                    except asyncio.CancelledError:
                        pass

    if scope["type"] == "websocket":
        await websocket_endpoint(scope, receive, send)
        return

    if scope["type"] == "webtransport":
        await webtransport_endpoint(scope, receive, send)
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

    elif path == "/altsvc":
        # An application that advertises its own alternative services; the
        # server must not add a second header of its own.
        await reply(b"mine\n", headers=[(b"alt-svc", b'h3=":9999"')])

    elif path == "/fixed":
        body = b"fixed length\n"
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"text/plain"),
                                (b"content-length", str(len(body)).encode())]})
        await send({"type": "http.response.body", "body": body})

    elif path == "/overlong":
        # Declares two bytes and then sends four. Emitting the excess would run
        # into the next response on a keep-alive connection.
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"text/plain"),
                                (b"content-length", b"2")]})
        try:
            await send({"type": "http.response.body", "body": b"LONG"})
        except Exception:
            # The server refuses it; report that it did rather than crashing.
            return

    elif path == "/short":
        # Declares ten bytes and sends three, which would leave the client
        # waiting for the rest until its own timeout.
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"text/plain"),
                                (b"content-length", b"10")]})
        try:
            await send({"type": "http.response.body", "body": b"abc"})
        except Exception:
            return

    elif path == "/reject":
        # Answers without reading a byte of the body. Nothing here can work
        # unless the application is dispatched on the head alone.
        await reply(b"denied\n", status=403)

    elif path == "/drip":
        # Reports the first chunk it is given, which is only interesting
        # because the client deliberately has not sent the rest yet.
        message = await receive()
        first = message.get("body", b"") if message["type"] == "http.request" else b""
        await reply(b"first-chunk:" + first + b"\n")

    elif path == "/slowsink":
        # Reads nothing for a moment, then drains. Whatever the client sends
        # meanwhile has to wait in the socket rather than in this process.
        await asyncio.sleep(float(scope["query_string"] or 1.0))
        total = 0
        while True:
            message = await receive()
            if message["type"] != "http.request":
                break
            total += len(message.get("body", b""))
            if not message.get("more_body", False):
                break
        await reply(str(total).encode() + b"\n")

    elif path == "/lateread":
        # Reads the body, answers, and then reads again. The request is over by
        # then, so the second read has to be told so rather than parked: the
        # connection cannot be reused while this task is still waiting.
        while True:
            message = await receive()
            if message["type"] != "http.request":
                break
            if not message.get("more_body", False):
                break
        await reply(b"first\n")
        late_receive = (await receive())["type"]

    elif path == "/lateread-result":
        # A separate request, so what /lateread saw survives its own task.
        await asyncio.sleep(0.3)
        await reply(late_receive.encode() + b"\n")

    elif path == "/uncancellable":
        # Swallows cancellation and keeps going, which is what the shutdown
        # path has to survive.
        while True:
            try:
                await asyncio.sleep(3600)
            except asyncio.CancelledError:
                pass

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

    if path == "/ws-silent":
        # Accepts and then never calls receive() again: a push-only endpoint.
        # Ping and pong still have to be handled, or the peer times out.
        await send({"type": "websocket.accept"})
        while True:
            await asyncio.sleep(0.5)
            await send({"type": "websocket.send", "text": "tick"})

    if path == "/ws-slow":
        # Accepts, then does lengthy work before reading anything.
        await send({"type": "websocket.accept"})
        await asyncio.sleep(3.0)
        while True:
            message = await receive()
            if message["type"] == "websocket.disconnect":
                return
            if message["type"] == "websocket.receive":
                await send({"type": "websocket.send",
                            "text": "late:" + (message.get("text") or "")})

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


async def webtransport_endpoint(scope, receive, send):
    """Exercises every message the WebTransport extension defines.

    /wt          echoes stream data and datagrams back the way they came
    /wt-reject   refuses the session
    /wt-push     opens a server-initiated stream and writes to it
    /wt-close    accepts, then closes with a code and a reason
    """
    path = scope["path"]

    message = await receive()
    assert message["type"] == "webtransport.connect", message

    if path == "/wt-reject":
        await send({"type": "webtransport.close", "code": 403})
        return

    await send({"type": "webtransport.accept"})

    if path == "/wt-close":
        await send({"type": "webtransport.close", "code": 7,
                    "reason": "asked to"})
        return

    if path == "/wt-push":
        # Both directions, so the client can check the prefix of each.
        await send({"type": "webtransport.stream.open", "bidirectional": False})
        opened = await receive()
        assert opened["type"] == "webtransport.stream.opened", opened
        await send({"type": "webtransport.stream.send",
                    "stream": opened["stream"], "data": b"push-uni",
                    "end_stream": True})
        await send({"type": "webtransport.stream.open", "bidirectional": True})
        opened = await receive()
        assert opened["type"] == "webtransport.stream.opened", opened
        await send({"type": "webtransport.stream.send",
                    "stream": opened["stream"], "data": b"push-bidi",
                    "end_stream": True})

    # Streams may be finished before their echo is written, so partial data is
    # accumulated per stream and answered when the peer says it is done.
    buffers = {}
    while True:
        message = await receive()
        kind = message["type"]
        if not kind.startswith("webtransport."):
            # The connection went away underneath the session rather than the
            # session ending; there is nothing left to answer.
            return
        if kind == "webtransport.disconnect":
            return
        if kind == "webtransport.datagram.receive":
            await send({"type": "webtransport.datagram.send",
                        "data": b"echo:" + message["data"]})
        elif kind == "webtransport.stream.receive":
            stream = message["stream"]
            buffers[stream] = buffers.get(stream, b"") + message["data"]
            if message["more_data"]:
                continue
            body = buffers.pop(stream)
            if stream % 4 == 0:
                # A bidirectional stream is answered on itself.
                await send({"type": "webtransport.stream.send", "stream": stream,
                            "data": b"echo:" + body, "end_stream": True})
            else:
                # A unidirectional one has to be answered on a new stream.
                await send({"type": "webtransport.stream.open",
                            "bidirectional": False})
                opened = await receive()
                await send({"type": "webtransport.stream.send",
                            "stream": opened["stream"], "data": b"echo:" + body,
                            "end_stream": True})
