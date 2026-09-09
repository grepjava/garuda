"""Builds the Swift server and packages the resulting binary.

Peregrine embeds CPython rather than talking to it over a socket, so the binary
is linked against one specific libpython. That is why this project ships as a
source distribution and is compiled at install time: the interpreter it links
must be the interpreter it will run applications for, and only the installing
environment knows which one that is.

That also decides how the wheel is tagged. Setuptools sees a pure-Python
package containing a data file and would tag it `py3-none-any`, which claims
the artifact works on any interpreter on any platform -- the opposite of the
truth for a native executable with a hard libpython dependency. The wheel is
therefore tagged for the exact CPython and platform it was built against, so
pip refuses it anywhere it would not actually run.

Requirements at install time:
  * a Swift toolchain (swift 6.1 or newer) on PATH
  * the Python development files for the interpreter being installed into,
    which pkg-config exposes as python3-embed (python3-dev / python3-devel)
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

try:                                    # setuptools >= 70.1 vendors its own
    from setuptools.command.bdist_wheel import bdist_wheel
except ImportError:                     # older setuptools defers to `wheel`
    try:
        from wheel.bdist_wheel import bdist_wheel
    except ImportError:
        bdist_wheel = None

HERE = os.path.dirname(os.path.abspath(__file__))
BINARY = "peregrine"


def _fail(message):
    sys.stderr.write("\nperegrine: %s\n\n" % message)
    raise SystemExit(1)


def _free_threaded():
    """True when this interpreter is a free-threaded build (PEP 703)."""
    return bool(sysconfig.get_config_var("Py_GIL_DISABLED"))


def _running_version():
    """The interpreter this build must produce a binary for.

    A free-threaded build is "3.14t", not "3.14". The suffix is not cosmetic:
    it is a different ABI with a different SONAME, so a binary linked against
    one cannot load the other, and a wheel that claimed otherwise would install
    happily and then fail at exec time.
    """
    return "%d.%d%s" % (sys.version_info[0], sys.version_info[1],
                        "t" if _free_threaded() else "")


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
    # pkg-config decides what Swift links, and it is not obliged to point at
    # the interpreter running this build. Catching that here gives a clear
    # message instead of a wheel that fails at import time.
    version = subprocess.run(["pkg-config", "--modversion", "python3-embed"],
                             capture_output=True, text=True)
    resolved = version.stdout.strip()
    if resolved and not resolved.startswith(_running_version()):
        _fail(
            "pkg-config resolves python3-embed to Python %s, but this build is\n"
            "running under Python %s. The server would embed the wrong\n"
            "interpreter. Install the development files for %s, or run pip\n"
            "from the interpreter you intend to serve with."
            % (resolved, _running_version(), _running_version())
        )


def _linked_version(binary):
    """Asks the built binary which libpython it actually bound.

    The authority is the binary, not pkg-config and not the headers: it reports
    Py_GetVersion() from the library the loader resolved.
    """
    result = subprocess.run([binary, "--version"], capture_output=True, text=True)
    match = re.search(r"CPython (\d+)\.(\d+)([^)]*)", result.stdout)
    if not match:
        return None
    suffix = "t" if "free-threaded" in match.group(3) else ""
    return "%s.%s%s" % (match.group(1), match.group(2), suffix)


class BinaryDistribution(Distribution):
    """Tells setuptools the package is platform-specific despite having no
    Python extension modules of its own."""

    def has_ext_modules(self):
        return True

    def is_pure(self):
        return False


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

        linked = _linked_version(built)
        if linked is None:
            _fail("the built binary did not report its embedded interpreter; "
                  "it may not have linked correctly.")
        if linked != _running_version():
            _fail(
                "the built binary embeds Python %s but this build is running\n"
                "under Python %s. The wheel would be tagged for the wrong\n"
                "interpreter and the server would serve applications with a\n"
                "different Python than the one its dependencies are installed\n"
                "for." % (linked, _running_version())
            )

        super().run()

        target_dir = os.path.join(self.build_lib, "peregrine", "_bin")
        os.makedirs(target_dir, exist_ok=True)
        target = os.path.join(target_dir, BINARY)
        shutil.copy2(built, target)
        os.chmod(target, 0o755)
        # Recorded from the binary itself, so the launcher warns against the
        # interpreter that is really embedded rather than the one that built it.
        with open(os.path.join(target_dir, "interpreter.txt"), "w") as fh:
            fh.write("%s\n" % linked)
            fh.write("%s\n" % (sysconfig.get_config_var("prefix") or ""))


if bdist_wheel is not None:

    class BinaryWheel(bdist_wheel):
        """Tags the wheel for the one interpreter and platform it can run on."""

        def finalize_options(self):
            super().finalize_options()
            self.root_is_pure = False

        def get_tag(self):
            _, _, platform_tag = super().get_tag()
            # cp312-cp312-<platform>: the bundled executable is dynamically
            # linked against this exact libpython, so anything else is a
            # mis-install rather than a graceful degradation.
            #
            # A free-threaded interpreter takes the same interpreter tag and a
            # distinct ABI tag -- cp314-cp314t -- which is what stops pip from
            # installing a GIL-built wheel into python3.14t, and the other way
            # round. They really are different binaries.
            interpreter = "cp%d%d" % sys.version_info[:2]
            abi = interpreter + ("t" if _free_threaded() else "")
            return interpreter, abi, platform_tag

    COMMANDS = {"build_py": BuildWithSwift, "bdist_wheel": BinaryWheel}
else:
    COMMANDS = {"build_py": BuildWithSwift}


setup(cmdclass=COMMANDS, distclass=BinaryDistribution)
