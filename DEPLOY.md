<p align="center">
  <img src="assets/peregrine-cursive-segoe.png" alt="peregrine" width="480">
</p>

# Deploying Peregrine

How a version reaches PyPI. The engine is built here; `pip` only sees what
this file describes.

PyPI does not watch GitHub. A tag on `main` is a source snapshot. Until
someone uploads, `pip install peregrine-server` is the last sdist that was
published — today that still compiles, because no wheel has been uploaded
yet.

A version, once accepted, cannot be replaced. Yanking hides it; it does not
free the number. Get the artifacts right before `--upload`.

---

## What is published

Two kinds of file, always the same version as `pyproject.toml`:

| Artifact | Who needs it |
|---|---|
| **Wheels** (`cp312-cp312-manylinux_2_39_x86_64`, `cp314-cp314t-...`) | anyone whose interpreter, ABI and glibc match; Swift is not required |
| **sdist** (`peregrine_server-X.Y.Z.tar.gz`) | everyone else; `pip` compiles it against the installing interpreter |

A wheel vendors the Swift runtime and leaves `libpython` to the user's
interpreter. The platform tag is `manylinux_2_N` for the builder's glibc
(Ubuntu 24.04 is `2_39`). PyPI rejects `linux_*`; it will not take a wheel
that still has that tag. Older glibc compiles from the sdist. macOS wheels
are not built yet.

The GitHub Actions publish job uploads **wheels only**. The script below
uploads the sdist as well. Use the script.

---

## What you need

| | |
|---|---|
| **A version that is not on PyPI** | bump, commit, tag, push first |
| **Linux wheels for that version** | `gh workflow run Wheels`, or `scripts/build-wheel.sh` per interpreter |
| **An sdist** | the publish script builds one if `dist/` has none |
| **A PyPI API token** | in `.pypi-token` at the repo root, or in `TWINE_PASSWORD` / `PYPI_TOKEN` |

`.pypi-token` is gitignored on purpose. It is a publishing credential. If it
ever lands in history, rotate it; rewriting commits does not unsay a token
that was pushed.

Create one at [pypi.org/manage/account/token](https://pypi.org/manage/account/token/).
The file is one line, `pypi-...`. Username is `__token__`; twine already
knows that.

---

## The sequence

### 1. Bump the version

The same string, everywhere people or packaging will read it:

* `pyproject.toml` — `version`
* `python/peregrine/__init__.py` — `__version__`
* `Sources/peregrine/main.swift` — the `peregrine X.Y.Z` `StaticString`
* the `--version` examples in `INSTALLATION.md` and `CONFIG.md`

PyPI classifiers stay at Production/Stable unless the release is a
deliberate step backwards.

### 2. Commit, tag, push

```bash
git tag v1.0.1
git push origin HEAD
git push origin v1.0.1
gh release create v1.0.1 --title "1.0.1" --notes "..."
```

The tag is what GitHub shows. It is not what `pip` installs.

### 3. Build the Linux wheels

```bash
gh workflow run Wheels --ref v1.0.1
gh run watch
```

Five jobs: 3.11, 3.12, 3.13, 3.14, 3.14t on Ubuntu 24.04. Each artifact is
one wheel. Leave `publish` off — that input skips the sdist.

A single interpreter, locally:

```bash
PYTHON=python3.12 bash scripts/build-wheel.sh
```

Needs Swift, `patchelf`, and the development files for that interpreter.
`PEREGRINE_SCRATCH_PATH` points the Swift build at a native disk when the
checkout is on `/mnt/d`.

### 4. Upload

Dry run first. It builds the sdist if needed, pulls wheels from Actions if
you ask, and prints what would go up. Nothing reaches PyPI without
`--upload`.

```bash
# wheels from the newest successful Wheels run on this branch
bash scripts/publish-pypi.sh --from-latest

# or a specific run
bash scripts/publish-pypi.sh --from-run 123456789

# or wheels you already put in dist/
bash scripts/publish-pypi.sh
```

Then, when the list is the version you meant and the files you meant:

```bash
bash scripts/publish-pypi.sh --from-latest --upload
```

`--upload` is idempotent on a retry (`twine --skip-existing`). It cannot
overwrite a file PyPI already accepted.

---

## After it lands

```bash
pip index versions peregrine-server
python3 -m pip download peregrine-server==1.0.1 --only-binary=:all: -d /tmp/pgcheck
```

A matching wheel installs in seconds and `peregrine --version` agrees with
the tag. A machine with no wheel for its tag still compiles the sdist, and
still needs Swift.

---

## When it goes wrong

**`file already exists`** — that version is on PyPI. Bump. Do not try to
edit the tag and re-upload.

**`invalid or non-existent authentication`** — `.pypi-token` is missing,
truncated, or a project token scoped to the wrong package. The script
refuses a token that does not start with `pypi-`.

**`--from-latest` found no run** — the Wheels workflow has not succeeded on
this branch. `gh run list --workflow=Wheels` is the authority.

**A wheel is tagged for the wrong interpreter** — `setup.py` asks the
binary, not the headers. Rebuild with `pkg-config` pointed at the
interpreter you intend to serve; do not retag the file.

**You uploaded wheels and forgot the sdist** — run the script again against
the same version. `--skip-existing` leaves the wheels alone and sends the
tarball.
