"""What the asyncio side of an ASGI request costs, in-process, with no server.

    python benchmarks/asgi_overhead.py            # asyncio and, if installed, uvloop
    python benchmarks/asgi_overhead.py --requests 50000 --reps 5

Sizes the parts of Garuda's per-request path that live in Python, before
anything is changed in the server:

  floor      the application coroutine stepped by hand, no task at all
  today      loop.create_task via a Python helper, a Python done callback
             that formats nothing unless the task failed -- what Garuda
             does now (Interpreter.swift spawn and task_error)
  no-helper  the same task, created and given its callback without the helper
  no-frame   no helper, and the done callback is Task.exception itself, a C
             call with no Python frame

and, for the record, what building an ASGI scope costs in C-level calls: a
dict copy and a header list for 3 and for 15 headers.

What it cannot size is the difference between Garuda's own C awaitable
raising StopIteration and completing without one; that is measured end to end
with benchmarks/turbo_ab.sh. Every figure is microseconds per request, the
median and interquartile range over the repetitions.
"""

import argparse
import asyncio
import statistics
import sys
import sysconfig
import time
import traceback

START = {"type": "http.response.start", "status": 200,
         "headers": [(b"content-length", b"0")]}
BODY = {"type": "http.response.body", "body": b""}


def spawn(loop, coro, done_cb):
    task = loop.create_task(coro)
    task.add_done_callback(done_cb)
    return task


def task_error(task):
    if task.cancelled():
        return None
    exc = task.exception()
    if exc is None:
        return None
    return "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))


def make_app(done):
    async def app(scope, receive, send):
        await send(START)
        await send(BODY)
    return app


def run_variant(new_loop, variant, requests, batch):
    loop = new_loop()
    asyncio.set_event_loop(loop)
    completed = loop.create_future()
    completed.set_result(None)
    send = lambda message: completed  # an awaitable that is already done
    receive = lambda: completed
    scope = {"type": "http", "method": "GET", "path": "/"}
    app = make_app(completed)
    remaining = requests
    finished = [0]

    def on_done(task):
        task_error(task)
        finished[0] += 1
        if finished[0] == requests:
            loop.stop()

    def count(task):
        finished[0] += 1
        if finished[0] == requests:
            loop.stop()

    exception = asyncio.Task.exception
    create_task = loop.create_task

    def tick():
        nonlocal remaining
        n = min(batch, remaining)
        remaining -= n
        if variant == "floor":
            for _ in range(n):
                coro = app(scope, receive, send)
                try:
                    coro.send(None)
                except StopIteration:
                    pass
            if remaining == 0:
                loop.stop()
        elif variant == "today":
            for _ in range(n):
                spawn(loop, app(scope, receive, send), on_done)
        elif variant == "no-helper":
            for _ in range(n):
                create_task(app(scope, receive, send)).add_done_callback(on_done)
        else:  # no-frame
            for i in range(n):
                task = create_task(app(scope, receive, send))
                task.add_done_callback(exception)
                if remaining == 0 and i == n - 1:
                    task.add_done_callback(lambda t: loop.stop())
        if remaining:
            loop.call_soon(tick)

    begin = time.perf_counter_ns()
    loop.call_soon(tick)
    loop.run_forever()
    elapsed = time.perf_counter_ns() - begin
    loop.close()
    return elapsed / 1000.0 / requests


def scope_cost(headers, requests):
    proto = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
             "scheme": "http", "root_path": "", "server": ("127.0.0.1", 8000)}
    names = [b"host", b"user-agent", b"accept", b"accept-encoding", b"accept-language",
             b"connection", b"cookie", b"referer", b"cache-control", b"x-request-id",
             b"x-forwarded-for", b"sec-fetch-mode", b"sec-fetch-site", b"dnt",
             b"upgrade-insecure-requests"][:headers]
    raw = [memoryview(b"a-typical-header-value/1.0") for _ in names]
    begin = time.perf_counter_ns()
    for _ in range(requests):
        scope = proto.copy()
        scope["method"] = "GET"
        scope["path"] = "/"
        scope["raw_path"] = bytes(raw[0])
        scope["headers"] = list(zip(names, map(bytes, raw)))
    return (time.perf_counter_ns() - begin) / 1000.0 / requests


def summarise(samples):
    q = statistics.quantiles(samples, n=4) if len(samples) > 1 else [samples[0]] * 3
    return f"{statistics.median(samples):7.2f}  [{q[0]:.2f}–{q[2]:.2f}]"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--requests", type=int, default=100_000)
    parser.add_argument("--reps", type=int, default=7)
    parser.add_argument("--batches", default="1,16")
    args = parser.parse_args()

    loops = [("asyncio", asyncio.new_event_loop)]
    try:
        import uvloop
        loops.append(("uvloop", uvloop.new_event_loop))
    except ImportError:
        pass

    ft = "t" if sysconfig.get_config_var("Py_GIL_DISABLED") else ""
    print(f"python {sys.version.split()[0]}{ft}, {args.requests} requests x {args.reps} reps,"
          " microseconds per request, median [interquartile range]")
    variants = ["floor", "today", "no-helper", "no-frame"]
    for batch in [int(b) for b in args.batches.split(",")]:
        for name, new_loop in loops:
            print(f"\n{name}, {batch} request(s) started per loop iteration")
            results = {v: [] for v in variants}
            for _ in range(args.reps):
                for v in variants:  # interleaved, so drift hits every variant alike
                    results[v].append(run_variant(new_loop, v, args.requests, batch))
            for v in variants:
                print(f"  {v:10s} {summarise(results[v])}")
            today = statistics.median(results["today"])
            for v in ("no-helper", "no-frame"):
                print(f"  today - {v:10s} {today - statistics.median(results[v]):+.2f}")
            print(f"  task machinery (today - floor) {today - statistics.median(results['floor']):+.2f}")

    print("\nscope: dict copy + header list, C-level calls")
    for headers in (3, 15):
        samples = [scope_cost(headers, args.requests) for _ in range(args.reps)]
        print(f"  {headers:2d} headers  {summarise(samples)}")


if __name__ == "__main__":
    main()
