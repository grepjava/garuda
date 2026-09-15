#!/usr/bin/env bash
# The measurements behind HANDLER-API.md, "How a request runs": what an async
# handler costs on an executor owned by the worker loop, and whether the
# proposed handler syntax selects the right overload.
#
#   bash benchmarks/async-probes/run.sh
#
#   task-per-request.swift    a new Task per request, sync call for scale
#   task-reuse.swift          Task.immediate variants, and one reused task
#   realistic-handlers.swift  a reused task with large frames, nesting, throws
#   handler-syntax.swift      sync and async overloads, typed extractors
#
# Each timing probe runs twice: plain, for time, and under LD_PRELOAD with
# malloc-counter.c, for allocations per request. Linux only (LD_PRELOAD,
# glibc's RTLD_NEXT); needs swiftc 6.2 or later and a C compiler.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cc -O2 -shared -fPIC -o "$OUT/malloc-counter.so" "$HERE/malloc-counter.c" -ldl
for probe in task-per-request task-reuse realistic-handlers handler-syntax; do
    swiftc -O -parse-as-library -swift-version 6 "$HERE/$probe.swift" -o "$OUT/$probe"
done

export SWIFT_BACKTRACE=enable=no
for probe in task-per-request task-reuse realistic-handlers; do
    echo "== $probe, time"
    "$OUT/$probe"
    echo "== $probe, allocations"
    LD_PRELOAD="$OUT/malloc-counter.so" "$OUT/$probe"
done
echo "== handler-syntax"
"$OUT/handler-syntax"
