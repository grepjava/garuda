"""An ASGI application that takes a while to import, for scripts/drain-test.sh.

A worker spends that time between fork and polling its signal pipe, which is
where a signal used to be lost: the supervisor's pipe was already closed and
the worker's own did not exist yet.
"""

import time

time.sleep(1.5)


async def app(scope, receive, send):
    if scope["type"] != "http":
        return
    await send({"type": "http.response.start", "status": 200, "headers": []})
    await send({"type": "http.response.body", "body": b"slow to start\n"})
