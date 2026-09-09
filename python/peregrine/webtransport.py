"""A WebTransport session object, over Peregrine's ASGI extension.

ASGI has no WebTransport specification, so Peregrine defines one (it is
documented in TRANSPORT.md). It is a message protocol, in the same shape as
ASGI's HTTP and WebSocket ones, and writing against it directly is perfectly
possible:

    async def app(scope, receive, send):
        assert (await receive())["type"] == "webtransport.connect"
        await send({"type": "webtransport.accept"})
        ...

What this module adds is the part every application would otherwise write for
itself: one `receive()` channel has to be demultiplexed into several streams, a
datagram queue, and the answers to stream-open requests, and doing that by hand
in every endpoint is both tedious and easy to get wrong.

    async def endpoint(session):
        await session.accept()
        async for stream in session.incoming_streams():
            data = await stream.read()
            await stream.send(b"echo:" + data, end=True)

Backpressure is per stream, not per session. A full stream queue sends
`webtransport.stream.pause`, which leaves that stream's bytes in the QUIC
buffer so its window does not reopen. The pump keeps reading, so every other
stream and every datagram still move. `resume` is sent when the application
drains the queue again. Datagrams are unreliable: a full datagram queue drops
the oldest, matching the server.
"""

import asyncio

__all__ = [
    "WebTransportSession",
    "WebTransportStream",
    "WebTransportError",
    "SessionClosed",
]

# Per-stream chunks, datagrams, and streams the peer has opened but the
# application has not accepted yet. Bounds, not buffers: reaching one is what
# applies backpressure.
STREAM_QUEUE = 32
DATAGRAM_QUEUE = 64
INCOMING_QUEUE = 64

_END = object()


class WebTransportError(Exception):
    """The session could not do what was asked of it."""


class SessionClosed(WebTransportError):
    """The session ended while an operation was outstanding."""


class WebTransportStream:
    """One stream inside a session.

    Reading is an async iterator of `bytes`; the iteration ends when the peer
    finishes or resets the stream, which are the same thing as far as anything
    an application can do about it.
    """

    def __init__(self, session, stream_id, bidirectional, writable=True):
        self.id = stream_id
        self.bidirectional = bidirectional
        self.session = session
        self._queue = asyncio.Queue(maxsize=STREAM_QUEUE)
        self._pending = []
        self._paused = False
        self._eof = False
        self._writable = writable
        self._ended = False

    # -- reading -----------------------------------------------------------

    @property
    def at_eof(self):
        return self._eof and self._queue.empty() and not self._pending

    async def receive(self):
        """The next run of bytes, or None once the stream has ended."""
        if self._eof and self._queue.empty() and not self._pending:
            return None
        self._pull_pending()
        chunk = await self._queue.get()
        self._pull_pending()
        if chunk is _END:
            self._eof = True
            await self.session._maybe_resume(self)
            return None
        await self.session._maybe_resume(self)
        return chunk

    def _pull_pending(self):
        while self._pending and not self._queue.full():
            self._queue.put_nowait(self._pending.pop(0))

    async def read(self):
        """Everything the peer sends, as one `bytes`."""
        parts = []
        while True:
            chunk = await self.receive()
            if chunk is None:
                return b"".join(parts)
            parts.append(chunk)

    def __aiter__(self):
        return self

    async def __anext__(self):
        chunk = await self.receive()
        if chunk is None:
            raise StopAsyncIteration
        return chunk

    # -- writing -----------------------------------------------------------

    @property
    def writable(self):
        return self._writable and not self._ended

    async def send(self, data=b"", end=False):
        if not self._writable:
            raise WebTransportError("this stream cannot be written to")
        if self._ended:
            raise WebTransportError("the stream has already been ended")
        await self.session._send({
            "type": "webtransport.stream.send",
            "stream": self.id,
            "data": _as_bytes(data),
            "end_stream": bool(end),
        })
        if end:
            self._ended = True

    async def end(self):
        """Finishes this direction without sending anything more."""
        if not self._ended and self._writable:
            await self.send(b"", end=True)


class WebTransportSession:
    """A WebTransport session, from the server's side.

    Construct it with the three arguments an ASGI application is called with;
    the `webtransport.connect` message is consumed by `accept()` or `close()`,
    so an endpoint never has to see it.
    """

    def __init__(self, scope, receive, send):
        if scope.get("type") != "webtransport":
            raise WebTransportError(
                "not a webtransport scope: %r" % (scope.get("type"),))
        self.scope = scope
        self._receive = receive
        self._raw_send = send

        self.accepted = False
        self.closed = False
        self.close_code = 0
        self.close_reason = ""

        self._streams = {}
        self._incoming = asyncio.Queue(maxsize=INCOMING_QUEUE)
        self._held = []
        self._datagrams = asyncio.Queue(maxsize=DATAGRAM_QUEUE)
        self._opened = asyncio.Queue()
        self._pump = None
        self._connected = False

    # -- the request that became a session ---------------------------------

    @property
    def path(self):
        return self.scope.get("path", "/")

    @property
    def headers(self):
        """Request headers, as the list of (bytes, bytes) pairs ASGI uses."""
        return self.scope.get("headers", [])

    @property
    def client(self):
        return self.scope.get("client")

    @property
    def path_params(self):
        """Whatever the router matched out of the path."""
        return self.scope.get("path_params", {})

    # -- lifecycle ---------------------------------------------------------

    async def _connect(self):
        if self._connected:
            return
        message = await self._receive()
        if message["type"] != "webtransport.connect":
            raise WebTransportError(
                "expected webtransport.connect, got %r" % (message["type"],))
        self._connected = True

    async def accept(self, headers=None):
        """Answers the CONNECT with 200 and starts the session."""
        await self._connect()
        if self.accepted:
            raise WebTransportError("the session has already been accepted")
        message = {"type": "webtransport.accept"}
        if headers:
            message["headers"] = [(_as_bytes(k, "header name"),
                                   _as_bytes(v, "header value"))
                                  for k, v in headers]
        await self._raw_send(message)
        self.accepted = True
        self._pump = asyncio.ensure_future(self._run())

    async def close(self, code=0, reason=""):
        """Ends the session, or refuses it if it was never accepted.

        Before `accept()`, the code is how the client is refused: one in the
        400-599 range becomes that HTTP status, anything else becomes 403.
        """
        await self._connect()
        if self.closed:
            return
        self.closed = True
        try:
            await self._raw_send({
                "type": "webtransport.close",
                "code": int(code),
                "reason": reason,
            })
        finally:
            await self._stop()

    async def _stop(self):
        if self._pump is not None:
            self._pump.cancel()
            try:
                await self._pump
            except asyncio.CancelledError:
                pass
            self._pump = None
        self._shut_down()

    def _shut_down(self):
        self._held.clear()
        for stream in self._streams.values():
            stream._eof = True
            stream._pending.clear()
            _put_nowait(stream._queue, _END)
        _put_nowait(self._incoming, _END)
        _put_nowait(self._datagrams, _END)
        _put_nowait(self._opened, _END)

    async def _send(self, message):
        if self.closed:
            raise SessionClosed("the session has ended")
        await self._raw_send(message)

    # -- the pump ----------------------------------------------------------

    async def _run(self):
        try:
            while True:
                message = await self._receive()
                kind = message["type"]
                if kind == "webtransport.stream.receive":
                    await self._on_stream_data(message)
                elif kind == "webtransport.datagram.receive":
                    self._offer_datagram(message.get("data") or b"")
                elif kind == "webtransport.stream.opened":
                    _put_nowait(self._opened, self._register_opened(message))
                elif kind == "webtransport.disconnect":
                    self.closed = True
                    self.close_code = message.get("code", 0)
                    self.close_reason = message.get("reason", "")
                    self._shut_down()
                    return
                else:
                    # An unknown message is a server that knows something this
                    # module does not; ignoring it is what keeps that additive.
                    continue
        except asyncio.CancelledError:
            raise
        except Exception:
            self.closed = True
            self._shut_down()
            raise

    def _register_opened(self, message):
        """Builds the stream object for an open this endpoint asked for.

        It has to happen here, in the pump, rather than in `create_stream()`:
        the peer may answer on that stream before `create_stream()` is
        scheduled again, and the pump would then see data for a stream id it
        knows nothing about and take it for one the peer had opened. Building
        it at `stream.opened` and handing that same object back means there is
        never a second object for the reply to be delivered to.
        """
        stream_id = message["stream"]
        stream = self._streams.get(stream_id)
        if stream is None:
            bidirectional = message.get("bidirectional")
            if bidirectional is None:
                bidirectional = not (stream_id & 0x2)
            stream = WebTransportStream(self, stream_id, bidirectional)
            self._streams[stream_id] = stream
        if not stream.bidirectional:
            # Nothing will ever arrive on a unidirectional stream we opened.
            stream._eof = True
        return stream

    async def _on_stream_data(self, message):
        stream_id = message["stream"]
        stream = self._streams.get(stream_id)
        if stream is None:
            # QUIC puts both facts in the identifier: bit 0 says who opened
            # the stream, bit 1 whether it is unidirectional. Only a stream
            # the *peer* opened is one to announce; an unknown id we opened
            # ourselves is the answer arriving ahead of its `stream.opened`,
            # and belongs to whoever is waiting in `create_stream()`.
            locally_opened = bool(stream_id & 0x1)
            bidirectional = not (stream_id & 0x2)
            stream = WebTransportStream(self, stream_id, bidirectional,
                                        writable=bidirectional or locally_opened)
            self._streams[stream_id] = stream
            if not locally_opened and not self._announce(stream):
                await self._pause_stream(stream)
        data = message.get("data") or b""
        if data:
            self._offer_chunk(stream, data)
        if not message.get("more_data", False):
            self._offer_chunk(stream, _END)
        if (stream._queue.full() or stream._pending) and not stream._paused:
            await self._pause_stream(stream)

    # -- streams -----------------------------------------------------------

    async def create_stream(self, bidirectional=True):
        """Opens a stream and waits for the server to say which one it is."""
        self._require_accepted()
        await self._send({
            "type": "webtransport.stream.open",
            "bidirectional": bool(bidirectional),
        })
        stream = await self._opened.get()
        if stream is _END:
            raise SessionClosed("the session ended before the stream opened")
        return stream

    async def accept_stream(self):
        """The next stream the peer opened, or None once the session ends.

        Reading outlives the session on purpose. What has already arrived is
        still worth having when the peer goes away, and an iterator that ends
        is easier to write against than one that raises.
        """
        self._require_started()
        stream = await self._next(self._incoming)
        await self._release_held()
        return stream

    def _announce(self, stream):
        try:
            self._incoming.put_nowait(stream)
            return True
        except asyncio.QueueFull:
            self._held.append(stream)
            return False

    def _offer_chunk(self, stream, item):
        try:
            stream._queue.put_nowait(item)
        except asyncio.QueueFull:
            stream._pending.append(item)

    def _offer_datagram(self, data):
        if self._datagrams.full():
            try:
                self._datagrams.get_nowait()
            except asyncio.QueueEmpty:
                pass
        _put_nowait(self._datagrams, data)

    async def _pause_stream(self, stream):
        if stream._paused or self.closed:
            return
        stream._paused = True
        await self._raw_send({
            "type": "webtransport.stream.pause",
            "stream": stream.id,
        })

    async def _maybe_resume(self, stream):
        if not stream._paused or self.closed:
            return
        if stream in self._held:
            return
        if stream._queue.qsize() > STREAM_QUEUE // 2 or stream._pending:
            return
        stream._paused = False
        await self._raw_send({
            "type": "webtransport.stream.resume",
            "stream": stream.id,
        })

    async def _release_held(self):
        while self._held and not self._incoming.full():
            stream = self._held.pop(0)
            try:
                self._incoming.put_nowait(stream)
            except asyncio.QueueFull:
                self._held.insert(0, stream)
                return
            await self._maybe_resume(stream)

    async def incoming_streams(self):
        """Async iterator over the streams the peer opens."""
        while True:
            stream = await self.accept_stream()
            if stream is None:
                return
            yield stream

    # -- datagrams ---------------------------------------------------------

    async def send_datagram(self, data):
        """Sends an unreliable datagram. Delivery is not promised."""
        self._require_accepted()
        await self._send({"type": "webtransport.datagram.send",
                          "data": _as_bytes(data)})

    async def receive_datagram(self):
        """The next datagram, or None once the session ends.

        Like `accept_stream()`, this drains what arrived before the session
        ended rather than refusing to look at it.
        """
        self._require_started()
        return await self._next(self._datagrams)

    async def datagrams(self):
        """Async iterator over incoming datagrams."""
        while True:
            data = await self.receive_datagram()
            if data is None:
                return
            yield data

    # -- misc --------------------------------------------------------------

    async def _next(self, queue):
        """One item from a receive queue, or None once nothing more can come.

        The emptiness check is not an optimisation. `_shut_down()` drops its
        sentinel when a queue is already full -- one more item would not fit --
        so after draining a full queue there may be nothing left to wake a
        reader with, and only the session state says the session is over.
        """
        if queue.empty() and self.closed:
            return None
        item = await queue.get()
        return None if item is _END else item

    def _require_started(self):
        """For the receiving side: the session has to have been accepted, but
        it does not have to still be open."""
        if not self.accepted:
            raise WebTransportError("the session has not been accepted yet")

    def _require_accepted(self):
        """For the sending side, where a closed session really is an error --
        there is nowhere for the bytes to go."""
        self._require_started()
        if self.closed:
            raise SessionClosed("the session has ended")

    async def __aenter__(self):
        await self.accept()
        return self

    async def __aexit__(self, exc_type, exc, tb):
        if not self.closed:
            await self.close()
        else:
            await self._stop()
        return False


def _as_bytes(data, name="data"):
    """Bytes, bytearray, memoryview, or str. Not an int -- `bytes(3)` is
    three NULs, which is never what an application meant."""
    if isinstance(data, (bytes, bytearray, memoryview)):
        return bytes(data)
    if isinstance(data, str):
        return data.encode()
    raise TypeError("%s must be bytes or str, not %s" % (name, type(data).__name__))


def _put_nowait(queue, item):
    try:
        queue.put_nowait(item)
    except asyncio.QueueFull:
        # A full queue already has more than the reader has taken; one more
        # sentinel would not tell it anything it is not about to find out.
        pass
