"""A CPU-bound ASGI/WSGI app, for checking that --free-threaded runs in parallel.

Every request burns a fixed amount of pure-Python CPU. Under a GIL the total
throughput is the same however many workers there are; without one it scales
with them, which is the only thing worth measuring here.

/info reports what the interpreter thinks about its own GIL, plus the thread
identity serving the request, so a single request proves the wiring even before
any load is applied.
"""

import json
import os
import sys
import threading

ROUNDS = int(os.environ.get("FT_ROUNDS", "6000"))

startup_ran = False
seen_threads = set()
_lock = threading.Lock()


def burn(rounds):
    total = 0
    for i in range(rounds):
        total = (total * 31 + i * i) % 1000003
    return total


def _info():
    with _lock:
        seen_threads.add(threading.get_ident())
        threads = len(seen_threads)
    gil = getattr(sys, "_is_gil_enabled", None)
    return {
        "pid": os.getpid(),
        "thread": threading.get_ident(),
        "threads_seen_in_process": threads,
        "gil_enabled": gil() if gil else True,
        "free_threaded": bool(getattr(sys, "_is_gil_enabled", None)),
        "startup_ran": startup_ran,
        "version": sys.version,
    }


# --- ASGI -------------------------------------------------------------------

async def app(scope, receive, send):
    global startup_ran

    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                startup_ran = True
                scope["state"]["boot_pid"] = os.getpid()
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return

    path = scope["path"]
    if path == "/info":
        payload = _info()
        payload["lifespan_state_boot_pid"] = scope.get("state", {}).get("boot_pid")
        body = json.dumps(payload).encode()
    elif path == "/burn":
        body = str(burn(ROUNDS)).encode()
    else:
        body = b"ok"

    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode())],
    })
    await send({"type": "http.response.body", "body": body})


# --- WSGI -------------------------------------------------------------------

def application(environ, start_response):
    path = environ.get("PATH_INFO", "/")
    if path == "/info":
        payload = _info()
        payload["wsgi.multithread"] = environ["wsgi.multithread"]
        payload["wsgi.multiprocess"] = environ["wsgi.multiprocess"]
        body = json.dumps(payload).encode()
    elif path == "/burn":
        body = str(burn(ROUNDS)).encode()
    else:
        body = b"ok"
    start_response("200 OK", [("Content-Type", "application/json"),
                              ("Content-Length", str(len(body)))])
    return [body]
