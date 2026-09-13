"""The application for scripts/eager-start-test.py.

/n/<tag> answers with its tag without ever waiting, so it finishes inside the
call that starts it. /big/<tag> does the same with a 200 KiB body, large enough
to be written out before the application returns. /sleep/<tag> waits once
first. /how says whether the request started eagerly and whether it had a
current task while it ran. /set-factory and /clear-factory install and remove
a task factory on the loop. /echo reads its whole body and sends it back.
/raise fails before answering and /raise-mid after the response has started.
"""

import asyncio
import sys

BIG = 200_000


async def respond(send, body, status=200):
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-length", str(len(body)).encode())]})
    await send({"type": "http.response.body", "body": body})


def started_eagerly():
    # Started eagerly, the application runs inside the glue that created its
    # task; scheduled, it runs from the event loop instead.
    frame = sys._getframe(1)
    while frame is not None:
        if frame.f_code.co_name == "spawn_request":
            return True
        frame = frame.f_back
    return False


async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return

    path = scope["path"]
    if path.startswith("/n/"):
        await respond(send, path[3:].encode())
    elif path.startswith("/big/"):
        tag = path[5:].encode()
        await respond(send, tag + b"." * (BIG - len(tag)))
    elif path.startswith("/sleep/"):
        await asyncio.sleep(0)
        await respond(send, path[7:].encode())
    elif path == "/how":
        how = "eager" if started_eagerly() else "scheduled"
        task = asyncio.current_task() is not None
        await respond(send, f"{how} task={task}".encode())
    elif path == "/set-factory":
        asyncio.get_running_loop().set_task_factory(
            lambda loop, coro, **kw: asyncio.Task(coro, loop=loop, **kw))
        await respond(send, b"set")
    elif path == "/clear-factory":
        asyncio.get_running_loop().set_task_factory(None)
        await respond(send, b"cleared")
    elif path == "/echo":
        body = b""
        while True:
            message = await receive()
            body += message.get("body", b"")
            if not message.get("more_body"):
                break
        await respond(send, body)
    elif path == "/raise":
        raise ValueError("deliberate failure before the response")
    elif path == "/raise-mid":
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-length", b"5")]})
        raise ValueError("deliberate failure mid-response")
    else:
        await respond(send, b"ok")
