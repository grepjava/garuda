#!/usr/bin/env python3
"""Draw the README's throughput chart from a fw-arms.sh log.

    python3 benchmarks/chart.py benchmarks/results/fw-arms-256-2026-09-20.log \
        assets/benchmark-256.svg

The figures are read out of the log rather than typed in, so the picture and
BENCHMARKS.md cannot drift apart. Round 1 is discarded, as the sweep discards
it, and each arm's bar is the median of its remaining rounds -- the same
statistic the table prints. SVG rather than PNG: it is a few kilobytes, the
text stays sharp at any width, and a diff shows what changed.
"""
import re
import sys
from xml.sax.saxutils import escape

# What each arm is called in the picture, and the order is by measurement.
LABELS = {
    "garuda": "Garuda",
    "axum": "axum",
    "ntex": "ntex",
    "vapor": "Vapor",
    "hummingbird": "Hummingbird",
    "elysia-bun": "Elysia on Bun",
    "actix": "actix-web",
    "vertx": "Vert.x",
}
MINE = "garuda"

INK = "#1b1b1b"
MUTED = "#6b7280"
ACCENT = "#c2410c"
OTHER = "#9ca3af"
BG = "#ffffff"


def read(path):
    """Every arm's rounds, in the order the sweep ran them."""
    rounds = {}
    arm = None
    rnd = None
    for line in open(path, encoding="utf-8", errors="replace"):
        head = re.match(r"^===== round (\d+)\s+position \d+\s+arm=(\S+) =====", line)
        if head:
            rnd, arm = int(head.group(1)), head.group(2)
            continue
        if arm is None or not re.match(r"^(swift|rust|elysia|java)\t", line):
            continue
        cell = line.split("\t")
        if len(cell) < 5 or "FAILED" in line:
            continue
        figure = cell[4].split()
        if not figure or not figure[0].isdigit():
            continue
        if rnd == 1:            # the warm-up round the sweep discards
            continue
        rounds.setdefault(arm, []).append(int(figure[0]))
    return rounds


def median(xs):
    xs = sorted(xs)
    mid = len(xs) // 2
    return xs[mid] if len(xs) % 2 else (xs[mid - 1] + xs[mid]) / 2


def draw(rounds, out, conns, workers, date, note):
    bars = sorted(
        ((LABELS.get(a, a), median(v), a, min(v), max(v)) for a, v in rounds.items()),
        key=lambda b: -b[1],
    )
    top = max(b[4] for b in bars)

    pad_l, pad_r = 172, 120
    bar_h, gap = 34, 22
    y0 = 128
    width = 1100
    height = y0 + len(bars) * (bar_h + gap) + 54
    span = width - pad_l - pad_r

    s = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" viewBox="0 0 {width} {height}" '
        f'font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif">',
        f'<rect width="{width}" height="{height}" fill="{BG}"/>',
        f'<text x="40" y="52" font-size="27" font-weight="700" fill="{INK}">'
        f'Requests per second, a worker per CPU, {conns} connections</text>',
        f'<text x="40" y="84" font-size="16" fill="{MUTED}">'
        f'the-benchmarker/web-frameworks applications and load command '
        f'· higher is better · bar is the median round, '
        f'whisker the lowest and highest</text>',
    ]

    y = y0
    for label, value, arm, lo, hi in bars:
        w = max(2, span * value / top)
        x_lo, x_hi = pad_l + span * lo / top, pad_l + span * hi / top
        fill = ACCENT if arm == MINE else OTHER
        weight = "700" if arm == MINE else "400"
        s.append(
            f'<text x="{pad_l - 14}" y="{y + bar_h - 10}" text-anchor="end" '
            f'font-size="17" font-weight="{weight}" fill="{INK}">{escape(label)}</text>'
        )
        s.append(f'<rect x="{pad_l}" y="{y}" width="{w:.1f}" height="{bar_h}" fill="{fill}"/>')
        # Lowest and highest round, so a bar is never read as a single number.
        # Where two of these ranges overlap, the rounds do not separate the two
        # servers and the order of the bars is not a result.
        mid, cap = y + bar_h / 2, 7
        s.append(
            f'<path d="M{x_lo:.1f} {mid - cap} V{mid + cap} M{x_lo:.1f} {mid} '
            f'H{x_hi:.1f} M{x_hi:.1f} {mid - cap} V{mid + cap}" '
            f'stroke="{INK}" stroke-width="1.6" fill="none" opacity="0.55"/>'
        )
        s.append(
            f'<text x="{x_hi + 12:.1f}" y="{y + bar_h - 10}" font-size="17" '
            f'font-weight="{weight}" fill="{INK}">{value:,.0f}</text>'
        )
        y += bar_h + gap

    s.append(
        f'<text x="{width - 40}" y="{height - 20}" text-anchor="end" font-size="14" '
        f'fill="{MUTED}">{escape(note)}</text>'
    )
    s.append("</svg>")
    open(out, "w", encoding="utf-8").write("\n".join(s) + "\n")
    return bars


if __name__ == "__main__":
    log = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "assets/benchmark-256.svg"
    data = read(log)
    if not data:
        sys.exit(f"{log}: no rounds after the discarded first one")
    note = (
        "zrk open-loop ramp to 500,000/s · median of 6 rotated rounds "
        "· 8 CPUs · method in BENCHMARKS.md"
    )
    for name, value, _, lo, hi in draw(data, out, 256, 8, None, note):
        print(f"{name:<16}{value:>10,.0f}   {lo:>9,}  {hi:>9,}   {100 * (hi - lo) / value:4.1f}%")
    print(f"\nwrote {out}")
