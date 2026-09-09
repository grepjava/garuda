"""Builds the Swift server and packages the resulting binary.

Peregrine embeds CPython rather than talking to it over a socket, so the binary
is linked against one specific libpython. That is why this project ships as a
source distribution and is compiled at install time: the interpreter it links
must be the interpreter it will run applications for, and only the installing
environment knows which one that is.

Requirements at install time:
  * a Swift toolchain (swift 6.1 or newer) on PATH
  * the Python development files for the interpreter being installed into,
    which pkg-config exposes as python3-embed (python3-dev / python3-devel)
"""

import os
import shutil
import subprocess
import sys
import sysconfig

from setuptools import setup
from setuptools.command.build_py import build_py

HERE = os.path.dirname(os.path.abspath(__file__))
BINARY = "peregrine"


def _fail(message):
    sys.stderr.write("\nperegrine: %s\n\n" % message)
    raise SystemExit(1)


def _check_toolchain():
    if shutil.which("swift") is None:
        _fail(
            "no Swift toolchain found on PATH.\n"
            "Peregrine is compiled at install time; install Swift 6.1 or newer\n"
            "from https://swift.org/install and try again."
        )
    if shutil.which("pkg-config") is None:
        _fail("pkg-config is required to locate the Python development files.")
    probe = subprocess.run(["pkg-config", "--exists", "python3-embed"])
    if probe.returncode != 0:
        _fail(
            "pkg-config cannot find python3-embed.\n"
            "Install the Python development files for this interpreter\n"
            "(python3-dev on Debian and Ubuntu, python3-devel on Fedora,\n"
            "or a python.org / Homebrew framework build on macOS)."
        )


class BuildWithSwift(build_py):
    """Compiles the server, then lets setuptools package it like any data file."""

    def run(self):
        _check_toolchain()
        scratch = os.environ.get("PEREGRINE_SCRATCH_PATH",
                                 os.path.join(HERE, ".build-install"))
        command = ["swift", "build", "-c", "release", "--scratch-path", scratch]
        sys.stderr.write("peregrine: %s\n" % " ".join(command))
        result = subprocess.run(command, cwd=HERE)
        if result.returncode != 0:
            _fail("the Swift build failed; see the output above.")

        built = os.path.join(scratch, "release", BINARY)
        if not os.path.exists(built):
            _fail("the Swift build produced no binary at %s" % built)

        super().run()

        target_dir = os.path.join(self.build_lib, "peregrine", "_bin")
        os.makedirs(target_dir, exist_ok=True)
        target = os.path.join(target_dir, BINARY)
        shutil.copy2(built, target)
        os.chmod(target, 0o755)
        # Record what this binary was linked against, so the launcher can warn
        # rather than fail obscurely when it is run under a different one.
        with open(os.path.join(target_dir, "interpreter.txt"), "w") as fh:
            fh.write("%d.%d\n" % sys.version_info[:2])
            fh.write("%s\n" % (sysconfig.get_config_var("prefix") or ""))


setup(cmdclass={"build_py": BuildWithSwift})
