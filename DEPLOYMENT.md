# Running Garuda in production

How a Garuda 2 server behaves as a set of processes, what each signal does,
how to take it out of a load balancer without refusing traffic, and how to
reload it. Building and certificates are in [INSTALLATION.md](INSTALLATION.md);
every flag is in [CONFIG.md](CONFIG.md).

---

## The supervisor and its shards

On Linux, by default, the process you start is a **supervisor**. It binds the
listening ports, maps the memory the shards share, and starts the
**shards**: one process per last-level cache domain, each with its own
work-stealing runtime pinned to that domain's CPUs. The supervisor serves
nothing itself. `--shards N` sets the count; `--shards 0` serves in the one
process you started, with no supervisor.

| platform | default | how shards start |
|---|---|---|
| Linux | `--shards auto` | forked from the supervisor |
| macOS | `--shards 0` | a new run of the same executable with the same arguments |
| Windows | one process, always | -- |

What the supervisor does:

- **A shard that crashes** -- killed by a signal, or exiting non-zero -- is
  started again at once. One that keeps crashing within a second of starting
  is restarted after 100 ms, then after waits doubling up to 5 seconds. Only
  that shard's connections are lost; the others keep serving. A shard whose
  `app.state` factory or `onShardStart` hook throws exits with status 1 and is
  restarted the same way, so a database that is down at start-up is retried
  rather than served without.
- **Signals** to the supervisor are passed on to the shards (below).
- **If the supervisor dies**, each shard is sent `SIGTERM`.
- **It exits** when every shard has gone: 0 after a stop signal.

The shards share some state through memory the supervisor maps before they
start, and keeps across shard restarts: the TLS session-ticket key, the
`--rate-limit` table, the `--metrics-port` counters, the `--cache-size`
cache and the `--broadcast-size` ring. Everything else -- `app.state`, the
database pools, in-memory session and token stores -- belongs to one shard.
An in-memory store under more than one shard is warned about at start-up;
use a database or Redis for state every shard must see.

**Nothing may start a thread before `app.run()`.** With shards, the
supervisor forks, and a fork copies only the calling thread, so Vega stops the
program if another thread exists by then: a Vega `Runtime` made in `main`, a
tracer's exporter, a library that starts a background thread. Make such
things in `app.state`, `onShardStart` or `app.tracing { shard in … }`, which run
in each shard.

The process names make the shards easy to find: shard *i*'s threads are named
`garuda-s<i>`.

### Containers and CPU limits

Vega sizes the shards from the CPUs the process may run on: its affinity mask,
which `taskset` or a cpuset sets. A CPU quota without a cpuset (a Kubernetes
CPU limit, `docker run --cpus`) is not seen, so in a container with a quota,
set the count yourself:

```bash
garuda --shards 1 --threads 4        # a pod limited to four CPUs
```

The environment variable `VEGA_SHARDS` overrides `--shards`, which is handy
where the command line is fixed.

---

## Signals

| signal | effect |
|---|---|
| `SIGTERM` | fail the health check for `--drain-delay`, then stop accepting and drain within `--graceful-timeout` |
| `SIGINT`, `SIGQUIT` | drain at once; one sent during a `--drain-delay` cuts it short |
| `SIGHUP` | restart the shards one at a time (with shards only) |

The supervisor passes `SIGTERM` on as `SIGTERM`, and `SIGINT` or `SIGQUIT` as
`SIGINT`. Each shard applies `--drain-delay` itself, so an init system that
signals the whole process group behaves the same as one that signals only the
supervisor.

**Draining.** A shard that drains:

1. answers the health check with 503 from then on;
2. stops accepting connections;
3. sends each WebSocket a 1001 close, and each HTTP/2 connection a GOAWAY once
   its WebSockets have closed;
4. lets HTTP/1.1 connections finish the request in hand, HTTP/2 and HTTP/3
   connections finish their streams, all within `--graceful-timeout`
   milliseconds (10000 by default);
5. stops its `app.every` jobs, runs its `onShardStop` hooks and shuts its
   state down, newest first.

The supervisor kills any shard still running `--drain-delay` +
`--graceful-timeout` + 5 seconds after the signal. The same signal sent to the
supervisor a second time does not wait: the shards are killed at once.

**With `--shards 0`** the one process handles `SIGTERM`, `SIGINT` and `SIGQUIT`
the same way. `SIGHUP` is not handled, so the system's default for it ends the
process. **On Windows** no signal is handled.

---

## Draining behind a load balancer

```bash
garuda --health-check-path /healthz --drain-delay 10000 --graceful-timeout 30000
```

A load balancer or Kubernetes Service keeps routing to a server for a few
seconds after it is told to stop: taking an endpoint out of rotation has to
propagate. A server that stops accepting the moment `SIGTERM` arrives refuses
that traffic. With `--drain-delay`, on `SIGTERM` the server:

- keeps serving for the delay, in milliseconds;
- answers `--health-check-path` with `503`, so the balancer marks it down;
- closes each HTTP/1.1 connection after its response, so clients reconnect
  to a server that is staying;

and only then starts draining. Both flags are milliseconds.

- Make the delay longer than the readiness probe takes to fail: its period
  times its failure threshold.
- Kubernetes' `terminationGracePeriodSeconds` must cover the delay plus
  `--graceful-timeout` and a margin.
- Only `SIGTERM` waits. `SIGINT`, `SIGQUIT` and a reload do not.

```yaml
readinessProbe:
  httpGet: { path: /healthz, port: 8000 }
  periodSeconds: 2
  failureThreshold: 2
terminationGracePeriodSeconds: 45     # 10 s delay + 30 s grace + margin
```

The health check is answered before rate limiting, static files and routes,
and says nothing about the application's own dependencies. A deeper check is
a route of the application's.

---

## Reloads

`SIGHUP` to the supervisor restarts the shards one at a time. For each shard
in turn, the supervisor sends it `SIGINT`; it drains (no `--drain-delay`) and
exits; its replacement starts; then the next shard. The log says
`reloading workers` when a reload begins and `workers reloaded` when every
shard has started again. A `SIGHUP` during a reload is ignored.

- **What a reload picks up:** each replacement shard loads the
  certificate and key files again, rebuilds its `app.state` and runs its start
  hooks. It is how a renewed certificate is taken into use without
  `--tls-reload`.
- **What it does not:** the command line, which the supervisor read once.
  The executable either: on Linux the replacement is forked from the
  supervisor, so a new build needs a restart (or, in development,
  `--reload`).
- **The response cache** is emptied when a replacement starts.
- **Capacity.** One shard is out of service at a time while it drains and
  restarts. The others keep accepting. With `--balance shared` they take
  every new connection. With `reuseport` (the default on Linux) the kernel
  hashes new connections only across the sockets still open; connections
  already queued on the stopping shard's socket when it closes are reset,
  unless `net.ipv4.tcp_migrate_req=1` lets the kernel move them to another
  shard's socket.

Certificate renewal with certbot:

```bash
certbot renew --deploy-hook 'systemctl reload garuda'
```

or run with `--tls-reload 3600` and let the server notice the files change,
with no restart at all ([CONFIG.md](CONFIG.md#renewing-certificates)).

---

## Running as a systemd service

```ini
[Unit]
Description=garuda
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/garuda --host 0.0.0.0 --port 443 \
    --tls-cert /etc/garuda/cert.pem --tls-key /etc/garuda/key.pem \
    --redirect-http 80 \
    --health-check-path /healthz --drain-delay 5000 --graceful-timeout 10000
ExecReload=/bin/kill -HUP $MAINPID
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

- `systemctl stop` sends `SIGTERM`, which drains. Keep `TimeoutStopSec` above
  `--drain-delay` + `--graceful-timeout` + 5 seconds.
- `systemctl reload` sends `SIGHUP` to the supervisor, which restarts the
  shards one at a time.
- `AmbientCapabilities=CAP_NET_BIND_SERVICE` lets a non-root user bind ports
  below 1024.
- `Restart=on-failure` covers the supervisor itself. Crashed shards are the
  supervisor's to restart.

Exit status: 0 after a stop signal; 2 for a command line, route table or
certificate that is wrong; 1 for a port that cannot be bound, or for a server
in one process whose state could not be built.

To upgrade, rebuild, copy the binary into place and restart. Garuda keeps no
state on disk.

---

## Behind a reverse proxy

Bind to loopback or a unix socket, and trust the proxy's forwarded headers:

```bash
garuda --unix /run/garuda.sock --forwarded-allow-ips unix
garuda --host 127.0.0.1 --port 8000 --forwarded-allow-ips 127.0.0.1
```

- Without `--forwarded-allow-ips`, `X-Forwarded-For`, `X-Forwarded-Proto` and
  `Forwarded` are ignored. Handlers and the rate limiter then see the proxy's
  address.
- A proxy that talks h2c upstream, such as Envoy or Caddy, needs
  `--http2-only`.
- If the proxy mounts the application under a prefix and does not strip it,
  use `--root-path`.
- A proxy that terminates TLS and sends no forwarded headers needs
  `--scheme https`.

---

## Logs and metrics

- Everything Garuda writes goes to standard error, one line per write of at
  most 4096 bytes, so shards sharing the stream never interleave lines.
  `--log-format json` and `--access-log-format json` give a collector one JSON
  object per line, with a `pid` to tell shards apart.
- `--metrics-port` serves Prometheus metrics summed over every shard, on a
  port of its own. Bind it privately with `--metrics-host 127.0.0.1`.
- `--request-id` puts one ID on the response, the access log and
  `request.log` lines.

[CONFIG.md](CONFIG.md#observability) has the formats and the metric names.
