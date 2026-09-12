"""Send Python's logging output through peregrine's logger.

Two log streams on one file descriptor is the usual arrangement and a poor one.
The server writes a level, a pid and a message -- as text or as JSON, depending
on how it was started -- and the application writes whatever `logging` was left
configured with. A collector reading the result has to guess which lines are
which, and neither half can be filtered by level without filtering both.

    import logging
    from peregrine.logging import configure

    configure()                      # root logger, the server's own level
    logging.getLogger("shop").info("checkout complete")

or, if the application already builds its logging configuration by hand:

    LOGGING = {
        "version": 1,
        "handlers": {
            "peregrine": {"class": "peregrine.logging.PeregrineHandler"},
        },
        "root": {"handlers": ["peregrine"], "level": "INFO"},
    }
    logging.config.dictConfig(LOGGING)

Outside a peregrine process -- during tests, or under another server -- the
handler falls back to stderr, so a configuration that names it does not have to
be conditional.

Nothing here touches `sys.stdout` or `sys.stderr`. Taking over a stream the
application may be writing to itself is a surprise, and `print` is not logging.
"""

import logging
import sys

__all__ = ["PeregrineHandler", "configure", "server_level"]

try:                      # Present only inside a peregrine process.
    import _peregrine
except ImportError:       # pragma: no cover - the fallback path
    _peregrine = None


# logging's levels are 10/20/30/40/50; peregrine's are 0/1/2/3. CRITICAL has no
# louder level to map to, so it shares one with ERROR: the distinction survives
# in the message, and inventing a level the server does not have would only move
# the problem.
def _to_server_level(levelno):
    if levelno >= logging.ERROR:
        return 3
    if levelno >= logging.WARNING:
        return 2
    if levelno >= logging.INFO:
        return 1
    return 0


_FROM_SERVER_LEVEL = {
    0: logging.DEBUG,
    1: logging.INFO,
    2: logging.WARNING,
    3: logging.ERROR,
    4: logging.CRITICAL + 10,     # --log-level silent: above everything
}


def server_level():
    """The server's `--log-level`, as a `logging` level.

    `logging.DEBUG` when this is not running under peregrine, so that a caller
    using it to configure a logger gets everything rather than nothing.
    """
    if _peregrine is None:
        return logging.DEBUG
    return _FROM_SERVER_LEVEL.get(_peregrine.log_level(), logging.INFO)


class PeregrineHandler(logging.Handler):
    """A logging handler that writes through the server's logger."""

    def emit(self, record):
        try:
            message = self.format(record)
        except Exception:           # noqa: BLE001 - handlers must not raise
            self.handleError(record)
            return
        if _peregrine is None:
            # Not under peregrine. The level prefix is the server's, so that a
            # test reading these lines sees the shape it will see in production.
            sys.stderr.write("%s %s\n" % (record.levelname.lower(), message))
            sys.stderr.flush()
            return
        try:
            _peregrine.log(_to_server_level(record.levelno), message)
        except Exception:           # noqa: BLE001 - handlers must not raise
            self.handleError(record)


def configure(logger=None, level=None, replace=True):
    """Points `logger` at the server's log.

    `logger` defaults to the root logger, so everything that has not been given
    a handler of its own arrives here. `level` defaults to the server's own, so
    that `--log-level warning` quiets the application to match rather than
    leaving it to a second setting that has to be kept in step.

    `replace` removes the handlers already on the logger, which is what makes
    this useful after a framework has called `basicConfig` -- Django does, and
    without this the output would simply be duplicated. Pass `replace=False` to
    add the handler alongside whatever is there.

    Returns the handler, so a caller can set a formatter on it.
    """
    logger = logging.getLogger() if logger is None else logger
    if level is None:
        level = server_level()

    if replace:
        for existing in list(logger.handlers):
            logger.removeHandler(existing)

    handler = PeregrineHandler()
    # No timestamp and no level in the format: the server writes both, and a
    # second copy of each in the message is noise. The logger name earns its
    # place, because the server has no idea which part of the application a
    # record came from.
    handler.setFormatter(logging.Formatter("%(name)s: %(message)s"))
    logger.addHandler(handler)
    logger.setLevel(level)
    return handler
