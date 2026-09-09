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
import uuid

from ..webtransport import WebTransportSession

__all__ = [
    "WebTransportRouter",
    "AltSvcMiddleware",
    "http_version",
    "is_http3",
    "supports_webtransport",
    "session_from",
]


def _to_uuid(value):
    return uuid.UUID(value)


# Starlette's convertors, plus Django's `slug`. `{name}` is `str`.
CONVERTERS = {
    "str": (r"[^/]+", None),
    "int": (r"[0-9]+", int),
    "float": (r"[0-9]+(?:\.[0-9]+)?", float),
    "uuid": (
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
        r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        _to_uuid,
    ),
    "path": (r".*", None),
    "slug": (r"[-a-zA-Z0-9_]+", None),
}

_PARAM = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)(?::([a-z]+))?\}")


class _Route:
    """One path pattern. `{name}` and `{name:int}` match the way Starlette does."""

    def __init__(self, path, handler, converters=None):
        self.path = path
        self.handler = handler
        self.converters = {}
        converters = converters if converters is not None else CONVERTERS
        parts = []
        remainder = path
        while True:
            found = _PARAM.search(remainder)
            if found is None:
                parts.append(re.escape(remainder))
                break
            parts.append(re.escape(remainder[:found.start()]))
            name, kind = found.group(1), found.group(2) or "str"
            spec = converters.get(kind)
            if spec is None:
                raise ValueError("unknown path converter %r in %r" % (kind, path))
            if name in self.converters:
                raise ValueError("duplicate path parameter %r in %r" % (name, path))
            pattern, convert = spec
            self.converters[name] = convert
            parts.append("(?P<%s>%s)" % (name, pattern))
            remainder = remainder[found.end():]
        self.regex = re.compile("^" + "".join(parts) + "$")

    def match(self, path):
        found = self.regex.match(path)
        if found is None:
            return None
        params = found.groupdict()
        try:
            for name, convert in self.converters.items():
                if convert is not None and name in params:
                    params[name] = convert(params[name])
        except (ValueError, TypeError):
            return None
        return params


class WebTransportRouter:
    """An ASGI application that routes WebTransport sessions.

    Anything that is not a WebTransport session goes to `app` unchanged, so
    this wraps a framework rather than replacing it. With no `app`, a
    non-WebTransport request gets a plain 404 -- useful for a process that
    serves nothing else.
    """

    converters = CONVERTERS

    def __init__(self, app=None, routes=None):
        self.app = app
        self.routes = []
        for path, handler in (routes or {}).items():
            self.add_route(path, handler)

    # -- registration ------------------------------------------------------

    def add_route(self, path, handler):
        self.routes.append(_Route(path, handler, self.converters))
        return handler

    def route(self, path):
        """Decorator form of `add_route`."""
        def register(handler):
            self.add_route(path, handler)
            return handler
        return register

    # -- ASGI --------------------------------------------------------------

    def _lookup(self, path):
        for route in self.routes:
            params = route.match(path)
            if params is not None:
                return route, params
        return None, None

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "webtransport":
            if self.app is None:
                await _not_found(scope, send)
                return
            await self.app(scope, receive, send)
            return

        path = scope.get("path", "/")
        route, params = self._lookup(path)
        if route is None:
            # A session cannot be redirected the way an HTTP request can, so
            # a missing or extra trailing slash is tried the other way rather
            # than refused. Exact matches still win.
            alt = path[:-1] if path.endswith("/") and path != "/" else path + "/"
            route, params = self._lookup(alt)
        if route is not None:
            scope = dict(scope)
            scope["path_params"] = params
            session = WebTransportSession(scope, receive, send)
            error = None
            try:
                await route.handler(session)
            except BaseException as exc:
                error = exc
                raise
            finally:
                if not session.closed:
                    try:
                        await session.close()
                    except Exception:
                        if error is None:
                            raise
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
                if not any(_header_is(k, b"alt-svc") for k, _ in headers):
                    headers.append((b"alt-svc", self.value))
                message = dict(message, headers=headers)
            await send(message)

        await self.app(scope, receive, wrapped)


def http_version(scope):
    """"1.0", "1.1", "2" or "3" -- whatever carried this request."""
    scope = getattr(scope, "scope", scope)
    if isinstance(scope, dict):
        return scope.get("http_version", "1.1")
    return "1.1"


def is_http3(scope):
    return http_version(scope) == "3"


def supports_webtransport(scope):
    """Whether this connection offers the WebTransport extension.

    True on a `webtransport` scope, and on an HTTP/3 request whose server
    advertised the extension. HTTP/1.1 and HTTP/2 never do -- WebTransport
    is HTTP/3 only.
    """
    scope = getattr(scope, "scope", scope)
    if not isinstance(scope, dict):
        return False
    return "webtransport" in (scope.get("extensions") or {})


def session_from(scope, receive, send):
    """A session built straight from an ASGI call, for custom routing."""
    return WebTransportSession(scope, receive, send)


def _header_is(name, expected):
    if isinstance(name, bytes):
        return name.lower() == expected
    return str(name).lower() == expected.decode()


async def _not_found(scope, send):
    if scope.get("type") != "http":
        return
    await send({"type": "http.response.start", "status": 404,
                "headers": [(b"content-type", b"text/plain")]})
    await send({"type": "http.response.body", "body": b"not found\n"})
