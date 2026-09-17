# Connectors

Garuda talks to other services through connectors that run on the worker's
poller: an HTTP client, a PostgreSQL driver and a Redis driver. Each one keeps a
pool per worker process, built after the fork. No connector blocks a worker's
thread, and none wraps a client library such as libpq or hiredis. A SQLite
connector is planned.

This file covers what each connector supports, what it does not, and the work
planned for each one. How to use them is in [README.md](README.md), and every
change is in [RELEASE.md](RELEASE.md).

| Connector | Status | Not supported |
|---|---|---|
| [HTTP client](#http-client) | Done | HTTP/3, proxies |
| [PostgreSQL](#postgresql) | Done | Some types, `LISTEN`, `COPY`, unix sockets, several hosts |
| [Redis](#redis) | Done | **Cluster, Sentinel**, sharded pub/sub, client-side caching |
| [SQLite](#sqlite) | Planned | Everything, for now |

## HTTP client

`request.client` speaks HTTP/1.1, and HTTP/2 over TLS when the server offers
it. It resolves names on the poller, verifies TLS certificates, keeps
connections for reuse, decodes compressed bodies and follows redirects when a
policy allows them.

### Not supported

- HTTP/3. The server speaks it, but the client does not.
- HTTP and SOCKS proxies.

### Future work

- HTTP/3, when a server advertises it with Alt-Svc.
- Proxies set in the configuration.
- Streamed request and response bodies. Today the client holds a whole body in
  memory, up to `maxBodyBytes`.

## PostgreSQL

The driver supports SCRAM-SHA-256 and TLS, which is required by default. It
pools connections with an acquire timeout, keeps statements prepared on each
connection, reads values in binary, and runs transactions that roll back when
their closure throws.

### Not supported

- `date`, `time`, `interval`, `numeric` and `json` have no Swift types of their
  own and are read as text.
- `LISTEN` and `NOTIFY`, and `COPY`.
- Unix-domain sockets. The driver connects over TCP only.
- SASLprep, so a password with non-ASCII characters may not authenticate.
- Several hosts in one configuration, and sending reads to a replica. A pool
  talks to one server.

### Future work

- Types for dates, times, intervals, `numeric` and `json`.
- `LISTEN` on a connection of its own, like Redis `subscribe`.
- `COPY` in both directions, streamed.
- Unix-domain sockets, SASLprep, and a list of hosts to try in order.

## Redis

The driver speaks RESP3 through `HELLO` and falls back to RESP2 for servers
older than Redis 6. Valkey works the same. TLS is required by default. The
driver supports ACL users, databases other than 0, unix sockets, pipelines,
transactions, `WATCH` sessions and pub/sub.

### Cluster and Sentinel are not supported

A `RedisPool` talks to the one server its `RedisConfiguration` names. The
driver never asks which nodes a cluster has or which server a Sentinel has
promoted.

**Redis Cluster.** Pointed at one node of a cluster, the driver works only
for keys whose hash slots that node holds:

- A key on another node is answered with `MOVED`, and a key being migrated with
  `ASK`. The driver does not follow either redirect. Both throw
  `RedisClientError.server`, with `code` set to `MOVED` or `ASK`.
- A command, pipeline or transaction whose keys span several slots gets
  `CROSSSLOT` from the server.
- `subscribe` hears messages published on any node, as cluster pub/sub
  spreads them. Sharded pub/sub (`SSUBSCRIBE`) has no method.

**Redis Sentinel.** The driver does not speak to Sentinels:

- Pointed at a Sentinel, data commands fail, because a Sentinel does not store
  keys.
- Pointed at the primary directly, the pool keeps its connections through a
  failover. Once the old primary becomes a replica, writes throw
  `RedisClientError.server` with `code` set to `READONLY` until those
  connections close. If the old primary is down, requests fail to connect
  until the configured address reaches a server again.

**What works today:**

- A single server, a primary with replicas where the application writes to the
  primary, or a managed service's single endpoint.
- A stable address that follows the primary through a failover, such as a DNS
  name or a proxy that speaks the single-server protocol. A connection the
  failover broke is closed, and the next one reaches the new primary. With a
  DNS name, a connection still open to a demoted primary keeps getting
  `READONLY` until it closes, so a proxy is the safer choice.

### Future work

**Cluster support:**

- Read the slot map with `CLUSTER SHARDS` (`CLUSTER SLOTS` on older servers)
  from a list of seed nodes.
- Keep a pool per node in each worker, and route each command by the CRC16 of
  its key, including `{hash tags}`.
- Follow `MOVED` by refreshing the map and retrying once. Follow `ASK` by
  sending `ASKING` to the named node for that one command.
- Split a pipeline by node and put the replies back in order. Keep a
  transaction and a `WATCH` session to one slot, and refuse keys from different
  slots before sending.
- Add `ssubscribe` for sharded pub/sub, on a connection to the node that owns
  the channel.
- Optionally send reads to replicas with `READONLY`.

**Sentinel support:**

- Configure a list of Sentinels and a primary's name. Ask the Sentinels with
  `SENTINEL GET-MASTER-ADDR-BY-NAME`, and check the answer with `ROLE` before
  using it.
- Listen for `+switch-master` on a Sentinel, and close the pool's connections
  when the primary changes.
- Treat `READONLY` as a sign of a missed failover: ask the Sentinels again and
  retry once.

**Other work:**

- RESP3's streamed strings and aggregates, which the parser refuses today. No
  command the driver sends is answered with them.
- Client-side caching with `CLIENT TRACKING`. Today, a connection that turns
  tracking on is closed instead of being reused.
- More typed commands: sorted sets, streams and scripting. `send` runs any of
  them now, with untyped replies.

## SQLite

SQLite is next. It will run on the blocking pool, since SQLite's C library
blocks the thread that calls it, and queries will decode rows into `Decodable`
types, as the PostgreSQL driver does.
