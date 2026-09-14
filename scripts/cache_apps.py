"""Applications for scripts/cache-test.sh.

Every call the application actually receives is appended to the file named by
CACHE_LOG, one "METHOD target" line each, so the test can count how many
requests reached it and how many were answered from the cache. The body says
which call and which process produced it, so a copy served from the cache is
byte for byte the response that was stored.

Any method but GET and HEAD is a change to the target: answered 200, or 403
when the request carries X-Deny. /etag evaluates If-Match itself, as an
application would.
"""

import asyncio
import email.utils
import os
import time

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
    "/item": [(b"cache-control", b"s-maxage=60")],
    "/slow-item": [(b"cache-control", b"s-maxage=60")],
    # Two minutes old by its own account, with a minute's lifetime.
    "/aged": [(b"cache-control", b"max-age=60"), (b"age", b"120")],
    "/half-aged": [(b"cache-control", b"max-age=60"), (b"age", b"30")],
    "/dated": [(b"cache-control", b"max-age=60")],
    "/etag": [(b"cache-control", b"s-maxage=60"), (b"etag", b'"v1"'),
              (b"last-modified", b"Sun, 06 Nov 1994 08:49:37 GMT")],
}


def extra_headers(path):
    if path == "/dated":
        # Dated an hour ago, with a minute's lifetime.
        return [(b"date", email.utils.formatdate(time.time() - 3600, usegmt=True).encode())]
    return []


async def asgi_app(scope, receive, send):
    if scope["type"] != "http":
        return
    path = scope["path"]
    target = path + ("?" + scope["query_string"].decode() if scope["query_string"] else "")
    record(scope["method"], target)
    CALLS[target] = CALLS.get(target, 0) + 1
    if scope["method"] not in ("GET", "HEAD"):
        denied = any(name.lower() == b"x-deny" for name, _ in scope["headers"])
        await send({"type": "http.response.start", "status": 403 if denied else 200,
                    "headers": [(b"content-type", b"text/plain")]})
        await send({"type": "http.response.body", "body": b"denied\n" if denied else b"changed\n"})
        return
    if path == "/etag":
        if_match = dict(scope["headers"]).get(b"if-match")
        if if_match is not None and if_match != b'"v1"':
            await send({"type": "http.response.start", "status": 412,
                        "headers": [(b"content-type", b"text/plain")]})
            await send({"type": "http.response.body", "body": b""})
            return
    body = b"call=%d pid=%d target=%s\n" % (CALLS[target], os.getpid(), target.encode())
    status = 200
    headers = ([(b"content-type", b"text/plain")] + ROUTES.get(path, ROUTES["/fresh"])
               + extra_headers(path))
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
    if path == "/slow-item":
        # Still answering when the test changes the target.
        await asyncio.sleep(1)

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
    if environ["REQUEST_METHOD"] not in ("GET", "HEAD"):
        denied = "HTTP_X_DENY" in environ
        start_response("403 Forbidden" if denied else "200 OK", [("Content-Type", "text/plain")])
        return [b"denied\n" if denied else b"changed\n"]
    body = b"call=%d pid=%d target=%s\n" % (CALLS[target], os.getpid(), target.encode())
    headers = [("Content-Type", "text/plain")] + [
        (name.decode(), value.decode())
        for name, value in ROUTES.get(path, ROUTES["/fresh"]) + extra_headers(path)]
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
