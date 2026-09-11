#!/usr/bin/env python3
"""setupdist.py -- Builds pre-compiled binary wheels for PyPI distribution.

Unlike setup.py (which compiles from source at \pip install\ time), this script
is run by the maintainer/CI to produce pre-built, platform- and ABI-tagged
binary wheels (.whl) for Linux (including WSL) and macOS.

Usage:
    # Build a wheel for the current interpreter (e.g. python3.14t):
    python3.14t setupdist.py bdist_wheel

    # Optionally package existing pre-built binary:
    PEREGRINE_BINARY=/path/to/release/peregrine python3.14t setupdist.py bdist_wheel

The resulting wheel is placed in dist/ and is tagged specifically:
    Linux / WSL: peregrine_server-1.0.0-cp314-cp314t-linux_x86_64.whl
    macOS:       peregrine_server-1.0.0-cp314-cp314t-macosx_14_0_arm64.whl
"""

import os
import re
import shutil
import subprocess
import sys
import sysconfig

from setuptools import setup
from setuptools.command.build_py import build_py
from setuptools.dist import Distribution

try:
    from setuptools.command.bdist_wheel import bdist_wheel
except ImportError:
    try:
        from wheel.bdist_wheel import bdist_wheel
    except ImportError:
        sys.stderr.write("setupdist: wheel package required. Run: pip install wheel\n")
        raise SystemExit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
BINARY = "peregrine"


def _fail(message):
    sys.stderr.write("\nsetupdist: %s\n\n" % message)
    raise SystemExit(1)


def _free_threaded():
    """True when this interpreter is a free-threaded build (PEP 703)."""
    return bool(sysconfig.get_config_var("Py_GIL_DISABLED"))


def _running_version():
    return "%d.%d%s" % (
        sys.version_info[0],
        sys.version_info[1],
        "t" if _free_threaded() else "",
    )


def _linked_version(binary_path):
    """Asks the built binary which libpython it actually bound."""
    result = subprocess.run([binary_path, "--version"], capture_output=True, text=True)
    match = re.search(r"CPython (\d+)\.(\d+)([^)]*)", result.stdout)
    if not match:
        return None
    suffix = "t" if "free-threaded" in match.group(3) else ""
    return "%s.%s%s" % (match.group(1), match.group(2), suffix)


class BinaryDistribution(Distribution):
    def has_ext_modules(self):
        return True

    def is_pure(self):
        return False


class BuildBinaryWheel(build_py):
    """Packages the pre-compiled or freshly built Swift binary into the wheel."""

    def run(self):
        target_bin = os.environ.get("PEREGRINE_BINARY")
        if target_bin and os.path.isfile(target_bin):
            built = target_bin
            sys.stderr.write("setupdist: using pre-built binary from %s\n" % built)
        else:
            if shutil.which("swift") is None:
                _fail(
                    "swift toolchain not found on PATH.\n"
                    "Install Swift 6.1 or provide PEREGRINE_BINARY=/path/to/binary"
                )
            scratch = os.environ.get(
                "PEREGRINE_SCRATCH_PATH", os.path.join(HERE, ".build-dist")
            )
            command = ["swift", "build", "-c", "release", "--scratch-path", scratch]
            sys.stderr.write("setupdist: %s\n" % " ".join(command))
            result = subprocess.run(command, cwd=HERE)
            if result.returncode != 0:
                _fail("the Swift build failed.")
            built = os.path.join(scratch, "release", BINARY)

        if not os.path.exists(built):
            _fail("binary not found at %s" % built)

        linked = _linked_version(built)
        if linked is None:
            _fail("could not determine embedded Python version from %s --version" % built)
        if linked != _running_version():
            _fail(
                "binary embeds Python %s, but running under Python %s.\n"
                "The wheel would carry the wrong ABI tag." % (linked, _running_version())
            )

        super().run()

        target_dir = os.path.join(self.build_lib, "peregrine", "_bin")
        os.makedirs(target_dir, exist_ok=True)
        dest_binary = os.path.join(target_dir, BINARY)
        shutil.copy2(built, dest_binary)
        os.chmod(dest_binary, 0o755)

        with open(os.path.join(target_dir, "interpreter.txt"), "w") as fh:
            fh.write("%s\n" % linked)
            fh.write("%s\n" % (sysconfig.get_config_var("prefix") or ""))

        sys.stderr.write("setupdist: packaged %s for Python %s\n" % (BINARY, linked))


class TaggedBinaryWheel(bdist_wheel):
    """Produces the exact wheel tags matching the Python ABI and platform."""

    def finalize_options(self):
        super().finalize_options()
        self.root_is_pure = False

    def get_tag(self):
        _, _, platform_tag = super().get_tag()
        interpreter = "cp%d%d" % sys.version_info[:2]
        abi = interpreter + ("t" if _free_threaded() else "")
        return interpreter, abi, platform_tag


if __name__ == "__main__":
    setup(
        cmdclass={"build_py": BuildBinaryWheel, "bdist_wheel": TaggedBinaryWheel},
        distclass=BinaryDistribution,
    )
