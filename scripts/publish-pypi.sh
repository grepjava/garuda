#!/usr/bin/env bash
# Upload this version's wheels and sdist to PyPI.
#
#   bash scripts/publish-pypi.sh --from-latest
#   bash scripts/publish-pypi.sh --from-latest --upload
#
# Future agents: read DEPLOY.md first. This script does not bump the version
# and does not create a tag. Without --upload it only checks. With --upload
# it publishes the version in pyproject.toml; PyPI will not take that number
# twice.
set -euo pipefail

cd "$(dirname "$0")/.."

FROM_RUN=""
FROM_LATEST=0
DO_UPLOAD=0

usage() {
    cat <<'EOF'
Upload this version's wheels and sdist to PyPI.

  bash scripts/publish-pypi.sh --from-latest
  bash scripts/publish-pypi.sh --from-latest --upload

Future agents: read DEPLOY.md first. This script does not bump the version
and does not create a tag. Without --upload it only checks. With --upload
it publishes the version in pyproject.toml; PyPI will not take that number
twice.

Options:
  --from-run ID   copy wheel artifacts from that Actions run into dist/
  --from-latest   same, from the newest successful Wheels run on this branch
  --upload        twine upload (without this, print and check only)
  -h, --help      this text
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --from-run)
            [ $# -ge 2 ] || { echo "peregrine: --from-run needs a run id" >&2; exit 2; }
            FROM_RUN="$2"
            shift 2
            ;;
        --from-latest) FROM_LATEST=1; shift ;;
        --upload)      DO_UPLOAD=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)
            echo "peregrine: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -n "${PYTHON:-}" ]; then
    PY="$PYTHON"
elif [ -x "$HOME/pgvenv/bin/python" ]; then
    PY="$HOME/pgvenv/bin/python"
else
    PY="python3"
fi

VERSION=$("$PY" -c "
import pathlib, re
text = pathlib.Path('pyproject.toml').read_text()
print(re.search(r'(?m)^version\\s*=\\s*\"([^\"]+)\"', text).group(1))
")
[ -n "$VERSION" ] || { echo "peregrine: could not read version from pyproject.toml" >&2; exit 1; }

need() {
    if ! "$PY" -c "import $1" >/dev/null 2>&1; then
        "$PY" -m pip install -q --disable-pip-version-check "$1"
    fi
}

latest_run() {
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    gh run list --workflow=Wheels --status=success --branch "$branch" \
        --limit 1 --json databaseId --jq '.[0].databaseId // empty'
}

collect_wheels() {
    local run_id="$1"
    local tmp found=0 f
    command -v gh >/dev/null || { echo "peregrine: gh is required to download Actions artifacts" >&2; exit 1; }
    tmp=$(mktemp -d)
    echo "peregrine: downloading artifacts from run $run_id"
    gh run download "$run_id" --dir "$tmp"
    mkdir -p dist
    while IFS= read -r f; do
        cp -f "$f" dist/
        found=1
    done < <(find "$tmp" -type f -name "peregrine_server-${VERSION}-*.whl")
    rm -rf "$tmp"
    if [ "$found" -eq 0 ]; then
        echo "peregrine: run $run_id had no wheels for ${VERSION}" >&2
        exit 1
    fi
}

if [ "$FROM_LATEST" -eq 1 ]; then
    [ -z "$FROM_RUN" ] || { echo "peregrine: use --from-run or --from-latest, not both" >&2; exit 2; }
    FROM_RUN=$(latest_run)
    if [ -z "$FROM_RUN" ]; then
        echo "peregrine: no successful Wheels run on this branch" >&2
        echo "  gh workflow run Wheels" >&2
        echo "  gh run list --workflow=Wheels" >&2
        exit 1
    fi
fi
if [ -n "$FROM_RUN" ]; then
    collect_wheels "$FROM_RUN"
fi

need build
if [ ! -f "dist/peregrine_server-${VERSION}.tar.gz" ]; then
    echo "peregrine: building sdist for ${VERSION}"
    "$PY" -m build --sdist
fi

shopt -s nullglob
WHEELS=(dist/peregrine_server-"${VERSION}"-*.whl)
SDIST="dist/peregrine_server-${VERSION}.tar.gz"
shopt -u nullglob

if [ ! -f "$SDIST" ]; then
    echo "peregrine: sdist missing: ${SDIST}" >&2
    exit 1
fi
if [ ${#WHEELS[@]} -eq 0 ]; then
    echo "peregrine: no wheels for ${VERSION} in dist/" >&2
    echo "  bash scripts/publish-pypi.sh --from-latest" >&2
    echo "  PYTHON=python3.12 bash scripts/build-wheel.sh" >&2
    exit 1
fi

echo "peregrine: ${VERSION}"
ls -l "$SDIST" "${WHEELS[@]}"

need twine
"$PY" -m twine check "$SDIST" "${WHEELS[@]}"

if [ "$DO_UPLOAD" -eq 0 ]; then
    echo
    echo "peregrine: dry run. Re-run with --upload to publish these files."
    exit 0
fi

TOKEN="${TWINE_PASSWORD:-${PYPI_TOKEN:-}}"
if [ -z "$TOKEN" ] && [ -f .pypi-token ]; then
    TOKEN=$(tr -d '[:space:]' < .pypi-token)
fi
if [ -z "$TOKEN" ]; then
    echo "peregrine: no PyPI token." >&2
    echo "  Put a pypi-... token in .pypi-token (gitignored), or set TWINE_PASSWORD." >&2
    exit 1
fi
case "$TOKEN" in
    pypi-*) ;;
    *)
        echo "peregrine: token does not look like a PyPI API token (expected pypi-...)" >&2
        exit 1
        ;;
esac

export TWINE_USERNAME="__token__"
export TWINE_PASSWORD="$TOKEN"
echo "peregrine: uploading ${VERSION} to PyPI"
"$PY" -m twine upload --non-interactive --skip-existing "$SDIST" "${WHEELS[@]}"
echo "peregrine: uploaded ${VERSION}"
