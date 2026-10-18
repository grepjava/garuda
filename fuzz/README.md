# Fuzzing

The parsers that read bytes from the network are fuzzed with `pgfuzz`, a
mutation fuzzer in this package. The targets live in
[`Sources/GarudaFuzzTargets`](../Sources/GarudaFuzzTargets), the driver in
[`Sources/pgfuzz`](../Sources/pgfuzz).

## Targets

| Target | What it feeds |
| --- | --- |
| `http-head` | the HTTP/1.1 request-head parser |
| `http-response` | the HTTP/1.1 response-head parser the HTTP client reads with |
| `chunked` | the chunked transfer decoder |
| `hpack` | the HPACK decoder |
| `qpack` | the QPACK decoder (HTTP/3 field sections) |
| `websocket` | the WebSocket frame header parser |
| `quic-packet` | the QUIC packet header parser |
| `quic-frames` | a server QUIC connection, the input sealed as one 1-RTT packet |
| `tls-hello` | a new server QUIC connection, the input as its ClientHello |
| `h2` | a whole HTTP/2 connection, the input after the preface and SETTINGS |
| `h3` | a whole HTTP/3 connection over loopback UDP, the input on a stream |
| `json` | the JSON decoder and encoder |
| `resp` | the Redis reply parser, whole and a byte at a time |
| `postgres` | PostgreSQL backend messages: framing, every message body, column values, arrays and COPY rows |

The connection targets run in process with no I/O except `h3`'s socket:
`quic-frames` and `tls-hello` drive Vega's `VegaQUICCore` against the tests' own client
(`Tests/QUICTestPeer`), `h2` serves an `Application` over GarudaTesting's
in-memory duplex, and `h3` serves one on 127.0.0.1 for the whole run. They
take milliseconds an input where the parsers take microseconds. For `h3`, the
input's first byte picks where the rest goes: 0, request stream 0; 1, the
client's control stream after SETTINGS; 2, a unidirectional stream, its type
included.

Not crashing is only part of the check. Each target also tests an invariant
that a wrong parse breaks even when nothing traps:

- **Slices stay in bounds.** Parsers return offsets into the caller's buffer.
  Every one must point inside the bytes given, and inside the bytes the parse
  claims to have consumed.
- **Splits do not matter.** The chunked decoder must produce the same outcome
  and the same body whether the input arrives at once or one byte at a time.
  On a socket the peer chooses the splits.
- **Consumed bytes are enough.** An HTTP head or WebSocket header that parses
  from a longer buffer must parse the same way from exactly the bytes it
  consumed. Pipelining depends on it.
- **Decoding is repeatable.** The same HPACK block decodes to the same fields
  in two fresh decoders.
- **JSON round-trips.** A document that decodes must encode, and decode again
  to the same value. So do PostgreSQL array literals and COPY rows, which a
  client writes back.
- **What a connection sends is legible.** Every packet a QUIC connection sends
  opens at the client and its frames parse; every HTTP/2 frame has the length
  its type needs and every header block decodes, in order; every HTTP/3 stream
  the server ends holds whole frames.
- **A connection does not hang.** An HTTP/2 connection closes once the client
  has; on HTTP/3, a request after the input is still answered, and a request
  stream the client ended is answered or refused.
- **No amplification.** Before the client's address is validated, a QUIC
  server sends at most three times what it received, retransmissions
  included. The target serves a certificate large enough to reach the limit.

## Running

```bash
swift run -c release pgfuzz                        # every target, 5 s each
swift run -c release pgfuzz http-head --seconds 300
swift run -c release pgfuzz chunked hpack --seed 42
swift run -c release pgfuzz --corpus-only          # replay seeds and corpus only
```

| Option | Default | Meaning |
| --- | --- | --- |
| `target ...` | all | which targets to run |
| `--seconds N` | 5 | time per target |
| `--seed N` | random | seed for the mutations, printed at start |
| `--corpus DIR` | `fuzz/corpus` | corpus root |
| `--max-len N` | 4096 | longest input a mutation may produce |
| `--corpus-only` | off | run the seeds and corpus without mutating |

Each target first runs its compiled-in seeds and every file in
`<corpus>/<target>/` unchanged, then mutates them until time is up: bit flips,
byte changes, inserted protocol tokens (`\r\n`, `chunked`, large numbers),
deleted and duplicated runs, splices between inputs, truncation, and repeated
bytes. There is no coverage feedback.

A run is reproducible from its seed with the same corpus. For the connection
targets this holds up to what the scheduler and the connection's own random
connection IDs and keys decide.

## Sanitizers

A release build traps on integer overflow and out-of-bounds `Array` access.
The parsers walk raw pointers, so an out-of-bounds read needs AddressSanitizer:

```bash
swift build -c release --product pgfuzz -Xswiftc -sanitize=address
.build/release/pgfuzz --seconds 60
```

The `fuzz` job in `.github/workflows/ci.yml` runs exactly this: 60 seconds a
target on every push to `main` and `vega`, every pull request and every run
started by hand, and 600 seconds a target nightly. It uploads any
`pgfuzz-*.bin` it finds.

## Corpus

`fuzz/corpus/<target>/` holds inputs worth keeping, above all anything that
once broke an invariant. `swift test` runs `FuzzCorpusTests` (in `Tests/GarudaFuzzTests`), which checks
every compiled-in seed, every corpus file, and an empty input against each
target's invariants.

When `pgfuzz` finds a failure it prints the reason and a hex dump, writes the
input to `pgfuzz-<target>-<seed>.bin` in the working directory, prints the
command to reproduce the run, and exits 1. To keep it as a regression test,
give it a descriptive name and move it into the corpus:

```bash
mv pgfuzz-chunked-1234.bin fuzz/corpus/chunked/what-it-was.bin
swift test
```
