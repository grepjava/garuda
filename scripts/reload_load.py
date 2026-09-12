#!/usr/bin/env python3
"""Short-lived connections against a server, counted by how they ended.

Used by reload-test.sh to answer one question: does a reload cost a client
anything? Every request opens its own connection and closes it, because the
thing a reload can break is the accept path, and a keep-alive client stops
exercising it after the first request.

    reload_load.py HOST PORT SECONDS THREADS

Writes a JSON summary to stdout:

    {"ok": 41231, "refused": 0, "reset": 0, "timeout": 0,
     "truncated": 0, "other": {}, "pids": {"1234": 10300, ...}}

`pids` counts responses by the worker that served them, which is what shows
the reload actually replaced anything.
"""

import json
import socket
import sys
import threading
import time

REQUEST = (b"GET /pid HTTP/1.1\r\n"
           b"Host: localhost\r\n"
           b"Connection: close\r\n"
           b"\r\n")


class Counts:
    def __init__(self):
        self.lock = threading.Lock()
        self.ok = 0
        self.refused = 0
        self.reset = 0
        self.timeout = 0
        self.truncated = 0
        self.other = {}
        self.pids = {}
        # Latencies matter as much as failures here: a handover that loses
        # nothing but stalls every connection for the length of an interpreter
        # boot is still an outage, it just does not show up as an error.
        self.latencies = []

    def record_ok(self, pid, seconds):
        with self.lock:
            self.ok += 1
            self.pids[pid] = self.pids.get(pid, 0) + 1
            self.latencies.append(seconds)

    def record(self, field):
        with self.lock:
            setattr(self, field, getattr(self, field) + 1)

    def record_other(self, name):
        with self.lock:
            self.other[name] = self.other.get(name, 0) + 1


def one_request(host, port):
    """Returns the serving worker pid, or raises."""
    sock = socket.create_connection((host, port), timeout=5)
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.sendall(REQUEST)
        chunks = []
        while True:
            block = sock.recv(65536)
            if not block:
                break
            chunks.append(block)
    finally:
        sock.close()

    raw = b"".join(chunks)
    head, sep, body = raw.partition(b"\r\n\r\n")
    if not sep or not head.startswith(b"HTTP/1.1 200"):
        raise ValueError("truncated")
    return body.decode().strip()


def hammer(host, port, deadline, counts):
    while time.monotonic() < deadline:
        started = time.monotonic()
        try:
            counts.record_ok(one_request(host, port), time.monotonic() - started)
        except ConnectionRefusedError:
            counts.record("refused")
        except ConnectionResetError:
            counts.record("reset")
        except (socket.timeout, TimeoutError):
            counts.record("timeout")
        except ValueError:
            counts.record("truncated")
        except OSError as exc:
            counts.record_other("%s(%s)" % (type(exc).__name__, exc.errno))
        except Exception as exc:  # noqa: BLE001 -- the summary is the report
            counts.record_other(type(exc).__name__)


def main():
    host = sys.argv[1]
    port = int(sys.argv[2])
    seconds = float(sys.argv[3])
    threads = int(sys.argv[4])

    counts = Counts()
    deadline = time.monotonic() + seconds
    workers = [threading.Thread(target=hammer, args=(host, port, deadline, counts))
               for _ in range(threads)]
    for t in workers:
        t.start()
    for t in workers:
        t.join()

    latencies = sorted(counts.latencies)

    def at(quantile):
        if not latencies:
            return 0.0
        index = min(len(latencies) - 1, int(len(latencies) * quantile))
        return round(latencies[index] * 1000, 3)

    json.dump({
        "ok": counts.ok,
        "refused": counts.refused,
        "reset": counts.reset,
        "timeout": counts.timeout,
        "truncated": counts.truncated,
        "other": counts.other,
        "pids": counts.pids,
        "p50_ms": at(0.50),
        "p99_ms": at(0.99),
        "p999_ms": at(0.999),
        "max_ms": round(latencies[-1] * 1000, 3) if latencies else 0.0,
    }, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
