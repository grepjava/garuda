#!/usr/bin/env bash
# What OpenSSL 3.x costs Garuda that BoringSSL would not, on the two things
# profiling puts the TLS bill in: a handshake, and a small record read and
# written on an established connection.
#
#   bash benchmarks/tls-probes/run.sh <path-to-CNIOBoringSSL-checkout> [cert] [key]
#
#   tlsbench.c   one source, compiled against each library in turn
#   sockbench.c  the same round trip with no TLS, for the syscall floor
#
# The BoringSSL side is swift-nio-ssl's vendored copy. Its prefix header maps
# the ordinary OpenSSL names onto prefixed ones, so a single source compiles
# against either library and the comparison is genuinely of the two libraries
# rather than of two programs.
#
# Two things have to be pinned or the result measures them instead:
#
#   the group   OpenSSL 3.5 offers X25519MLKEM768 by default, BoringSSL picks
#               classical X25519. Post-quantum key exchange is much the more
#               expensive, so an unpinned run reads as a library difference
#               when it is a policy difference.
#   the suite   OpenSSL leads with AES-256-GCM, BoringSSL takes AES-128-GCM
#               where AES is accelerated. BoringSSL does not let TLS 1.3
#               suites be chosen, so OpenSSL is brought to its choice.
#
# Both binaries print what they actually negotiated. If those two fields ever
# differ between the arms, the numbers on that line mean nothing.
#
# Use an ECDSA P-256 certificate, as the server does; an RSA certificate puts
# a signature so far above everything else that the libraries look alike.
#
# Run it pinned to one core, and read the arms in pairs rather than comparing
# across sessions.
set -eu

NIOSSL=${1:?usage: run.sh <path-to-swift-nio-ssl checkout> [cert] [key]}
CERT=${2:-/tmp/c.pem}
KEY=${3:-/tmp/k.pem}

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

INC="$NIOSSL/Sources/CNIOBoringSSL/include"
[ -d "$INC" ] || { echo "no CNIOBoringSSL headers under $NIOSSL" >&2; exit 1; }

# The objects SwiftPM already built for CNIOBoringSSL, so there is nothing to
# compile from source here. Build swift-nio-ssl in release first if this is
# empty.
OBJS=$(find "$NIOSSL/../.." -path "*CNIOBoringSSL.build*" -name "*.o" 2>/dev/null || true)
[ -n "$OBJS" ] || { echo "no CNIOBoringSSL objects; build swift-nio-ssl -c release first" >&2; exit 1; }

cc -O2 -o "$OUT/tb-openssl" "$HERE/tlsbench.c" -lssl -lcrypto
c++ -O2 -DUSE_BORINGSSL -I "$INC" -o "$OUT/tb-boring" "$HERE/tlsbench.c" $OBJS -lpthread
cc -O2 -o "$OUT/sockbench" "$HERE/sockbench.c"

echo "== socketpair floor, no TLS"
for _ in 1 2 3; do taskset -c 0 "$OUT/sockbench" 200000; done

echo "== openssl against boringssl, alternating"
for _ in 1 2 3 4 5; do
    taskset -c 0 "$OUT/tb-openssl" "$CERT" "$KEY" 2000 200000
    taskset -c 0 "$OUT/tb-boring"  "$CERT" "$KEY" 2000 200000
done
