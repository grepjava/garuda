"""The application for scripts/stale-send-test.py.

/leak answers at once, but first starts a task that keeps the request's `send`
and `receive` and calls them after a delay -- once the response is complete,
when the connection may already be carrying the next request. What those late
calls did is written to $STALE_LOG, one line each, so the test can tell a call
that was ignored from one that reached somebody else's request.

/echo waits, then reads its whole body and sends it back: the request a late
`send` or `receive` could land on. /probe records what `await send()` gives
back. Anything else answers "ok".
"""

import asyncio
import os

# Escaped tasks are kept here so they are not collected before they run.
_tasks = set()


def log(line):
    with open(os.environ["STALE_LOG"], "a") as f:
        f.write(line + "\n")


def delay_of(scope):
    for pair in scope.get("query_string", b"").split(b"&"):
        if pair.startswith(b"delay="):
            return float(pair[6:])
    return 0.0


async def respond(send, body, status=200):
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-length", str(len(body)).encode())]})
    await send({"type": "http.response.body", "body": body})


async def late_calls(send, receive, delay):
    await asyncio.sleep(delay)
    try:
        await send({"type": "http.response.start", "status": 299,
                    "headers": [(b"content-length", b"5")]})
        await send({"type": "http.response.body", "body": b"STALE"})
        log("send returned")
    except Exception as exc:
        log(f"send raised {type(exc).__name__}")
    try:
        message = await asyncio.wait_for(receive(), 0.3)
        log(f"receive {message['type']} {len(message.get('body', b''))}")
    except Exception as exc:
        log(f"receive raised {type(exc).__name__}")


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
    if path == "/leak":
        task = asyncio.get_running_loop().create_task(
            late_calls(send, receive, delay_of(scope)))
        _tasks.add(task)
        task.add_done_callback(_tasks.discard)
        await respond(send, b"leaked")
    elif path == "/echo":
        await asyncio.sleep(delay_of(scope))
        body = b""
        while True:
            message = await receive()
            body += message.get("body", b"")
            if not message.get("more_body"):
                break
        await respond(send, body)
    elif path == "/probe":
        started = await send({"type": "http.response.start", "status": 200,
                              "headers": [(b"content-length", b"2")]})
        iterator = send({"type": "http.response.body", "body": b"ok"}).__await__()
        try:
            next(iterator)
            outcome = "yielded"
        except StopIteration as stop:
            outcome = f"StopIteration({stop.value!r})"
        log(f"probe start={started!r} next={outcome}")
    else:
        await respond(send, b"ok")
