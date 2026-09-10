# Benchmarks

These numbers are from one machine, one load generator and six hello-world
apps. They answer a narrow question: **does `--free-threaded` raise request
throughput on the the-benchmarker contract?** On this box, no — worker
processes still win for the frameworks, and threads only tie on raw ASGI.

A different question — CPU-bound Python, and resident memory — is answered
under [Free-threaded Python](CONFIG.md#free-threaded-python). There, four
threads match four processes at a third of the RSS, because the application
is imported once. That is what `--free-threaded` is for. This file is the
hello-world side of the same comparison.

---

## Method

| | |
|---|---|
| Host | WSL2, 4 cores |
| Load | `oha` closed-loop `GET /`, 15 s per cell |
| Columns | concurrent **connections** (64 / 256 / 512), not a fixed request rate |
| Warm-up | 3 s at 64 connections before the first cell |
| Apps | [benchmarks/contract/](benchmarks/contract/) — the-benchmarker routes, empty `GET /` |

Two binaries, because a free-threaded CPython is a different ABI:

| | Binary | Interpreter | Workers |
|---|---|---|---|
| **GIL** | `~/pgbuild/release/peregrine` | CPython 3.12.3 | processes (`--workers N`) |
| **FT** | `~/pgbuild-ft/release/peregrine` | CPython 3.14.6t | threads (`--workers N --free-threaded`) |

That is threading model **and** interpreter version, not a clean A/B. 3.14t
pays a single-thread refcount tax that 3.12 does not. FastAPI, Django, Sanic,
BlackSheep and uvloop 0.22.1 on the 3.14t venv all left the GIL off.

Reproduce:

```bash
bash benchmarks/gil_vs_ft.sh
```

`GIL_BIN`, `FT_BIN`, `GIL_VENV`, `FT_VENV`, `DURATION` and `CONNS` override
the defaults. The FT binary must be linked against `python3.14t` (or newer)
and needs an rpath — or `LD_LIBRARY_PATH` — to that interpreter's `lib`, or
it will not find `libpython3.14t.so`.

---

## 1 worker

req/s.

| app | GIL 64 | GIL 256 | GIL 512 | FT 64 | FT 256 | FT 512 |
|---|---:|---:|---:|---:|---:|---:|
| raw ASGI | 60,882 | 62,123 | 62,713 | 58,149 | 61,160 | 57,365 |
| raw WSGI | 102,619 | 121,316 | 111,817 | 81,656 | 105,506 | 103,407 |
| FastAPI | 10,228 | 9,734 | 9,448 | 8,991 | 8,533 | 8,434 |
| Django | 6,560 | 6,726 | 6,830 | 6,198 | 6,021 | 5,889 |
| Sanic | 9,278 | 9,398 | 8,794 | 9,392 | 8,470 | 8,492 |
| BlackSheep | 25,594 | 29,951 | 21,281 | 30,720 | 29,620 | 30,463 |

One FT worker is one event loop plus a mostly-idle supervising thread. There
is nothing for a second core to do, so the free-threaded build can only be
as fast as 3.14t's single-thread path. At 256 connections that is roughly
2–13 % slower than 3.12, except BlackSheep, which is a wash.

---

## 4 workers

req/s. GIL workers are processes; FT workers are threads of one process.

| app | GIL 64 | GIL 256 | GIL 512 | FT 64 | FT 256 | FT 512 |
|---|---:|---:|---:|---:|---:|---:|
| raw ASGI | 123,716 | 135,070 | 136,537 | 123,587 | 142,939 | 136,769 |
| raw WSGI | 154,654 | 161,424 | 146,469 | 147,882 | 150,535 | 143,869 |
| FastAPI | 41,467 | 41,598 | 42,450 | 35,148 | 36,576 | 36,377 |
| Django | 23,509 | 23,928 | 24,540 | 18,484 | 18,618 | 19,208 |
| Sanic | 36,374 | 36,848 | 36,373 | 23,187 | 25,044 | 24,894 |
| BlackSheep | 89,818 | 97,784 | 97,072 | 85,615 | 85,419 | 84,605 |

FT versus GIL at 256 connections:

| app | 1 worker | 4 workers | 1W → 4W (GIL) | 1W → 4W (FT) |
|---|---:|---:|---:|---:|
| raw ASGI | −2 % | **+6 %** | 2.2× | 2.3× |
| raw WSGI | −13 % | −7 % | 1.3× | 1.4× |
| FastAPI | −12 % | −12 % | 4.3× | 4.3× |
| Django | −10 % | −22 % | 3.6× | 3.1× |
| Sanic | −10 % | **−32 %** | 3.9× | 3.0× |
| BlackSheep | −1 % | −13 % | 3.3× | 2.9× |

Raw ASGI at 4 workers is a tie: threads really do run in parallel. Raw WSGI
barely scales on either model — one worker is already saturating the box.
The frameworks scale close to 4× as processes; as threads they share one
interpreter and one application object, and that costs. Sanic is the worst
of them, which is what you would expect from one `Sanic()` instance driven
by four event loops in one process.

Four FT workers also mean five runnable threads (four loops plus the
supervisor) on four cores. That is a real tax on a machine this small; it
is not the whole of the framework gap.

---

## How to read it

- **`--workers` (processes) is the way to raise hello-world RPS.** That is
  how Peregrine uses every core today.
- **`--free-threaded` is not a throughput upgrade on this contract.** It is
  the same parallelism with one import and one set of module-level caches. Measure RSS, or a CPU-bound view, if that is the
  claim you want to test — [CONFIG.md](CONFIG.md#free-threaded-python) and
  [benchmarks/free_threaded.sh](benchmarks/free_threaded.sh).
- These cells are empty `GET /`. They say nothing about bodies, HTTP/2,
  HTTP/3, WebSocket, or an application that waits on a database.

Next: [CONFIG.md](CONFIG.md) — flags, including `--free-threaded`.
[ARCHITECTURE.md](ARCHITECTURE.md) — why a worker is a process, and what
changes when it is a thread. [INSTALLATION.md](INSTALLATION.md#building-against-free-threaded-cpython)
— building the 3.14t binary.
