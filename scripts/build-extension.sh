#!/usr/bin/env bash
# Builds peregrine._native: the server as a CPython extension module, for the
# python that runs it.
#
#   bash scripts/build-extension.sh
#   PYTHON=~/venv/bin/python bash scripts/build-extension.sh
#
# The module is written to python/peregrine/ under that interpreter's
# extension suffix (_native.cpython-312-x86_64-linux-gnu.so), so
# `python -m peregrine` with python/ on PYTHONPATH serves through it.
#
# It links no libpython. The Python symbols are resolved from the interpreter
# that imports it, which on a distribution python is a statically linked,
# position-dependent executable -- faster for framework code than
# libpython3.x.so, which is the reason this build exists.
#
# The headers have to be that interpreter's. They are found through its
# python3.pc; set PKG_CONFIG_PATH when sysconfig does not know where that is
# (relocated builds such as uv's report the path they were built at).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PYTHON=${PYTHON:-python3}
SCRATCH=${SCRATCH:-$HOME/pgbuild-ext}

suffix=$("$PYTHON" -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')
pcdir=$("$PYTHON" -c 'import sysconfig; print(sysconfig.get_config_var("LIBPC") or "")')
want=$("$PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
ldversion=$("$PYTHON" -c 'import sysconfig; print(sysconfig.get_config_var("LDVERSION") or "")')

export PEREGRINE_EXTENSION=1
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:+$PKG_CONFIG_PATH:}$pcdir"

# The versioned package when there is one: python3.pc is an alias that a
# versioned Homebrew keg does not ship, and then pkg-config answers with
# another Python's. Package.swift reads the name from PEREGRINE_PYTHON_PC.
package=python3
if [ -n "$ldversion" ] && pkg-config --exists "python-$ldversion" 2>/dev/null; then
    package="python-$ldversion"
fi
export PEREGRINE_PYTHON_PC=$package

have=$(pkg-config --modversion "$package" 2>/dev/null || true)
if [ "$have" != "$want" ]; then
    echo "pkg-config finds Python headers for '$have' as $package, but $PYTHON is $want;" >&2
    echo "point PKG_CONFIG_PATH at the lib/pkgconfig of $PYTHON" >&2
    exit 1
fi

# Anything after the script's name goes to swift build, for the flags a platform
# needs -- on macOS, where Homebrew's OpenSSL is: -Xcc -I... -Xlinker -L...
swift build -c release --product PeregrineExtension --scratch-path "$SCRATCH" "$@"

# SwiftPM names the library for the platform; Python wants the interpreter's
# suffix, which is .so on macOS too.
library="$SCRATCH/release/libPeregrineExtension.so"
[ "$(uname -s)" = Darwin ] && library="$SCRATCH/release/libPeregrineExtension.dylib"
target="$ROOT/python/peregrine/_native$suffix"
cp "$library" "$target"
echo "built $target"
