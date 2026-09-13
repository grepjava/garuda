"""Applications for scripts/redirect-test.sh.

`/` answers with no security headers of its own; `/own-hsts` sets its own
Strict-Transport-Security, which the server must leave alone rather than send a
second one beside.
"""

OWN = b"max-age=60"


async def asgi_app(scope, receive, send):
    if scope["type"] != "http":
        return
    headers = [(b"content-type", b"text/plain")]
    if scope["path"] == "/own-hsts":
        headers.append((b"strict-transport-security", OWN))
    await send({"type": "http.response.start", "status": 200, "headers": headers})
    await send({"type": "http.response.body", "body": b"asgi\n"})


def wsgi_app(environ, start_response):
    headers = [("Content-Type", "text/plain")]
    if environ["PATH_INFO"] == "/own-hsts":
        headers.append(("Strict-Transport-Security", OWN.decode()))
    start_response("200 OK", headers)
    return [b"wsgi\n"]
