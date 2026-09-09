"""WebTransport and HTTP/3 for Django.

Django's ASGI handler asserts `scope["type"] == "http"`, so a WebTransport
session has to be answered before it reaches Django:

    # asgi.py
    import os
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "myproject.settings")

    from django.core.asgi import get_asgi_application
    from peregrine.contrib.django import WebTransportRouter

    application = WebTransportRouter(get_asgi_application())

    @application.route("chat/<str:room>/")
    async def chat(session):
        await session.accept()
        room = session.path_params["room"]
        ...

Everything that is not a WebTransport session goes to Django untouched. Paths
are written the way Django writes them -- `<str:name>`, `<int:name>`, `<slug:name>`
and `<uuid:name>` are understood, and a leading slash is optional so a route
reads like a `urlpatterns` entry.

Django needs no integration at all for HTTP/3: a request is the same request
whatever carried it, and `request.is_secure()`, `request.scheme` and
`REMOTE_ADDR` are all correct over QUIC. `http_version(request)` is here for
applications that want to know anyway.
"""

import re

from .asgi import AltSvcMiddleware
from .asgi import WebTransportRouter as _BaseRouter

__all__ = [
    "WebTransportRouter",
    "AltSvcMiddleware",
    "http_version",
    "is_http3",
]

# Django's path() converters, as far as a single path segment is concerned.
_CONVERTER = re.compile(r"<(?:([a-z]+):)?([A-Za-z_][A-Za-z0-9_]*)>")
_INT = re.compile(r"^[0-9]+$")


class WebTransportRouter(_BaseRouter):
    """The generic router, with Django's path syntax and int conversion."""

    def add_route(self, path, handler):
        if not path.startswith("/"):
            path = "/" + path
        converters = {}

        def translate(match):
            kind, name = match.group(1) or "str", match.group(2)
            converters[name] = kind
            return "{%s}" % name

        translated = _CONVERTER.sub(translate, path)
        if converters:
            handler = _Converting(handler, converters)
        return super().add_route(translated, handler)


class _Converting:
    """Applies Django's converter semantics to what the pattern matched."""

    def __init__(self, handler, converters):
        self.handler = handler
        self.converters = converters

    async def __call__(self, session):
        params = session.scope.get("path_params") or {}
        for name, kind in self.converters.items():
            value = params.get(name)
            if value is None:
                continue
            if kind == "int":
                if not _INT.match(value):
                    await session.close(code=404)
                    return
                params[name] = int(value)
        await self.handler(session)


def http_version(request):
    """"1.0", "1.1", "2" or "3" -- whatever carried this request.

    Takes a Django `HttpRequest` of either kind, or a raw ASGI scope, because a
    WebTransport endpoint has one and not the other.

    The scope is consulted before `META`, and that order is load-bearing: an
    `ASGIRequest` carries both, but Django builds its `META` from the scope by
    hand and puts no `SERVER_PROTOCOL` in it. Reading `META` first would answer
    "1.1" for every request Django ever serves over ASGI, HTTP/3 included.
    """
    scope = getattr(request, "scope", None)
    if isinstance(scope, dict) and "http_version" in scope:
        return scope["http_version"]
    meta = getattr(request, "META", None)
    if meta is not None:
        protocol = meta.get("SERVER_PROTOCOL")
        if protocol:
            return protocol.split("/", 1)[-1] if "/" in protocol else protocol
    if isinstance(request, dict):
        return request.get("http_version", "1.1")
    return "1.1"


def is_http3(request):
    return http_version(request) == "3"
