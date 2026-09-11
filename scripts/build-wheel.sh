#!/usr/bin/env bash
# Build a wheel for the interpreter that runs this script.
#
#   PYTHON=python3.12 bash scripts/build-wheel.sh
#
# The file in dist/ is tagged for this CPython and this glibc
# (cp312-cp312-manylinux_2_39_x86_64, say). pip will refuse it anywhere else.
# On Linux, patchelf rewrites the binary so the Swift runtime travels
# next to it; libpython is left to the installing interpreter.
set -euo pipefail

cd "$(dirname "$0")/.."
PYTHON="${PYTHON:-python3}"

if ! command -v swift >/dev/null && [ -x "$HOME/.local/share/swiftly/bin/swift" ]; then
    PATH="$HOME/.local/share/swiftly/bin:$PATH"
fi

if [ "$(uname -s)" = Linux ] && ! command -v patchelf >/dev/null; then
    echo "peregrine: patchelf is required to make the binary relocatable" >&2
    echo "  sudo apt install patchelf" >&2
    exit 1
fi

export PEREGRINE_REQUIRE_RELOCATE="${PEREGRINE_REQUIRE_RELOCATE:-1}"

"$PYTHON" -m pip install -q --disable-pip-version-check build wheel setuptools
"$PYTHON" -m build --wheel "$@"
ls -l dist/*.whl
