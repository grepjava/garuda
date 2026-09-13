"""Applications for scripts/request-start-test.sh: each answers with the
X-Request-Start it was handed, or "none"."""

import time


def wsgi(environ, start_response):
    if environ["PATH_INFO"] == "/slow":
        time.sleep(0.3)
    value = environ.get("HTTP_X_REQUEST_START", "none").encode()
    start_response("200 OK", [("Content-Type", "text/plain")])
    return [value]


async def asgi(scope, receive, send):
    if scope["type"] != "http":
        return
    value = b"none"
    for name, v in scope["headers"]:
        if name == b"x-request-start":
            value = v
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"text/plain")]})
    await send({"type": "http.response.body", "body": value})
