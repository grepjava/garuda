"""Applications for scripts/request-id-test.sh.

Each answers with what it was handed: how many X-Request-ID headers the
request carried by the time it reached the application, and the value.
`/own-id` also sets an X-Request-ID of its own on the response, which the
server must not send a second one beside.
"""


async def asgi_app(scope, receive, send):
    if scope["type"] != "http":
        return
    ids = [v for k, v in scope["headers"] if k == b"x-request-id"]
    headers = [(b"content-type", b"text/plain")]
    if scope["path"] == "/own-id":
        headers.append((b"x-request-id", b"from-the-app"))
    body = b"n=%d id=%s\n" % (len(ids), ids[0] if ids else b"")
    await send({"type": "http.response.start", "status": 200, "headers": headers})
    await send({"type": "http.response.body", "body": body})


def wsgi_app(environ, start_response):
    headers = [("Content-Type", "text/plain")]
    if environ["PATH_INFO"] == "/own-id":
        headers.append(("X-Request-ID", "from-the-app"))
    start_response("200 OK", headers)
    value = environ.get("HTTP_X_REQUEST_ID", "")
    return [("n=%d id=%s\n" % (1 if value else 0, value)).encode()]
