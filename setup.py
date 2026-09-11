"""Builds the Swift server and packages the resulting binary.

Peregrine embeds CPython rather than talking to it over a socket, so the binary
is linked against one specific libpython. A prebuilt wheel is therefore tagged
for the exact CPython and platform it was built against
(`cp312-cp312-linux_x86_64`, `cp314-cp314t-...`) so pip refuses it anywhere it
would not actually run. When no wheel matches, pip falls back to the sdist and
this file compiles the server against the installing interpreter.

The wheel does not vendor libpython -- that would fight the interpreter the
user already has. It does vendor the Swift runtime next to the binary, with a
relative rpath, so a machine that has never seen this toolchain can still
exec the server.

Requirements when compiling (sdist or `scripts/build-wheel.sh`):
  * a Swift toolchain (swift 6.1 or newer) on PATH
  * the Python development files for the interpreter being installed into,
    which pkg-config exposes as python3-embed (python3-dev / python3-devel)
  * patchelf on Linux, so the binary can be made relocatable
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


def _same_release(pkg_version, running):
    """Whether two version strings name the same CPython release.

    Major and minor and nothing else. The free-threaded suffix is deliberately
    ignored here: it describes an ABI rather than a release, and pkg-config
    does not report it even when the headers it found are the free-threaded
    ones.
    """
    def numbers(text):
        match = re.match(r"(\d+)\.(\d+)", text)
        return match.groups() if match else None

    left, right = numbers(pkg_version), numbers(running)
    return left is not None and left == right


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
    # Only the numbers are comparable here. A free-threaded interpreter calls
    # itself "3.14t", because the suffix is a different ABI with a different
    # SONAME -- but its own python3-embed.pc says "3.14", exactly as the GIL
    # build's does. Comparing the two strings rejected the very pairing the
    # check exists to accept: a free-threaded interpreter and its own headers.
    # Which ABI was actually linked is settled after the build instead, by
    # asking the binary, which is the one authority that cannot be wrong.
    if resolved and not _same_release(resolved, _running_version()):
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
    env = os.environ.copy()
    libdir = sysconfig.get_config_var("LIBDIR")
    if libdir:
        key = "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
        env[key] = libdir + os.pathsep + env.get(key, "")
    result = subprocess.run(
        [binary, "--version"], capture_output=True, text=True, env=env)
    match = re.search(r"CPython (\d+)\.(\d+)([^)]*)", result.stdout)
    if not match:
        return None
    suffix = "t" if "free-threaded" in match.group(3) else ""
    return "%s.%s%s" % (match.group(1), match.group(2), suffix)


# The Swift runtime travels with the binary. libpython, libssl and the rest of
# the OS do not -- they belong to the machine that runs the wheel.
_BUNDLE_HINTS = ("swift", "dispatch", "blocksruntime")
_NEVER_BUNDLE = (
    "libpython", "libssl", "libcrypto", "libc.so", "libm.so", "libdl.so",
    "libpthread", "librt.so", "libgcc", "libstdc++", "ld-linux",
    "linux-vdso", "libz.so", "libxml2", "libicu", "libcurl", "libbsd",
    "libedit", "libncurses", "libsqlite", "liblzma", "libffi", "libsystem",
)


def _require_relocate():
    return os.environ.get("PEREGRINE_REQUIRE_RELOCATE", "").strip() not in ("", "0")


def _should_bundle(name, path):
    # Match against the SONAME / basename, from the start. A substring
    # check on the whole line would skip libswiftGlibc.so because
    # "libc.so" sits inside "glibc.so".
    base = os.path.basename(name or path).lower()
    if any(base == token or base.startswith(token) for token in _NEVER_BUNDLE):
        return False
    haystack = ("%s %s" % (base, path)).lower()
    return any(token in haystack for token in _BUNDLE_HINTS)


def _linux_runtime_paths(binary):
    """SONAME -> resolved path for every Swift library ldd can see."""
    try:
        output = subprocess.check_output(
            ["ldd", binary], text=True, stderr=subprocess.STDOUT)
    except (OSError, subprocess.CalledProcessError) as exc:
        _fail("ldd could not read %s: %s" % (binary, exc))
    found = {}
    for line in output.splitlines():
        if "=>" not in line:
            continue
        soname, _, rest = line.strip().partition("=>")
        path = rest.strip().split()[0]
        if path in ("", "not"):
            continue
        soname = soname.strip()
        if _should_bundle(soname, path) and os.path.isfile(path):
            found[soname] = path
    return found


def _macos_runtime_paths(binary):
    """install name -> resolved path for every Swift library otool can see."""
    try:
        output = subprocess.check_output(
            ["otool", "-L", binary], text=True, stderr=subprocess.STDOUT)
    except (OSError, subprocess.CalledProcessError) as exc:
        _fail("otool could not read %s: %s" % (binary, exc))
    found = {}
    for line in output.splitlines()[1:]:
        path = line.strip().split()[0]
        if path.startswith("/usr/lib/") or path.startswith("/System/"):
            continue
        if not os.path.isfile(path):
            continue
        name = os.path.basename(path)
        if _should_bundle(name, path):
            found[path] = path
    return found


def _copy_runtime(binary, resolved):
    lib_dir = os.path.join(os.path.dirname(binary), "lib")
    os.makedirs(lib_dir, exist_ok=True)
    copied = []
    for name, path in resolved.items():
        dest = os.path.join(lib_dir, os.path.basename(name))
        shutil.copy2(path, dest)
        copied.append(dest)
    return lib_dir, copied


def _relocate_linux(binary):
    if shutil.which("patchelf") is None:
        message = (
            "patchelf is required to make the binary relocatable.\n"
            "Install it (patchelf on Debian and Ubuntu) and try again."
        )
        if _require_relocate():
            _fail(message)
        sys.stderr.write("peregrine: %s\n" % message)
        return
    resolved = _linux_runtime_paths(binary)
    if not resolved:
        message = "ldd found no Swift runtime libraries to vendor next to %s" % binary
        if _require_relocate():
            _fail(message)
        sys.stderr.write("peregrine: %s\n" % message)
        return
    lib_dir, copied = _copy_runtime(binary, resolved)
    subprocess.check_call(["patchelf", "--set-rpath", "$ORIGIN/lib", binary])
    for path in copied:
        subprocess.check_call(["patchelf", "--set-rpath", "$ORIGIN", path])
    sys.stderr.write(
        "peregrine: vendored %d Swift libraries into %s\n" % (len(copied), lib_dir)
    )


def _relocate_macos(binary):
    resolved = _macos_runtime_paths(binary)
    if not resolved:
        message = "otool found no Swift runtime libraries to vendor next to %s" % binary
        if _require_relocate():
            _fail(message)
        sys.stderr.write("peregrine: %s\n" % message)
        return
    lib_dir, copied = _copy_runtime(binary, resolved)
    # -add_rpath fails if the path is already there; that is not an error.
    add = subprocess.run(
        ["install_name_tool", "-add_rpath", "@loader_path/lib", binary],
        capture_output=True, text=True)
    if add.returncode != 0 and "would duplicate" not in (add.stderr or ""):
        _fail("install_name_tool -add_rpath failed: %s" % add.stderr.strip())
    for original, dest in zip(resolved.values(), copied):
        name = os.path.basename(dest)
        subprocess.check_call(
            ["install_name_tool", "-id", "@rpath/%s" % name, dest])
        subprocess.check_call(
            ["install_name_tool", "-change", original,
             "@loader_path/lib/%s" % name, binary])
    sys.stderr.write(
        "peregrine: vendored %d Swift libraries into %s\n" % (len(copied), lib_dir)
    )


def _relocate(binary):
    """Vendors the Swift runtime next to the binary and rewrites its rpath.

    A wheel has to run on a machine that has never seen this toolchain.
    libpython stays with the user's interpreter -- the tag already promised
    that pairing.
    """
    if sys.platform.startswith("linux"):
        _relocate_linux(binary)
    elif sys.platform == "darwin":
        _relocate_macos(binary)
    elif _require_relocate():
        _fail("relocating the binary is not implemented on %s" % sys.platform)
    else:
        sys.stderr.write("peregrine: skipping relocate on %s\n" % sys.platform)


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

        # A wheel has to run on a machine that has never seen this Swift
        # toolchain. libpython stays with the user's interpreter -- the tag
        # already promised that pairing -- and the Swift runtime travels
        # next to the binary with a relative rpath.
        _relocate(target)
        relocated = _linked_version(target)
        if relocated != linked:
            _fail(
                "the relocated binary no longer reports Python %s "
                "(got %s). The Swift runtime may not have been vendored."
                % (linked, relocated)
            )


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
