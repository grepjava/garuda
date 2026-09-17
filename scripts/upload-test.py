#!/usr/bin/env python3
"""Streamed request bodies, interim responses and resumable uploads, end to end.

    ~/pgvenv/bin/python scripts/upload-test.py [path-to-garuda-conformance]

Runs .build/release/garuda-conformance with two workers, so an upload resumed
on a new connection may well be resumed by another process than the one that
started it. Needs openssl, h2 and aioquic.
"""

import asyncio
import importlib.util
import os
import shutil
import socket
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("handler_test", os.path.join(HERE, "handler-test.py"))
ht = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ht)

import h2.events  # noqa: E402  (available once handler-test imported cleanly)
from aioquic.h3.events import HeadersReceived, DataReceived  # noqa: E402

import aioquic.h3.connection as h3connection  # noqa: E402

UPLOADS = tempfile.mkdtemp(prefix="garuda-upload-test-")

# aioquic takes a second HEADERS on a response stream for trailers, so an
# interim response ahead of the final one ends the connection with
# H3_MESSAGE_ERROR. RFC 9114 section 4.1 allows any number of them; this
# teaches the client so, rather than leaving HTTP/3 untested.
_handle_frame = h3connection.H3Connection._handle_request_or_push_frame


def _accept_interim(self, frame_type, frame_data, stream, stream_ended):
    events = _handle_frame(self, frame_type, frame_data, stream, stream_ended)
    for event in events:
        if isinstance(event, HeadersReceived) and any(
                name == b":status" and value.startswith(b"1") for name, value in event.headers):
            stream.headers_recv_state = h3connection.HeadersState.INITIAL
    return events


h3connection.H3Connection._handle_request_or_push_frame = _accept_interim


def fnv(data):
    value = 0xcbf29ce484222325
    for byte in data:
        value ^= byte
        value = (value * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return "%d %016x" % (len(data), value)


def payload(n, seed=0):
    return bytes((i * 131 + seed) & 0xFF for i in range(n))


def server(**kwargs):
    return ht.Server("--workers", "2", env={"GARUDA_UPLOAD_DIR": UPLOADS}, **kwargs)


def raw_exchange(sock, request, body=b""):
    """Sends a request and reads every response to it, interim ones included."""
    sock.sendall(request + body)
    conn = ht.H1.__new__(ht.H1)
    conn.sock, conn.buf = sock, b""
    responses = []
    while True:
        r = conn.response("POST")
        responses.append(r)
        if r.status >= 200:
            return responses


def interim_of(conn):
    """Reads responses on `conn` until a final one, returning them all."""
    responses = []
    while True:
        r = conn.response("POST")
        responses.append(r)
        if r.status >= 200:
            return responses


# ------------------------------------------------------------------ HTTP/1.1


def bodies_h1():
    print("\nStreamed request bodies, HTTP/1.1")
    with server() as s:
        conn = ht.H1(s)
        big = payload(8 << 20)
        r = conn.request("POST", "/body-stream", body=big)
        ht.is_("an 8 MiB body is read as it arrives, intact", r.body.decode(), fnv(big))
        r = conn.request("POST", "/body-stream?slow=1", body=big)
        ht.is_("and by a reader that waits between reads", r.body.decode(), fnv(big))

        framed = b"".join(b"%x\r\n%s\r\n" % (len(big[i:i + 100000]), big[i:i + 100000])
                          for i in range(0, len(big), 100000)) + b"0\r\n\r\n"
        conn.send(ht.H1.head("POST", "/body-stream", [("Transfer-Encoding", "chunked")]) + framed)
        ht.is_("a chunked one too", conn.response("POST").body.decode(), fnv(big))
        ht.is_("and the connection is kept", conn.request("GET", "/").status, 200)
        conn.close()

        conn = ht.H1(s)
        conn.send(ht.H1.head("POST", "/interim", length=0))
        responses = interim_of(conn)
        ht.is_("an interim response comes before the final one",
               [r.status for r in responses], [103, 200])
        ht.is_("with its headers", responses[0].header("link"), "</style.css>; rel=preload")
        conn.close()


def uploads_h1():
    print("\nResumable uploads, HTTP/1.1")
    with server() as s:
        whole = payload(3 << 20, 7)

        conn = ht.H1(s)
        conn.send(ht.H1.head("POST", "/files", [("Upload-Complete", "?1"), ("Upload-Draft-Interop-Version", "9")], length=len(whole)) + whole)
        responses = interim_of(conn)
        statuses = [r.status for r in responses]
        ht.check("an upload in one request is told where it lives first",
                 statuses[0] == 104 and responses[0].header("location", ).startswith("/uploads/"),
                 statuses)
        ht.is_("and completes", (responses[-1].status, responses[-1].body.decode()), (201, fnv(whole)))
        ht.is_("saying so", responses[-1].header("upload-complete"), "?1")
        conn.close()

        # Interrupted: half the body, then the connection is gone.
        half = len(whole) // 2
        sock = socket.create_connection(("127.0.0.1", s.port), 10)
        sock.sendall(ht.H1.head("POST", "/files", [("Upload-Complete", "?1"), ("Upload-Draft-Interop-Version", "9")], length=len(whole))
                     + whole[:half])
        conn = ht.H1.__new__(ht.H1)
        conn.sock, conn.buf = sock, b""
        first = conn.response("POST")
        location = first.header("location")
        ht.is_("an interrupted upload had its 104", first.status, 104)
        sock.close()

        # Closing with the progress 104 unread resets the connection, and a
        # reset throws away what the server's kernel still held unread -- flow
        # control leaves it there. So the offset is whatever reached the
        # upload, at most what was sent, and it is where a client resumes.
        offset, previous = None, None
        for _ in range(50):
            probe = ht.H1(s)
            r = probe.request("HEAD", location)
            probe.close()
            offset = r.header("upload-offset")
            if offset is not None and offset == previous:
                break
            previous = offset
            time.sleep(0.2)
        kept = int(offset) if offset and offset.isdigit() else -1
        ht.check("what arrived before the drop is kept, and no more than was sent",
                 0 < kept <= half, (offset, half))
        ht.is_("and it is not complete", r.header("upload-complete"), "?0")
        ht.is_("and its length is remembered", r.header("upload-length"), str(len(whole)))

        stale = ht.H1(s)
        r = stale.request("PATCH", location, [("Content-Type", "application/partial-upload"),
                                              ("Upload-Offset", "0"), ("Upload-Complete", "?0")],
                          whole[:10])
        ht.is_("resuming from the wrong offset is a conflict", r.status, 409)
        ht.is_("which names the right one", r.header("upload-offset"), str(kept))
        stale.close()

        # Resumed on new connections, which two workers may share between them.
        rest = whole[kept:]
        mid = len(rest) // 2
        conn = ht.H1(s)
        r = conn.request("PATCH", location, [("Content-Type", "application/partial-upload"),
                                             ("Upload-Offset", str(kept)), ("Upload-Complete", "?0")],
                         rest[:mid])
        ht.is_("an append that is not the last is 204", (r.status, r.header("upload-offset")),
               (204, str(kept + mid)))
        conn.close()
        conn = ht.H1(s)
        conn.send(ht.H1.head("PATCH", location, [("Content-Type", "application/partial-upload"),
                                                  ("Upload-Offset", str(kept + mid)),
                                                  ("Upload-Complete", "?1"), ("Upload-Draft-Interop-Version", "9")], length=len(rest) - mid)
                  + rest[mid:])
        responses = interim_of(conn)
        final = responses[-1]
        ht.is_("the last append completes the upload with the handler's answer",
               (final.status, final.body.decode()), (201, fnv(whole)))
        ht.is_("and every byte is where it should be", final.header("upload-complete"), "?1")
        conn.close()

        conn = ht.H1(s)
        ht.is_("a finished upload the handler removed is gone", conn.request("HEAD", location).status, 404)
        ht.check("the store is empty afterwards",
                 not [f for f in os.listdir(UPLOADS) if f.endswith(".data")], os.listdir(UPLOADS))
        conn.close()


# ------------------------------------------------------------ HTTP/2, HTTP/3


class H2(ht.H2Client):
    def __init__(self, server):
        super().__init__(server)
        self.informational = {}

    def step(self, timeout=0.2):
        self.sock.settimeout(timeout)
        try:
            data = self.sock.recv(1 << 20)
        except (socket.timeout, TimeoutError, ht.ssl.SSLWantReadError):
            return True
        if not data:
            return False
        for event in self.conn.receive_data(data):
            if isinstance(event, h2.events.InformationalResponseReceived):
                fields = dict(event.headers)
                self.informational.setdefault(event.stream_id, []).append(fields)
            elif isinstance(event, h2.events.ResponseReceived):
                fields = {}
                for name, value in event.headers:
                    fields.setdefault(name, []).append(value)
                self.headers[event.stream_id] = fields
                self.status[event.stream_id] = int(fields[b":status"][0])
            elif isinstance(event, h2.events.DataReceived):
                self.body[event.stream_id] = self.body.get(event.stream_id, b"") + event.data
                self.conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
            elif isinstance(event, h2.events.StreamEnded):
                self.ended.add(event.stream_id)
            elif isinstance(event, h2.events.StreamReset):
                self.ended.add(event.stream_id)
                self.reset[event.stream_id] = event.error_code
        self.flush()
        return True


class H3(ht.H3Client):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.statuses = {}

    def quic_event_received(self, event):
        for http_event in self._http.handle_event(event):
            if isinstance(http_event, HeadersReceived):
                for name, value in http_event.headers:
                    if name == b":status":
                        self.statuses.setdefault(http_event.stream_id, []).append(int(value))
                    if name == b"location":
                        self.headers.setdefault(http_event.stream_id, {})[b"location"] = [value]
            self._deliver(http_event)

    def _deliver(self, http_event):
        stream = http_event.stream_id
        if isinstance(http_event, HeadersReceived):
            fields = self.headers.setdefault(stream, {})
            for name, value in http_event.headers:
                if name == b":status":
                    self.status[stream] = int(value)
                else:
                    fields.setdefault(name, []).append(value)
        elif isinstance(http_event, DataReceived):
            self.body[stream] = self.body.get(stream, b"") + http_event.data
        if getattr(http_event, "stream_ended", False):
            done = self._done.get(stream)
            if done is not None and not done.done():
                done.set_result(None)


def streams():
    print("\nStreamed bodies, interim responses and uploads, HTTP/2 and HTTP/3")
    with server(http3=True) as s:
        big = payload(4 << 20, 3)
        client = H2(s)
        body = client.request("POST", "/body-stream?slow=1", body=big)
        interim = client.request("POST", "/interim", body=b"")
        whole = payload(1 << 20, 9)
        upload = client.request("POST", "/files", [("upload-complete", "?1"), ("upload-draft-interop-version", "9")], body=whole)
        client.collect([body, interim, upload], deadline=60)
        ht.is_("over HTTP/2 a body larger than the window is read as it arrives",
               client.body.get(body, b"").decode(), fnv(big))
        ht.is_("an interim response arrives as one",
               [f.get(b":status") for f in client.informational.get(interim, [])], [b"103"])
        ht.is_("an upload is told where it lives",
               [f.get(b":status") for f in client.informational.get(upload, [])][:1], [b"104"])
        ht.is_("and completes", (client.status.get(upload), client.body.get(upload, b"").decode()),
               (201, fnv(whole)))

        # A handler that has not read yet holds the client to one window: what
        # arrived is not acknowledged as read until it is.
        held = client.open("POST", "/body-stream?hold=1", length=len(big))
        sent, deadline = 0, time.monotonic() + 1.0
        while time.monotonic() < deadline and sent < len(big):
            window = min(client.conn.local_flow_control_window(held), client.conn.max_outbound_frame_size)
            if window <= 0:
                client.step(0.05)
                continue
            n = min(window, len(big) - sent)
            client.conn.send_data(held, big[sent:sent + n])
            client.flush()
            sent += n
        limited = client.request("POST", "/body-limited", body=payload(4096, 1))
        client.collect([limited], deadline=20)
        # Answered 413, as on the other two, and the stream then reset with
        # NO_ERROR so the client stops sending.
        ht.is_("over HTTP/2 a route's own body limit applies",
               client.status.get(limited), 413)
        ht.check("over HTTP/2 a body nobody has read yet holds the client to a window",
                 sent <= 1 << 20, sent)
        client.send_body(held, big[sent:], end_stream=True)
        client.collect([held], deadline=60)
        ht.is_("and once read, all of it arrives", client.body.get(held, b"").decode(), fnv(big))
        client.close()

        async def h3_scenario():
            config = ht.QuicConfiguration(is_client=True, alpn_protocols=["h3"])
            config.verify_mode = ht.ssl.CERT_NONE
            async with ht.connect("127.0.0.1", s.port, configuration=config, create_protocol=H3) as h3:
                body = h3.request("POST", "/body-stream", body=big)
                interim = h3.request("POST", "/interim", body=b"")
                await h3.collect([body, interim], timeout=60)
                ht.is_("over HTTP/3 a large body is read as it arrives",
                       h3.body.get(body, b"").decode(), fnv(big))
                ht.is_("an interim response arrives before the final one",
                       h3.statuses.get(interim), [103, 200])

                limited = h3.request("POST", "/body-limited", body=payload(4096, 1))
                await h3.collect([limited], timeout=20)
                ht.is_("over HTTP/3 a route's own body limit applies", h3.status.get(limited), 413)

                held = h3.request("POST", "/body-stream?hold=1", body=big)
                await asyncio.sleep(1.0)
                granted = h3._quic._streams[held].max_stream_data_remote
                ht.check("over HTTP/3 a body nobody has read yet holds the client to a window",
                         granted <= 1 << 20, granted)
                await h3.collect([held], timeout=60)
                ht.is_("and once read, all of it arrives", h3.body.get(held, b"").decode(), fnv(big))

                # Interrupted by a reset, then finished with PATCH.
                half = len(whole) // 2
                stream = h3.open("POST", "/files", [("upload-complete", "?1"), ("upload-draft-interop-version", "9")], length=len(whole))
                h3.send(stream, whole[:half])
                for _ in range(100):
                    if h3.statuses.get(stream):
                        break
                    await asyncio.sleep(0.05)
                location = h3.headers.get(stream, {}).get(b"location", [b""])[0].decode()
                ht.is_("an upload over HTTP/3 has its 104", h3.statuses.get(stream, [])[:1], [104])
                await asyncio.sleep(0.3)
                h3._quic.reset_stream(stream, 0x10c)
                h3.transmit()
                offset = None
                for _ in range(50):
                    probe = h3.request("HEAD", location)
                    await h3.collect([probe])
                    offset = (h3.headers.get(probe, {}).get(b"upload-offset") or [b""])[-1]
                    if offset == str(half).encode():
                        break
                    await asyncio.sleep(0.1)
                ht.is_("a reset stream keeps what arrived", offset, str(half).encode())
                rest = h3.request("PATCH", location, [("content-type", "application/partial-upload"),
                                                      ("upload-offset", str(half)),
                                                      ("upload-complete", "?1")], whole[half:])
                await h3.collect([rest], timeout=30)
                ht.is_("and the rest completes it", (h3.status.get(rest), h3.body.get(rest, b"").decode()),
                       (201, fnv(whole)))

        ht.run(h3_scenario())


def main():
    if not os.path.exists(ht.BIN):
        print("no such binary: %s" % ht.BIN)
        return 2
    try:
        for section in (bodies_h1, uploads_h1, streams):
            try:
                section()
            except Exception as exc:  # noqa: BLE001
                ht.bad("%s ran to the end" % section.__name__, "no exception", repr(exc))
    finally:
        shutil.rmtree(UPLOADS, ignore_errors=True)
    print("\npassed: %d   failed: %d" % (ht.PASS, ht.FAIL))
    return 0 if ht.FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
