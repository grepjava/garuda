#!/usr/bin/env python3
"""Draw the README's capability chart.

    python3 scripts/feature-chart.py assets/features.svg

Unlike benchmarks/chart.py there is no log to read: the list below is the
source, and it is written to match the documentation rather than to sell.
Every line is something that is implemented and tested here, and the muted
line at the foot is what is not, taken from README.md's "Not supported".
Keeping both in one picture is the point -- a capability chart that lists only
what exists tells a reader nothing about where the edges are.

When a feature lands, add it here and regenerate; when one is removed, the
same. The RFC numbers are the ones TRANSPORT.md cites.
"""
import sys
from xml.sax.saxutils import escape

GROUPS = [
    ("Protocols", [
        "HTTP/1.1, HTTP/2, HTTP/3 over QUIC",
        "TLS 1.2 and 1.3, SNI, ALPN",
        "ACME certificates, renewed in place",
        "One worker per CPU, reload with no drops",
    ]),
    ("Real-time", [
        "WebSocket over HTTP/1.1 (RFC 6455),",
        "   HTTP/2 (RFC 8441) and HTTP/3 (RFC 9220)",
        "permessage-deflate (RFC 7692)",
        "WebTransport over HTTP/3",
        "Server-sent events, with Last-Event-ID",
        "Broadcast across workers, with replay",
    ]),
    ("Bodies and files", [
        "Resumable uploads: the IETF protocol",
        "Streamed responses, with backpressure",
        "Streamed request bodies, flow-controlled",
        "Static files, byte ranges, listings",
        "brotli, zstd and gzip, as the client accepts",
        "103 Early Hints and other interim responses",
    ]),
    ("Handlers", [
        "Typed path, query, body, form, multipart",
        "Custom and async extractors, optional",
        "Groups, nested routers, 405 with Allow",
        "Middleware before the handler and on send",
        "Deadlines, cancellation, blocking pool",
        "OpenAPI and Swagger UI from the types",
    ]),
    ("Data", [
        "PostgreSQL driver on the poller",
        "Redis and Valkey: RESP3, cluster, pub/sub",
        "SQLite: WAL, migrations, reader per worker",
        "HTTP client: HTTP/1.1 and HTTP/2, SSE",
    ]),
    ("Security and operations", [
        "JWT and JWKS, sessions, CSRF, CORS",
        "Rate limits, allowed hosts, address filter",
        "Security headers, request IDs, trace context",
        "Access log, OpenTelemetry spans",
        "Prometheus metrics, health check, drain",
    ]),
]

NOT_BUILT_IN = (
    "Not built in: QUIC 0-RTT and session resumption · kernel TLS · "
    "multipart/byteranges · reads from Redis replicas · "
    "Windows outside WSL 2"
)

INK = "#1b1b1b"
MUTED = "#6b7280"
ACCENT = "#c2410c"
BG = "#ffffff"

WIDTH = 1100
COLS = 3
PAD = 40
TOP = 130
LINE = 25
HEAD = 30
GROUP_GAP = 34


def draw(out):
    col_w = (WIDTH - 2 * PAD) // COLS
    rows = [GROUPS[i:i + COLS] for i in range(0, len(GROUPS), COLS)]

    s = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="__H__" '
        f'viewBox="0 0 {WIDTH} __H__" '
        f'font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif">',
        f'<rect width="{WIDTH}" height="__H__" fill="{BG}"/>',
        f'<text x="{PAD}" y="52" font-size="27" font-weight="700" fill="{INK}">'
        f'What Garuda has, and what it has not</text>',
        f'<text x="{PAD}" y="84" font-size="16" fill="{MUTED}">'
        f'every line below is implemented and tested · '
        f'the protocols are in TRANSPORT.md, the rest in the documentation table</text>',
    ]

    y = TOP
    for row in rows:
        for c, (title, items) in enumerate(row):
            x = PAD + c * col_w
            s.append(
                f'<rect x="{x}" y="{y - 15}" width="26" height="3" fill="{ACCENT}"/>'
            )
            s.append(
                f'<text x="{x}" y="{y + 8}" font-size="17" font-weight="700" '
                f'fill="{INK}">{escape(title)}</text>'
            )
            yy = y + HEAD + 4
            for item in items:
                # A line starting with spaces continues the one above it, so a
                # long entry wraps without being read as two features.
                indent = 12 if item.startswith("   ") else 0
                s.append(
                    f'<text x="{x + indent}" y="{yy + 12}" font-size="14.5" '
                    f'fill="{INK}">{escape(item.strip())}</text>'
                )
                yy += LINE
        y += HEAD + 4 + max(len(g[1]) for g in row) * LINE + GROUP_GAP

    height = y + 34
    s.append(
        f'<text x="{PAD}" y="{height - 22}" font-size="14" fill="{MUTED}">'
        f'{escape(NOT_BUILT_IN)}</text>'
    )
    s.append("</svg>")
    svg = "\n".join(s).replace("__H__", str(height)) + "\n"
    open(out, "w", encoding="utf-8").write(svg)
    return height


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "assets/features.svg"
    print(f"wrote {target}, {draw(target)}px tall, "
          f"{sum(len(g[1]) for g in GROUPS)} lines")
