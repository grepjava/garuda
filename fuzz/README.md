# Fuzzing

The parsers in this server read bytes chosen by whoever is on the other end of
a socket: the request head, the chunked framing under it, an HPACK block, a
WebSocket frame header, a QUIC packet header. A wrong answer in any of them is
reachable from the network, so they are fuzzed.

```bash
swift run -c release pgfuzz                      # every target, 5s each
swift run -c release pgfuzz http-head --seconds 300
swift run -c release pgfuzz --corpus-only        # just replay what is here
```

Under a sanitizer, which is where it earns its keep — a release build already
traps on an overflow or an out-of-bounds `Array` access, but these parsers walk
raw pointers, and only ASan sees a read one byte past a buffer:

```bash
swift build -c release -Xswiftc -sanitize=address
.build/release/pgfuzz --seconds 60
```

CI runs that last form on every push.

## What is actually checked

"Does not crash" is the weakest thing a fuzzer can check and the easiest to
pass by accident, so each target also states an invariant that a corrupted
parse breaks even when nothing traps
([`Sources/PeregrineFuzzTargets`](../Sources/PeregrineFuzzTargets)):

- **every slice points inside the bytes it was given.** The parsers return
  offsets into the caller's buffer; one that runs past the end is how a
  malformed request becomes a read of somebody else's memory.
- **a resumable decoder does not care where the reads split.** On a socket the
  splits are the peer's choice, so if they can change what is decoded, they can
  change where a message ends — which is what request smuggling is. This is the
  invariant that found the trailer bug in `fuzz/corpus/chunked/`.
- **a parse that succeeds from a longer buffer succeeds the same way from
  exactly the bytes it claimed to consume.** Pipelining depends on it.

## The corpus

`corpus/<target>/` holds inputs worth keeping — above all, anything that once
broke an invariant. `swift test` replays every one of them on every run, so a
fixed parser bug has a test that names the byte string that broke it, and the
fuzzer starts its mutations from them.

When a run finds something it writes the input to `pgfuzz-<target>-<seed>.bin`
and prints the seed that reproduces the whole run. Give the file a name that
says what it is and move it here:

```bash
mv pgfuzz-chunked-1234.bin fuzz/corpus/chunked/what-it-was.bin
swift test                                       # now it is a regression test
```

There is no coverage feedback: this is a mutation fuzzer, not libFuzzer.
That is a deliberate trade — it builds and runs anywhere the server does, with
no extra toolchain, which is what makes it something CI can run on every
commit. Pointing libFuzzer at `Fuzz.run` is a two-line target when a deeper
search is wanted.
