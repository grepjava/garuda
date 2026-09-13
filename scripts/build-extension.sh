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

export PEREGRINE_EXTENSION=1
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:+$PKG_CONFIG_PATH:}$pcdir"

have=$(pkg-config --modversion python3 2>/dev/null || true)
if [ "$have" != "$want" ]; then
    echo "pkg-config finds Python headers for '$have', but $PYTHON is $want;" >&2
    echo "point PKG_CONFIG_PATH at the lib/pkgconfig of $PYTHON" >&2
    exit 1
fi

swift build -c release --product PeregrineExtension --scratch-path "$SCRATCH"

target="$ROOT/python/peregrine/_native$suffix"
cp "$SCRATCH/release/libPeregrineExtension.so" "$target"
echo "built $target"
