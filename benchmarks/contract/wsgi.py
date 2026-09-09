"""Minimal WSGI app for the-benchmarker/web-frameworks contract."""


def application(environ, start_response):
    method = environ["REQUEST_METHOD"]
    path = environ.get("PATH_INFO") or "/"
    if method == "GET" and path == "/":
        body = b""
    elif method == "GET" and path.startswith("/user/"):
        body = path.rsplit("/", 1)[-1].encode()
    elif method == "POST" and path == "/user":
        length = int(environ.get("CONTENT_LENGTH") or 0)
        if length:
            environ["wsgi.input"].read(length)
        body = b""
    else:
        start_response("404 Not Found", [("Content-Length", "0")])
        return [b""]
    start_response("200 OK", [("Content-Length", str(len(body)))])
    return [body]
