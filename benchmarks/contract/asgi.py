"""Minimal ASGI app for the-benchmarker/web-frameworks contract."""


async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
        return

    method = scope.get("method", "GET")
    path = scope.get("path", "/")
    if method == "GET" and path == "/":
        body = b""
    elif method == "GET" and path.startswith("/user/"):
        body = path.rsplit("/", 1)[-1].encode()
    elif method == "POST" and path == "/user":
        while True:
            message = await receive()
            if message["type"] == "http.disconnect" or not message.get("more_body", False):
                break
        body = b""
    else:
        await send({"type": "http.response.start", "status": 404,
                    "headers": [(b"content-length", b"0")]})
        await send({"type": "http.response.body", "body": b""})
        return

    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-length", str(len(body)).encode())]})
    await send({"type": "http.response.body", "body": body})
