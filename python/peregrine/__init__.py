"""Peregrine -- a Python ASGI/WSGI server written in Swift.

This package is a thin launcher. The server itself is a native binary that
embeds CPython, so there is no Python-level server loop to import; what lives
here is the logic for finding that binary and starting it with the right
interpreter and environment.
"""

import os
import sys
import sysconfig

__version__ = "0.1.0"
__all__ = ["binary_path", "run", "main"]

_BIN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_bin")


def binary_path():
    """Absolute path to the peregrine binary, or None when it is missing."""
    candidate = os.path.join(_BIN_DIR, "peregrine")
    return candidate if os.path.exists(candidate) else None


def built_for():
    """The Python the binary was linked against, as "3.13" or "3.13t".

    The "t" marks a free-threaded build (PEP 703). It is part of the answer
    because it is a different ABI, not a runtime setting: a binary embedding
    3.14t cannot be served by 3.14 or the reverse.
    """
    try:
        with open(os.path.join(_BIN_DIR, "interpreter.txt")) as fh:
            return fh.readline().strip()
    except OSError:
        return None


def _running_version():
    return "%d.%d%s" % (sys.version_info[0], sys.version_info[1],
                        "t" if sysconfig.get_config_var("Py_GIL_DISABLED") else "")


def _virtualenv():
    """The active virtualenv, or None.

    An installed peregrine is normally *inside* the environment it should
    serve, so sys.prefix is the answer whenever it differs from the base
    installation. VIRTUAL_ENV is honoured too, for the case where the binary
    was installed globally.
    """
    prefix = getattr(sys, "prefix", None)
    base = getattr(sys, "base_prefix", prefix)
    if prefix and base and os.path.abspath(prefix) != os.path.abspath(base):
        return prefix
    return os.environ.get("VIRTUAL_ENV") or None


def _default_arguments(argv):
    """Fills in what the launcher knows and the user did not say."""
    extra = []
    if not any(a == "--venv" or a == "--no-auto-venv" for a in argv):
        venv = _virtualenv()
        if venv:
            extra += ["--venv", venv]
    # The application almost always lives in the directory the user is in.
    if not any(a == "--python-path" for a in argv):
        extra += ["--python-path", os.getcwd()]
    return extra


def run(argv=None):
    """Replaces this process with the server. Does not return on success."""
    argv = list(sys.argv[1:] if argv is None else argv)
    binary = binary_path()
    if binary is None:
        raise SystemExit(
            "peregrine: the server binary is missing from %s.\n"
            "The package is compiled at install time; reinstall it from source\n"
            "with a Swift toolchain available." % _BIN_DIR
        )

    linked = built_for()
    running = _running_version()
    if linked and linked != running:
        sys.stderr.write(
            "peregrine: warning: this binary embeds Python %s but you are "
            "running it from Python %s.\nThe application will be served by "
            "Python %s.\n" % (linked, running, linked)
        )

    command = [binary] + _default_arguments(argv) + argv
    os.execv(binary, command)


def main():
    run()
