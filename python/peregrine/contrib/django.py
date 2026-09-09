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
are written the way Django writes them -- `<str:name>`, `<int:name>`,
`<slug:name>`, `<uuid:name>` and `<path:name>` are understood, and a leading
slash is optional so a route reads like a `urlpatterns` entry.

Django needs no integration at all for HTTP/3: a request is the same request
whatever carried it, and `request.is_secure()`, `request.scheme` and
`REMOTE_ADDR` are all correct over QUIC. `http_version(request)` is here for
applications that want to know anyway.
"""

import re

from .asgi import CONVERTERS as _CONVERTERS
from .asgi import AltSvcMiddleware
from .asgi import WebTransportRouter as _BaseRouter
from .asgi import session_from, supports_webtransport

__all__ = [
    "WebTransportRouter",
    "AltSvcMiddleware",
    "http_version",
    "is_http3",
    "supports_webtransport",
    "session_from",
]

# Django's path() converters: `<int:pk>`, or `<name>` which is `str`.
_CONVERTER = re.compile(r"<(?:([a-z]+):)?([A-Za-z_][A-Za-z0-9_]*)>")


class WebTransportRouter(_BaseRouter):
    """The generic router, with Django's path syntax and converter types."""

    # Django's `path` converter is `.+` (at least one character); Starlette's
    # is `.*`. Keep each framework's own rule.
    converters = dict(_CONVERTERS)
    converters["path"] = (r".+", None)

    def add_route(self, path, handler):
        if not path.startswith("/"):
            path = "/" + path

        def translate(match):
            kind, name = match.group(1) or "str", match.group(2)
            return "{%s:%s}" % (name, kind)

        return super().add_route(_CONVERTER.sub(translate, path), handler)


def http_version(request):
    """"1.0", "1.1", "2" or "3" -- whatever carried this request.

    Takes a Django `HttpRequest` of either kind, or a raw ASGI scope, because a
    WebTransport endpoint has one and not the other.

    The scope is consulted before `META`. An `ASGIRequest` carries both, but
    Django builds `META` from the scope by hand and historically omitted
    `SERVER_PROTOCOL`; reading `META` first would report "1.1" for every ASGI
    request, HTTP/3 included. WSGI requests have no scope and fall through to
    `SERVER_PROTOCOL`, which peregrine sets to `HTTP/2` or `HTTP/3` when that
    is what carried them.
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
