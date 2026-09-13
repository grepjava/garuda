"""Flask application used to check real-framework compatibility (WSGI)."""

import time

from flask import Flask, Response, jsonify, request, stream_with_context

app = Flask(__name__)


@app.get("/")
def root():
    return jsonify(hello="peregrine", multithread=request.environ["wsgi.multithread"])


@app.get("/headers")
def headers():
    return jsonify(
        scheme=request.scheme,
        secure=request.is_secure,
        remote=request.remote_addr,
        ua=request.headers.get("User-Agent"),
    )


@app.post("/echo")
def echo():
    return request.get_data()


@app.get("/stream")
def stream():
    def produce():
        for i in range(5):
            yield "chunk-%d\n" % i

    return Response(stream_with_context(produce()), mimetype="text/plain")


@app.get("/rows")
def rows():
    # Two hundred small blocks: the shape of a CSV export or a report streamed
    # row by row, where the cost per block is what shows.
    def produce():
        row = "x" * 99 + "\n"
        for _ in range(200):
            yield row

    return Response(produce(), mimetype="text/plain")


@app.get("/boom")
def boom():
    raise RuntimeError("intentional failure")


@app.get("/sleep")
def sleep():
    time.sleep(float(request.args.get("s", "0.5")))
    return "slept"


@app.get("/proto")
def proto():
    # SERVER_PROTOCOL is "HTTP/1.1", "HTTP/2" or "HTTP/3": the same view, whatever
    # carried the request.
    return jsonify(http_version=request.environ["SERVER_PROTOCOL"].partition("/")[2])
