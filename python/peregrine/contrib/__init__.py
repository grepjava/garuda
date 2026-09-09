"""Framework integrations.

Nothing here is needed to serve an ordinary application: FastAPI, Starlette and
Django run over HTTP/1.1, HTTP/2 and HTTP/3 unchanged, because the request is
the same request whatever carried it.

What they cannot do unaided is WebTransport. A session is not a request, so it
arrives with `scope["type"] == "webtransport"`, and every ASGI framework
asserts on that field before routing: Starlette's router allows `http`,
`websocket` and `lifespan`, and Django's handler allows `http` alone. So a
WebTransport endpoint has to be reached before the framework sees the scope,
which is what the routers in this package do -- they answer WebTransport
themselves and hand everything else to the application unchanged.

Paths keep each framework's own spelling. Starlette `{name}` / `{name:int}`
and Django `<str:name>` / `<int:name>` convert; a missing trailing slash is
tried the other way, because a session cannot be HTTP-redirected.
"""
