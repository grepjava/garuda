"""A small WSGI application used to exercise the server."""

import os
import threading
import time


def application(environ, start_response):
    path = environ["PATH_INFO"]

    if path == "/":
        body = b"hello from peregrine\n"
        start_response("200 OK", [("Content-Type", "text/plain; charset=utf-8")])
        return [body]

    if path == "/echo":
        # read() with no argument works for both Content-Length and chunked
        # bodies, because the server frames the body before calling us.
        body = environ["wsgi.input"].read()
        start_response("200 OK", [("Content-Type", "application/octet-stream")])
        return [body]

    if path == "/pid":
        start_response("200 OK", [("Content-Type", "text/plain")])
        return [str(os.getpid()).encode()]

    if path == "/environ":
        # The two flags PEP 3333 defines for the execution model, which
        # --workers and --free-threaded answer the opposite way round.
        text = "multithread=%s multiprocess=%s thread=%s\n" % (
            environ["wsgi.multithread"], environ["wsgi.multiprocess"],
            threading.get_ident())
        start_response("200 OK", [("Content-Type", "text/plain")])
        return [text.encode()]

    if path == "/env":
        keys = sorted(k for k in environ if k.startswith("HTTP_") or k in
                      ("REQUEST_METHOD", "PATH_INFO", "QUERY_STRING",
                       "SERVER_PROTOCOL", "SERVER_NAME", "SERVER_PORT",
                       "REMOTE_ADDR", "CONTENT_TYPE", "CONTENT_LENGTH",
                       "SCRIPT_NAME", "wsgi.url_scheme"))
        text = "\n".join(f"{k}={environ[k]!r}" for k in keys) + "\n"
        body = text.encode()
        start_response("200 OK", [("Content-Type", "text/plain")])
        return [body]

    if path == "/client":
        # What the application believes about the caller, which is what
        # forwarded-header handling has to get right.
        text = "%s %s %s\n" % (environ["wsgi.url_scheme"],
                               environ.get("REMOTE_ADDR", ""),
                               environ.get("wsgi.multithread"))
        start_response("200 OK", [("Content-Type", "text/plain")])
        return [text.encode()]

    if path == "/listpairs":
        # PEP 3333 says a list of tuples; a list of two-item lists is what
        # several frameworks actually build.
        start_response("200 OK", [["Content-Type", "text/plain"],
                                  ["X-Shape", "list"]])
        return [b"list pairs\n"]

    if path == "/sleep":
        # Blocking, on purpose: this is the shape of a request waiting on a
        # database, and the only thing a thread pool helps with.
        time.sleep(float(environ.get("QUERY_STRING") or 0.25))
        start_response("200 OK", [("Content-Type", "text/plain")])
        return [b"slept\n"]

    if path == "/stream":
        start_response("200 OK", [("Content-Type", "text/plain")])
        return (b"chunk-%d\n" % i for i in range(5))

    if path == "/firehose":
        n = int(environ.get("QUERY_STRING") or 64 * 1024 * 1024)
        block = b"x" * 65536
        start_response("200 OK", [("Content-Type", "application/octet-stream"),
                                  ("Content-Length", str(n))])

        def produce():
            sent = 0
            while sent < n:
                take = min(len(block), n - sent)
                sent += take
                yield block[:take]

        return produce()

    if path == "/big":
        n = int(environ.get("QUERY_STRING") or 100000)
        start_response("200 OK", [("Content-Type", "application/octet-stream")])
        return [b"x" * n]

    if path == "/headers":
        start_response("200 OK", [
            ("Content-Type", "text/plain"),
            ("X-One", "1"),
            ("X-Two", "2"),
        ])
        return [b"ok\n"]

    if path == "/boom":
        raise RuntimeError("intentional failure")

    if path == "/write":
        write = start_response("200 OK", [("Content-Type", "text/plain")])
        write(b"written ")
        return [b"and returned\n"]

    if path == "/slowwrite":
        # PEP 3333 says a written block goes out before write() returns, so the
        # first line has to reach the client during the sleep, not after it.
        write = start_response("200 OK", [("Content-Type", "text/plain")])
        write(b"first\n")
        time.sleep(float(environ.get("QUERY_STRING") or 1.0))
        write(b"second\n")
        return []

    if path == "/bigwrite":
        # A block far larger than the write buffer, then a pause. Anything the
        # server has not sent by the time the pause starts cannot move until it
        # ends -- on the inline path the application is holding the loop thread
        # -- so this is how a stranded remainder becomes visible.
        write = start_response("200 OK",
                               [("Content-Type", "application/octet-stream")])
        write(b"x" * (8 * 1024 * 1024))
        time.sleep(float(environ.get("QUERY_STRING") or 1.0))
        write(b"TAIL")
        return []

    if path == "/slowstream":
        # The same question for the ordinary iterable path: a block is due
        # before the next one is asked for.
        start_response("200 OK", [("Content-Type", "text/plain")])
        delay = float(environ.get("QUERY_STRING") or 1.0)

        def produce():
            yield b"first\n"
            time.sleep(delay)
            yield b"second\n"

        return produce()

    start_response("404 Not Found", [("Content-Type", "text/plain")])
    return [b"not found\n"]


def make_application():
    """A factory, for --factory."""
    return application
