"""Applications for scripts/trace-context-test.sh.

Each answers with the traceparent headers the request carried by the time it
reached the application, so the test can check the server left them alone.
"""


async def asgi_app(scope, receive, send):
    if scope["type"] != "http":
        return
    values = [v for k, v in scope["headers"] if k == b"traceparent"]
    body = b"n=%d tp=%s\n" % (len(values), b",".join(values))
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"text/plain")]})
    await send({"type": "http.response.body", "body": body})


def wsgi_app(environ, start_response):
    start_response("200 OK", [("Content-Type", "text/plain")])
    value = environ.get("HTTP_TRACEPARENT", "")
    return [("n=%d tp=%s\n" % (1 if value else 0, value)).encode()]
