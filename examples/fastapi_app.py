"""FastAPI + Starlette application used to check real-framework compatibility."""

import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
from starlette.websockets import WebSocket

STATE = {}


@asynccontextmanager
async def lifespan(app):
    STATE["started"] = True
    yield
    STATE["stopped"] = True
    marker = os.environ.get("PEREGRINE_SHUTDOWN_MARKER")
    if marker:
        with open(marker, "w") as fh:
            fh.write("clean\n")


app = FastAPI(lifespan=lifespan)


@app.get("/")
def root():
    return {"hello": "peregrine", "started": STATE.get("started", False)}


@app.get("/headers")
def headers(request: Request):
    return {
        "scheme": request.url.scheme,
        "client": request.client.host if request.client else None,
        "ua": request.headers.get("user-agent"),
    }


@app.post("/echo")
async def echo(request: Request):
    body = await request.body()
    return {"len": len(body), "head": body[:16].decode(errors="replace")}


@app.get("/stream")
def stream():
    def produce():
        for i in range(5):
            yield b"chunk-%d\n" % i

    return StreamingResponse(produce(), media_type="text/plain")


@app.get("/boom")
def boom():
    raise RuntimeError("intentional failure")


@app.websocket("/ws")
async def ws(socket: WebSocket):
    await socket.accept()
    try:
        while True:
            message = await socket.receive_text()
            await socket.send_text("echo:" + message)
    except Exception:
        return


@app.get("/proto")
def proto(request: Request):
    from peregrine.contrib.fastapi import http_version, supports_webtransport
    return {
        "http_version": http_version(request),
        "webtransport": supports_webtransport(request),
    }


# --- WebTransport -----------------------------------------------------------
#
# Starlette's router asserts on the scope type, so a WebTransport session has
# to be answered before the framework sees it. `wt` is the application to
# serve; everything that is not a session goes to `app` unchanged.

from peregrine.contrib.fastapi import (  # noqa: E402
    WebTransportEndpoint, WebTransportRouter,
)

wt = WebTransportRouter(app)


@wt.route("/wt/echo")
async def wt_echo(session):
    await session.accept()
    async for stream in session.incoming_streams():
        body = await stream.read()
        if stream.bidirectional:
            await stream.send(b"echo:" + body, end=True)
        else:
            reply = await session.create_stream(bidirectional=False)
            await reply.send(b"echo:" + body, end=True)


@wt.route("/wt/room/{name}")
async def wt_room(session):
    await session.accept()
    name = session.path_params["name"].encode()
    stream = await session.create_stream(bidirectional=False)
    await stream.send(b"welcome to " + name, end=True)
    async for _ in session.incoming_streams():
        pass


class WTChat(WebTransportEndpoint):
    """The class-based form, and the only endpoint here doing datagrams."""

    async def on_stream(self, stream):
        await stream.send(b"chat:" + await stream.read(), end=True)

    async def on_datagram(self, data):
        await self.session.send_datagram(b"chat:" + data)


wt.add_route("/wt/chat", WTChat)


@wt.route("/wt/reject")
async def wt_reject(session):
    await session.close(code=403)
