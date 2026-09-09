"""WebTransport and HTTP/3 for any ASGI application.

    from fastapi import FastAPI
    from peregrine.contrib.asgi import WebTransportRouter

    api = FastAPI()
    app = WebTransportRouter(api)

    @app.route("/chat/{room}")
    async def chat(session):
        await session.accept()
        room = session.path_params["room"]
        async for stream in session.incoming_streams():
            await stream.send(b"hello " + room.encode(), end=True)

Serve `app`. It is an ASGI application that answers `webtransport` scopes
itself and passes everything else through untouched, which is what a framework
router cannot do: it would assert on the scope type first.
"""

import re

from ..webtransport import WebTransportSession

__all__ = [
    "WebTransportRouter",
    "AltSvcMiddleware",
    "http_version",
    "is_http3",
    "supports_webtransport",
]

_PARAM = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")


class _Route:
    """One path pattern. `{name}` matches a single path segment."""

    def __init__(self, path, handler):
        self.path = path
        self.handler = handler
        pattern = "^" + _PARAM.sub(r"(?P<\1>[^/]+)", re.escape(path)
                                   .replace(r"\{", "{").replace(r"\}", "}")) + "$"
        self.regex = re.compile(pattern)

    def match(self, path):
        found = self.regex.match(path)
        return found.groupdict() if found else None


class WebTransportRouter:
    """An ASGI application that routes WebTransport sessions.

    Anything that is not a WebTransport session goes to `app` unchanged, so
    this wraps a framework rather than replacing it. With no `app`, a
    non-WebTransport request gets a plain 404 -- useful for a process that
    serves nothing else.
    """

    def __init__(self, app=None, routes=None):
        self.app = app
        self.routes = []
        for path, handler in (routes or {}).items():
            self.add_route(path, handler)

    # -- registration ------------------------------------------------------

    def add_route(self, path, handler):
        self.routes.append(_Route(path, handler))
        return handler

    def route(self, path):
        """Decorator form of `add_route`."""
        def register(handler):
            self.add_route(path, handler)
            return handler
        return register

    # -- ASGI --------------------------------------------------------------

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "webtransport":
            if self.app is None:
                await _not_found(scope, send)
                return
            await self.app(scope, receive, send)
            return

        path = scope.get("path", "/")
        for route in self.routes:
            params = route.match(path)
            if params is None:
                continue
            scope = dict(scope)
            scope["path_params"] = params
            session = WebTransportSession(scope, receive, send)
            await route.handler(session)
            if not session.closed:
                await session.close()
            return

        # No endpoint here. Refusing before accepting is an HTTP failure,
        # which is the only thing a client can be told at this point.
        session = WebTransportSession(scope, receive, send)
        await session.close(code=404)


class AltSvcMiddleware:
    """Adds `alt-svc` to HTTP responses, advertising HTTP/3 elsewhere.

    Peregrine already sends this for its own HTTP/3 listener, so this is for
    the case where it does not know the answer: a TLS-terminating proxy in
    front, or an HTTP/3 endpoint on a different host or port from the one this
    process is bound to.

        app = AltSvcMiddleware(app, port=443)
    """

    def __init__(self, app, value=None, port=None, max_age=86400):
        if value is None:
            if port is None:
                raise ValueError("AltSvcMiddleware needs a value or a port")
            value = 'h3=":%d"; ma=%d' % (int(port), int(max_age))
        self.app = app
        self.value = value.encode() if isinstance(value, str) else value

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "http" or scope.get("http_version") == "3":
            await self.app(scope, receive, send)
            return

        async def wrapped(message):
            if message["type"] == "http.response.start":
                headers = list(message.get("headers") or [])
                if not any(k.lower() == b"alt-svc" for k, _ in headers):
                    headers.append((b"alt-svc", self.value))
                message = dict(message, headers=headers)
            await send(message)

        await self.app(scope, receive, wrapped)


def http_version(scope):
    """"1.0", "1.1", "2" or "3" -- whatever carried this request."""
    return scope.get("http_version", "1.1")


def is_http3(scope):
    return http_version(scope) == "3"


def supports_webtransport(scope):
    """Whether this server offers the WebTransport extension."""
    return "webtransport" in (scope.get("extensions") or {})


async def _not_found(scope, send):
    if scope.get("type") != "http":
        return
    await send({"type": "http.response.start", "status": 404,
                "headers": [(b"content-type", b"text/plain")]})
    await send({"type": "http.response.body", "body": b"not found\n"})
