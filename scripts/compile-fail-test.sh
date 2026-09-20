#!/usr/bin/env bash
# Handler code that must not compile. Each file in Tests/CompileFail tries to
# keep request data past where the API lends it, and names the diagnostic it
# expects in an "// expect-error:" line. The lifetime checks are SIL
# diagnostics, so every file is compiled through -emit-sil: -typecheck would
# let the escaping ones through.
#
#   swift build && bash scripts/compile-fail-test.sh
#
# Tests/CompileFail/control holds code that must compile, so that a harness
# that cannot find the Garuda module does not pass everything by failing it.
# The `@JSON` cases need the macro plugin, which `swift build` leaves beside
# the modules.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD:-$ROOT/.build/debug}
SWIFTC=${SWIFTC:-swiftc}
# aviancore's C headers: SwiftPM's checkout, or a local copy beside this one.
AVIAN=${AVIAN:-$ROOT/.build/checkouts/aviancore}
[ -d "$AVIAN" ] || AVIAN=$ROOT/../aviancore

# Every C target Garuda's module was built against, not aviancore's alone:
# a swiftmodule names the clang modules it needs, and swiftc refuses to
# load Garuda at all unless it can find every one of them.
compile() {
    "$SWIFTC" -parse-as-library -swift-version 6 -emit-sil -o /dev/null \
        -I "$BUILD/Modules" \
        -Xcc -fmodule-map-file="$BUILD/CAvian.build/module.modulemap" \
        -Xcc -fmodule-map-file="$BUILD/CGarudaJWT.build/module.modulemap" \
        -Xcc -fmodule-map-file="$BUILD/CGarudaSQLite.build/module.modulemap" \
        -Xcc -I"$AVIAN/Sources/CAvian/include" \
        -Xcc -I"$ROOT/Sources/CGarudaJWT/include" \
        -Xcc -I"$ROOT/Sources/CGarudaSQLite/include" \
        -load-plugin-executable "$BUILD/GarudaMacros-tool#GarudaMacros" \
        "$1" 2>&1
}

passed=0
failed=0

for file in "$ROOT"/Tests/CompileFail/control/*.swift; do
    name="control/$(basename "$file" .swift)"
    if output=$(compile "$file"); then
        echo "  ok   $name compiles"
        passed=$((passed + 1))
    else
        echo "  FAIL $name does not compile; the harness is broken"
        printf '%s\n' "$output" | grep "error:" | head -5
        failed=$((failed + 1))
    fi
done

for file in "$ROOT"/Tests/CompileFail/*.swift; do
    name=$(basename "$file" .swift)
    expected=$(sed -n 's|^// expect-error: ||p' "$file" | head -1)
    if [ -z "$expected" ]; then
        echo "  FAIL $name has no expect-error line"
        failed=$((failed + 1))
        continue
    fi
    output=$(compile "$file")
    status=$?
    if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -qF -- "$expected"; then
        echo "  ok   $name is refused: $expected"
        passed=$((passed + 1))
    else
        echo "  FAIL $name (exit $status), expected: $expected"
        printf '%s\n' "$output" | grep "error:" | head -5
        failed=$((failed + 1))
    fi
done

echo "compile-fail: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
