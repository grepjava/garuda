#!/usr/bin/env bash
# The shared response cache's own tests, compiled against peregrine_cache.c:
# a writer paused mid-copy, one that died holding a slot, copies of a response
# in two size classes, and a change to a target while a GET for it is out.
#
#   bash scripts/cache-unit-test.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

${CC:-cc} -std=c11 -O1 -g -Wall -Wextra -Werror -DPG_CACHE_TESTING \
    -I "$ROOT/Sources/CPeregrine/include" \
    "$ROOT/Sources/CPeregrine/peregrine_cache.c" "$ROOT/scripts/cache_unit.c" \
    -o "$OUT/cache-unit"
"$OUT/cache-unit"
