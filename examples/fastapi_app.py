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
