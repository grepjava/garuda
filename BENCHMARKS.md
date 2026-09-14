<p align="center">
  <img src="assets/garuda-fiery-roaring.png" alt="garuda" width="480">
</p>

# Benchmarks

Six Garuda entries of
[the-benchmarker/web-frameworks](https://web-frameworks-benchmark.netlify.app/)
and Elysia on Bun, measured with that suite's load command, its applications
and a worker per CPU, at 64, 256 and 512 connections. The machine is not the
suite's, so the figures here are **not** comparable with the ones the site
publishes; see [Relation to the published results](#relation-to-the-published-results).

Measured in one session on 2026-09-14, on Garuda at b8d6ae9: 1.1.4 and every
fix since, the build 1.1.5 would ship.

- **Every entry answered every request.** No run returned an error, a timeout
  or a non-2xx response, at any level.
- **Raw WSGI is the fastest Garuda entry at 64 and 256 connections**,
  293,025 and 302,417 requests a second, against raw ASGI's 221,826 and
  271,396. At 512 the two are 1.4 % apart, inside the run-to-run spread.
- **BlackSheep is the fastest framework**, 179,208–202,141: 2.6–3.1× FastAPI,
  3.9–4.3× Django and 3.6–4.0× Flask on the same server.
- **Elysia on Bun serves 1.2–1.6× raw Garuda** and 1.7–1.9× BlackSheep.

---

## Results, 4 workers

Requests per second, the mean of three runs:

| entry | application | 64 | 256 | 512 |
|---|---|---:|---:|---:|
| garuda-wsgi | raw WSGI | **293,025** | **302,417** | 256,660 |
| garuda-asgi | raw ASGI | 221,826 | 271,396 | **260,155** |
| garuda-blacksheep | BlackSheep 2.6.3 | 179,208 | 202,141 | 197,687 |
| garuda-fastapi | FastAPI 0.141.1 | 57,553 | 72,306 | 76,818 |
| garuda-flask | Flask 3.1.3 | 49,933 | 50,423 | 50,964 |
| garuda-django | Django 6.1.1 | 46,058 | 47,806 | 45,806 |
| elysia-bun, reference | Elysia 1.4.30 on Bun 1.4.2 | 346,465 | 350,622 | 356,547 |

Latency, p50 / p99, in milliseconds, the mean of three runs:

| entry | 64 | 256 | 512 |
|---|---:|---:|---:|
| garuda-wsgi | 87 / 1,538 | 47 / 1,233 | 226 / 1,875 |
| garuda-asgi | 329 / 2,734 | 224 / 1,896 | 180 / 1,851 |
| garuda-blacksheep | 698 / 4,225 | 498 / 3,043 | 624 / 3,225 |
| garuda-fastapi | 2,772 / 8,075 | 2,619 / 7,256 | 2,448 / 6,954 |
| garuda-flask | 3,324 / 8,739 | 3,224 / 8,391 | 3,274 / 8,421 |
| garuda-django | 3,407 / 8,903 | 3,377 / 8,589 | 3,356 / 8,682 |
| elysia-bun, reference | 38 / 1,084 | 15 / 772 | 14 / 884 |

The three runs behind each figure, in requests per second:

| entry | 64 | 256 | 512 |
|---|---|---|---|
| garuda-wsgi | 288,003 · 291,107 · 299,966 | 280,747 · 315,792 · 310,711 | 207,911 · 284,829 · 277,240 |
| garuda-asgi | 203,659 · 235,354 · 226,465 | 286,103 · 271,192 · 256,894 | 240,507 · 254,042 · 285,916 |
| garuda-blacksheep | 188,493 · 174,349 · 174,781 | 205,982 · 196,186 · 204,256 | 194,230 · 193,920 · 204,910 |
| garuda-fastapi | 51,953 · 58,053 · 62,652 | 65,900 · 72,505 · 78,512 | 76,863 · 77,457 · 76,134 |
| garuda-flask | 50,075 · 49,084 · 50,639 | 48,893 · 51,603 · 50,774 | 49,881 · 51,867 · 51,145 |
| garuda-django | 45,022 · 48,251 · 44,901 | 47,846 · 45,924 · 49,647 | 46,053 · 46,048 · 45,316 |
| elysia-bun, reference | 343,970 · 343,530 · 351,895 | 353,516 · 369,948 · 328,402 | 362,111 · 357,651 · 349,879 |

- **Runs vary, the raw entries most.** Raw WSGI at 512 connections ranges from
  207,911 to 284,829, raw ASGI at 64 from 203,659 to 235,354, and FastAPI at
  256 from 65,900 to 78,512. Every other cell stays within 13 %. The load
  generator shares the four CPUs with the server, which likely matters most
  for the entries that answer the most. Differences of 10 % or less between
  the raw entries, or between levels, are inside that spread.
- **Latency measures how far behind the ramp a server falls, not a request's
  round trip.** The ramp offers requests faster than every entry here can
  answer them by the end of each run, and zrk counts the time a request waited
  to be sent. A p50 of seconds means the queue grew for most of the run; tens
  of milliseconds, that the server kept up until late. Compare the entries with
  each other, not with a closed-loop benchmark.
- **Flask and Django are within 12 % of each other**, and both are limited by
  the framework, not the server: the raw WSGI entry on the same server is
  5.0–6.4× either.

---

## Method

The load command, the applications and the server command are the suite's own,
from [the-benchmarker/web-frameworks](https://github.com/the-benchmarker/web-frameworks)
on `develop`: the load command at
[4bb9eaa](https://github.com/the-benchmarker/web-frameworks/blob/4bb9eaa/.tasks/config.rake#L149)
(2026-09-13), the applications at 3795a31 (2026-09-14). The machine, the
Python patch release and where the load generator runs are not, and every
difference is listed below.

| | |
|---|---|
| Load generator | [zrk](https://github.com/zoxy-io/zrk) 2.5.0, two threads |
| Warm-up | `zrk -c 50 -d 5s --plain URL` |
| Each level | `zrk --plain -c N -d 15s -m GET --format json -R1000:500000 --interval 1s --timeout 8s --latency URL` |
| Levels | 64, 256 and 512 connections, `GET /` |
| Figure | zrk's `achieved_rate`, in requests per second, the mean of three runs |
| Latency | p50 and p99, corrected for coordinated omission, the mean of three runs |
| Server | `python -m garuda --log-level error --protocol X --workers 4 APP`, the suite's `garuda` engine command with `--workers $(nproc)` |
| Applications | the suite's `python/garuda-asgi`, `-wsgi`, `-fastapi` and `-django` entries, and its `python/flask` and `python/blacksheep` sources run the same way, copied unchanged: [benchmarks/web-frameworks/](benchmarks/web-frameworks/) |
| Elysia | the suite's `javascript/elysia-bun`, `cluster.ts` starting one `bun ./app.ts` per CPU: [benchmarks/elysia-bun/](benchmarks/elysia-bun/) |
| Host | WSL2, 4 CPUs of an Intel Core i9-12900KF, 31 GB, Ubuntu 24.04.4, Linux 6.18; load generator on the same machine |
| Python | CPython 3.14.6, not free-threaded; Garuda built from source as the extension module a wheel installs |

Versions: FastAPI 0.141.1 (Starlette 1.6.0, Pydantic 2.13.5), Django 6.1.1,
Flask 3.1.3 (Werkzeug 3.1.8), BlackSheep 2.6.3, uvloop 0.22.1; Elysia 1.4.30
on Bun 1.4.2.

The command is an open-loop ramp from 1,000 to 500,000 requests a second over
the 15 s of a run, with keep-alive on. Upstream raised the end of the ramp from
100,000 at 4bb9eaa. Under the old ramp a run offered at most about 96,500
requests a second, which every raw entry and Elysia reached, so it could not
rank them; the new one offers more than any entry here answers. The comment
above the command in `config.rake` describes `--closed`, a closed loop; the
command does not pass it.

Free-threaded builds were not measured.

**Where this differs from upstream:**

| | upstream, dataset of 2026-09-13 | here |
|---|---|---|
| Host | 16 CPUs, 7.7 GB, Linux 7.1 (Fedora) | WSL2 on 4 CPUs, 31 GB, Ubuntu 24.04.4 |
| Workers | `--workers $(nproc)`, 16 | `--workers $(nproc)`, 4 |
| Load generator | the suite runs each server in a container | same machine as the server, sharing its 4 CPUs |
| Python | 3.14 | 3.14.6 |
| Garuda | `pip install 'garuda-server>=1.0,<1.1'` | built from source at b8d6ae9 |
| Flask and BlackSheep | on their own engines, gunicorn and uvicorn; there is no Garuda entry for either | the suite's sources on Garuda |

### Relation to the published results

The site's dataset of 2026-09-13 09:54 UTC lists Garuda 1.0 under four
entries, measured with the same command on sixteen CPUs. Requests per second at
64 / 256 / 512 connections, beside the entries the same frameworks have on their
default engines:

| site entry | what it runs | 64 | 256 | 512 |
|---|---|---:|---:|---:|
| `garuda-wsgi` | raw WSGI on Garuda 1.0 | 158,062 | 131,645 | 130,843 |
| `garuda-asgi` | raw ASGI on Garuda 1.0 | 128,342 | 107,861 | 105,471 |
| `garuda-fastapi` | FastAPI on Garuda 1.0 | 54,338 | 59,273 | 60,201 |
| `garuda-django` | Django on Garuda 1.0, WSGI | 39,840 | 39,718 | 39,654 |
| `fastapi` | FastAPI on uvicorn | 41,891 | 47,335 | 48,552 |
| `flask` | Flask on gunicorn, sync workers | 5,106 | 12,277 | 5,904 |
| `django` | Django on gunicorn | 1,165 | 5,727 | 4,699 |
| `blacksheep` | BlackSheep on uvicorn | 80,409 | 85,160 | 85,960 |
| `fastpysgi-wsgi` | a raw WSGI application on fastpysgi | 157,810 | 129,789 | 129,033 |
| `elysia-bun` | Elysia on Bun | 162,284 | 132,591 | 127,945 |

Source: [`data.min.json` on `develop`](https://github.com/the-benchmarker/web-frameworks/blob/develop/data.min.json),
the file the site's frontend loads.

None of these can be set beside the tables above. Here four workers answered
up to 302,417 requests a second where sixteen answered 158,062 there, so the
host and the path from load generator to server count for more than the
workers do. On this machine the load generator reaches the server over
loopback, which is likely a large part of it. What the two agree on is the
order where both have entries: raw WSGI leads raw ASGI at 64 and 256
connections, FastAPI leads Django, and in the published set FastAPI and Django
on Garuda 1.0 are ahead of the same frameworks on their default engines.

---

## Reproduce

```bash
PYTHON=~/.local/share/uv/python/cpython-3.14.6-linux-x86_64-gnu/bin/python3 \
    SCRATCH=~/pgbuild-ext-314 bash scripts/build-extension.sh
uv venv ~/wf314-venv --python 3.14
uv pip install --python ~/wf314-venv/bin/python fastapi==0.141.1 django==6.1.1 \
    flask==3.1.3 blacksheep==2.6.3 uvloop==0.22.1
VENV=~/wf314-venv SOURCES=upstream WORKERS=$(nproc) AGG=mean \
    FRAMEWORKS="asgi wsgi fastapi django flask blacksheep elysia" \
    SERVERS="garuda-ext elysia-bun" bash benchmarks/frameworks.sh > results.tsv
```

[benchmarks/frameworks.sh](benchmarks/frameworks.sh) prints one line per entry
and level, with every run. `WORKERS`, `CONNS`, `RUNS`, `AGG`, `RATE`,
`DURATION`, `FRAMEWORKS`, `SERVERS`, `SOURCES`, `VENV`, `ZRK`, `EXT_ROOT`,
`GARUDA_EXTRA_ARGS` and `BUN` override the defaults. The Elysia entry needs
[Bun](https://bun.sh) and port 3000, since the suite's `app.ts` listens there;
the script runs `bun install` the first time.
