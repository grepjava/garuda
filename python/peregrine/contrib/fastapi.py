"""WebTransport and HTTP/3 for FastAPI and Starlette.

FastAPI is a Starlette application, and Starlette's router asserts that a scope
is `http`, `websocket` or `lifespan` before it looks at anything else. A
WebTransport session is none of those, so it has to be answered before the
framework sees it:

    from fastapi import FastAPI
    from peregrine.contrib.fastapi import WebTransportRouter

    api = FastAPI()
    app = WebTransportRouter(api)          # serve this one

    @app.route("/echo")
    async def echo(session):
        await session.accept()
        async for stream in session.incoming_streams():
            await stream.send(b"echo:" + await stream.read(), end=True)

Everything that is not a WebTransport session goes to `api` untouched, so the
rest of the application is unaffected -- including over HTTP/3, which needs no
integration at all because a request is the same request whatever carried it.
"""

import asyncio

from .asgi import AltSvcMiddleware
from .asgi import WebTransportRouter as _BaseRouter
from ..webtransport import WebTransportSession

__all__ = [
    "WebTransportRouter",
    "WebTransportEndpoint",
    "AltSvcMiddleware",
    "http_version",
    "is_http3",
    "supports_webtransport",
    "session_from",
]


class WebTransportEndpoint:
    """A class-based endpoint, in the shape of Starlette's WebSocketEndpoint.

        class Chat(WebTransportEndpoint):
            async def on_connect(self):
                await self.session.accept()

            async def on_stream(self, stream):
                await stream.send(b"echo:" + await stream.read(), end=True)

            async def on_datagram(self, data):
                await self.session.send_datagram(data)

        app.add_route("/chat", Chat)

    Streams and datagrams are handled concurrently, so a slow stream holds up
    neither the datagrams nor the streams behind it. Each `on_stream` runs in
    its own task, and an exception in one ends the session rather than being
    swallowed.
    """

    def __init__(self, session):
        self.session = session

    @property
    def scope(self):
        return self.session.scope

    @property
    def path_params(self):
        return self.session.path_params

    async def on_connect(self):
        """Called first. Accept the session here, or close it to refuse."""
        await self.session.accept()

    async def on_stream(self, stream):
        """Called once per stream the peer opens."""

    async def on_datagram(self, data):
        """Called once per datagram."""

    async def on_disconnect(self, code, reason):
        """Called once, after the session has ended."""

    async def dispatch(self):
        await self.on_connect()
        if not self.session.accepted:
            return
        tasks = [
            asyncio.ensure_future(self._streams()),
            asyncio.ensure_future(self._datagrams()),
        ]
        try:
            done, pending = await asyncio.wait(
                tasks, return_when=asyncio.FIRST_EXCEPTION)
            for task in pending:
                task.cancel()
            for task in done:
                task.result()
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await self.on_disconnect(self.session.close_code,
                                     self.session.close_reason)

    async def _streams(self):
        """Runs one `on_stream` task per stream, and fails if any of them do.

        A handler that raises has to reach `dispatch()`, which is the only
        thing that can end the session -- and it has to reach it *when* it
        raises, not whenever the next stream happens to arrive, because on a
        session where no further stream ever arrives that is never. So the
        failure is recorded by the done callback into a future this waits on
        alongside the accept loop.
        """
        running = set()
        failed = asyncio.get_running_loop().create_future()

        def finished(task):
            running.discard(task)
            if task.cancelled() or failed.done():
                return
            error = task.exception()
            if error is not None:
                failed.set_exception(error)

        async def accept():
            async for stream in self.session.incoming_streams():
                task = asyncio.ensure_future(self.on_stream(stream))
                running.add(task)
                task.add_done_callback(finished)
            if running:
                await asyncio.gather(*running)

        accepting = asyncio.ensure_future(accept())
        try:
            await asyncio.wait([accepting, failed],
                               return_when=asyncio.FIRST_COMPLETED)
            # A handler's failure is the more informative of the two, and the
            # accept loop may have finished cleanly beside it.
            if failed.done():
                failed.result()
            if accepting.done():
                accepting.result()
        finally:
            accepting.cancel()
            for task in list(running):
                task.cancel()
            await asyncio.gather(accepting, *running, return_exceptions=True)
            if not failed.done():
                failed.cancel()
            elif not failed.cancelled():
                failed.exception()      # retrieved, so asyncio does not warn

    async def _datagrams(self):
        async for data in self.session.datagrams():
            await self.on_datagram(data)


class WebTransportRouter(_BaseRouter):
    """The generic router, plus registration of `WebTransportEndpoint`
    subclasses, which is how Starlette's own routes are usually written."""

    def add_route(self, path, handler):
        if isinstance(handler, type) and issubclass(handler,
                                                    WebTransportEndpoint):
            endpoint = handler

            async def run(session):
                await endpoint(session).dispatch()

            super().add_route(path, run)
            return handler
        return super().add_route(path, handler)


def http_version(request_or_scope):
    """"1.0", "1.1", "2" or "3" -- whatever carried this request."""
    scope = getattr(request_or_scope, "scope", request_or_scope)
    return scope.get("http_version", "1.1")


def is_http3(request_or_scope):
    return http_version(request_or_scope) == "3"


def supports_webtransport(request_or_scope):
    scope = getattr(request_or_scope, "scope", request_or_scope)
    return "webtransport" in (scope.get("extensions") or {})


def session_from(scope, receive, send):
    """A session built straight from an ASGI call, for custom routing."""
    return WebTransportSession(scope, receive, send)
