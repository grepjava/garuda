"""Applications for scripts/cache-test.sh.

Every call the application actually receives is appended to the file named by
CACHE_LOG, one "METHOD target" line each, so the test can count how many
requests reached it and how many were answered from the cache. The body says
which call and which process produced it, so a copy served from the cache is
byte for byte the response that was stored.
"""

import os

CALLS = {}
PADDING = b"cacheable text, repeated so that compression has something to do. " * 40


def record(method, target):
    path = os.environ.get("CACHE_LOG")
    if not path:
        return
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, ("%s %s\n" % (method, target)).encode())
    finally:
        os.close(fd)


ROUTES = {
    "/fresh": [(b"cache-control", b"public, s-maxage=60")],
    "/maxage": [(b"cache-control", b"max-age=60")],
    "/short": [(b"cache-control", b"s-maxage=1")],
    "/private": [(b"cache-control", b"private, max-age=60")],
    "/nostore": [(b"cache-control", b"no-store, max-age=60")],
    "/cookie": [(b"cache-control", b"max-age=60"), (b"set-cookie", b"id=1")],
    "/vary-ua": [(b"cache-control", b"max-age=60"), (b"vary", b"User-Agent")],
    "/vary-ae": [(b"cache-control", b"max-age=60"), (b"vary", b"Accept-Encoding")],
    "/plain": [],
    "/big": [(b"cache-control", b"s-maxage=60")],
    "/stream": [(b"cache-control", b"s-maxage=60")],
    "/missing": [(b"cache-control", b"s-maxage=60")],
    "/broken": [(b"cache-control", b"s-maxage=60")],
    "/nothing": [(b"cache-control", b"s-maxage=60")],
}


async def asgi_app(scope, receive, send):
    if scope["type"] != "http":
        return
    path = scope["path"]
    target = path + ("?" + scope["query_string"].decode() if scope["query_string"] else "")
    record(scope["method"], target)
    CALLS[target] = CALLS.get(target, 0) + 1
    body = b"call=%d pid=%d target=%s\n" % (CALLS[target], os.getpid(), target.encode())
    status = 200
    headers = [(b"content-type", b"text/plain")] + ROUTES.get(path, ROUTES["/fresh"])
    if path == "/big":
        body += b"x" * (2 * 1024 * 1024)
    elif path == "/missing":
        status = 404
    elif path == "/broken":
        status = 500
    elif path == "/nothing":
        status = 204
    else:
        body += PADDING

    if path == "/stream":
        await send({"type": "http.response.start", "status": status, "headers": headers})
        await send({"type": "http.response.body", "body": body[:100], "more_body": True})
        await send({"type": "http.response.body", "body": body[100:]})
        return
    if status == 204:
        body = b""
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})


def wsgi_app(environ, start_response):
    path = environ["PATH_INFO"]
    query = environ.get("QUERY_STRING", "")
    target = path + ("?" + query if query else "")
    record(environ["REQUEST_METHOD"], target)
    CALLS[target] = CALLS.get(target, 0) + 1
    body = b"call=%d pid=%d target=%s\n" % (CALLS[target], os.getpid(), target.encode())
    headers = [("Content-Type", "text/plain")] + [
        (name.decode(), value.decode()) for name, value in ROUTES.get(path, ROUTES["/fresh"])]
    if path == "/big":
        body += b"x" * (2 * 1024 * 1024)
    else:
        body += PADDING

    if path == "/write":
        # The write() callable: the head goes out before the body is known.
        write = start_response("200 OK", headers)
        write(body)
        return []
    if path == "/short-length":
        # Declares more than it sends, which is a response nobody should keep.
        start_response("200 OK", headers + [("Content-Length", str(len(body) + 10))])
        return [body]
    start_response("200 OK", headers)
    if path == "/stream":
        return iter([body[:100], body[100:]])
    return [body]
