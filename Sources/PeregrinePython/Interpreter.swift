//===----------------------------------------------------------------------===//
// Interpreter start-up, application loading, and the small Python glue module.
//
// The glue is deliberately tiny. Anything on the request path is written in
// Swift against the C API; the Python here only does things that would take
// twenty C-API calls to express and that run once per process or once per
// request completion (task creation, exception formatting, loop setup).
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

public enum AppProtocol: UInt8, Sendable {
    case wsgi, asgi
}

public enum Interpreter {

    /// Python source for the `_peregrine` helper module. Raw string literal so
    /// nothing in it is interpreted by Swift.
    private static let glueSource = #"""
import asyncio
import inspect
import sys
import traceback


def detect_protocol(app):
    """Classify a callable as a WSGI or an ASGI application."""
    target = app
    offset = 0
    if not (inspect.isfunction(app) or inspect.ismethod(app)):
        call = getattr(type(app), '__call__', None)
        if call is not None:
            target = call
            offset = 1          # discount the implicit self
    if inspect.iscoroutinefunction(target):
        return 'asgi'
    try:
        sig = inspect.signature(target)
    except (TypeError, ValueError):
        return 'asgi'
    n = -offset
    for p in sig.parameters.values():
        if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD):
            if p.default is p.empty:
                n += 1
        elif p.kind == p.VAR_POSITIONAL:
            return 'asgi'
    # WSGI takes (environ, start_response); ASGI takes (scope, receive, send).
    return 'wsgi' if n == 2 else 'asgi'


def new_loop(prefer_uvloop):
    if prefer_uvloop:
        try:
            import uvloop
            return uvloop.new_event_loop()
        except Exception:
            pass
    return asyncio.new_event_loop()


def run_loop(loop, pollfd, drain):
    """Drive the loop, with the server poller registered as a readable fd.

    This is the whole cross-runtime integration: our epoll/kqueue descriptor is
    itself pollable, so asyncio watches it like any socket and calls back into
    Swift when connections become ready. One thread, one loop, no queues, no
    cross-thread wakeups, and no GIL ping-pong.
    """
    asyncio.set_event_loop(loop)
    loop.add_reader(pollfd, drain)
    try:
        loop.run_forever()
    finally:
        try:
            loop.remove_reader(pollfd)
        except Exception:
            pass


def stop_loop(loop):
    loop.call_soon(loop.stop)


def arm_timer(loop, callback):
    # Periodic housekeeping (idle timeouts, drain completion) rides on the
    # loop timer wheel rather than a dedicated timerfd, which keeps the whole
    # server on one wakeup source.
    loop.call_later(0.2, callback)


def spawn(loop, coro, done_cb):
    task = loop.create_task(coro)
    task.add_done_callback(done_cb)
    return task


def resolve(fut, value):
    if not fut.done():
        fut.set_result(value)


def fail(fut, exc):
    if not fut.done():
        fut.set_exception(exc)


def task_error(task):
    """Return a formatted traceback for a failed task, or None."""
    if task.cancelled():
        return None
    exc = task.exception()
    if exc is None:
        return None
    return ''.join(traceback.format_exception(type(exc), exc, exc.__traceback__))


class FileWrapper:
    """The optional wsgi.file_wrapper. Chunked iteration over a file object."""

    __slots__ = ('filelike', 'blksize')

    def __init__(self, filelike, blksize=65536):
        self.filelike = filelike
        self.blksize = blksize

    def __iter__(self):
        read = self.filelike.read
        size = self.blksize
        while True:
            data = read(size)
            if not data:
                break
            yield data

    def close(self):
        close = getattr(self.filelike, 'close', None)
        if close is not None:
            close()


def run_until(loop, coro):
    return loop.run_until_complete(coro)


class Lifespan:
    """Drives the ASGI lifespan protocol.

    Kept in Python because it is pure coordination that runs twice per process:
    once at startup and once at shutdown. Expressing it through the C API would
    be a great deal of code for no measurable gain.
    """

    def __init__(self, app, root_path):
        self.app = app
        self.state = {}
        self.scope = {
            'type': 'lifespan',
            'asgi': {'version': '3.0', 'spec_version': '2.0'},
            'root_path': root_path,
            'state': self.state,
        }
        self.queue = asyncio.Queue()
        self.started = asyncio.Event()
        self.stopped = asyncio.Event()
        self.error = None
        self.unsupported = False
        self.task = None

    async def receive(self):
        return await self.queue.get()

    async def send(self, message):
        kind = message['type']
        if kind == 'lifespan.startup.complete':
            self.started.set()
        elif kind == 'lifespan.startup.failed':
            self.error = message.get('message') or 'startup failed'
            self.started.set()
        elif kind == 'lifespan.shutdown.complete':
            self.stopped.set()
        elif kind == 'lifespan.shutdown.failed':
            self.error = message.get('message') or 'shutdown failed'
            self.stopped.set()

    async def _run(self):
        try:
            await self.app(self.scope, self.receive, self.send)
        except BaseException:
            # An application that does not implement lifespan raises as soon as
            # it sees the scope type. That is not an error, just an opt-out.
            self.unsupported = True
        finally:
            self.started.set()
            self.stopped.set()

    async def startup(self):
        self.task = asyncio.ensure_future(self._run())
        await self.queue.put({'type': 'lifespan.startup'})
        try:
            await asyncio.wait_for(self.started.wait(), 30)
        except asyncio.TimeoutError:
            return 'lifespan startup timed out'
        return self.error

    async def shutdown(self, timeout=30.0):
        if self.unsupported:
            return None
        await self.queue.put({'type': 'lifespan.shutdown'})
        timed_out = False
        try:
            await asyncio.wait_for(self.stopped.wait(), timeout)
        except asyncio.TimeoutError:
            timed_out = True
        if self.task is not None and not self.task.done():
            # The application said what it had to say but left the lifespan
            # coroutine parked, so cancel it. Awaiting that cancellation is a
            # courtesy and not an obligation: an application that suppresses
            # CancelledError would otherwise hold the process open for as long
            # as it liked, which is the deadline this is here to keep.
            self.task.cancel()
            _, alive = await asyncio.wait({self.task}, timeout=timeout)
            if alive:
                sys.stderr.write(
                    '[warn]  lifespan task ignored cancellation and was '
                    'abandoned\n')
        if timed_out:
            return 'lifespan shutdown timed out'
        return self.error


def finish(loop, lifespan, timeout_ms):
    """Shut the loop down in the order an application expects.

    Request tasks first, with a deadline: whatever is still running when it
    expires is cancelled and awaited, so cancellation is actually delivered
    rather than merely requested. Only then does the lifespan get its shutdown
    event -- the reverse order would cancel the lifespan task itself and the
    application would never run the code after its `yield`.
    """
    timeout = max(0.0, timeout_ms / 1000.0)
    deadline = timeout if timeout > 0 else 5.0
    ls = lifespan if lifespan is not None and lifespan is not Ellipsis else None
    if isinstance(ls, dict) or not hasattr(ls, 'shutdown'):
        ls = None
    ls_task = getattr(ls, 'task', None) if ls is not None else None

    async def _run():
        current = asyncio.current_task()
        pending = [t for t in asyncio.all_tasks()
                   if not t.done() and t is not current and t is not ls_task]
        if pending:
            if timeout > 0:
                _, still = await asyncio.wait(pending, timeout=timeout)
            else:
                still = set(pending)
            if still:
                for t in still:
                    t.cancel()
                # Cancellation is a request, not a guarantee. An application
                # that catches CancelledError and carries on would hold the
                # loop open for ever, so the cancellation phase gets its own
                # bound and whatever survives it is abandoned.
                _, alive = await asyncio.wait(still, timeout=deadline)
                if alive:
                    sys.stderr.write(
                        '[warn]  %d task(s) ignored cancellation and were '
                        'abandoned\n' % len(alive))
        if ls is not None:
            return await ls.shutdown(deadline)
        return None

    async def _close_asyncgens():
        # shutdown_asyncgens() throws GeneratorExit into every live async
        # generator, and a finally block that swallows it -- or merely awaits
        # something slow -- waits here for ever. Same rule as everywhere else
        # in this function: ask, wait a bounded time, then move on.
        task = asyncio.ensure_future(loop.shutdown_asyncgens())
        _, alive = await asyncio.wait({task}, timeout=deadline)
        if alive:
            task.cancel()
            sys.stderr.write(
                '[warn]  async generator shutdown did not finish in time\n')

    try:
        result = loop.run_until_complete(_run())
    finally:
        try:
            loop.run_until_complete(_close_asyncgens())
        except BaseException:
            pass
        try:
            loop.close()
        except Exception:
            pass
    return result


def activate_venv(path):
    """Make a virtualenv importable from the embedded interpreter.

    The embedded libpython is whichever one peregrine was linked against, so a
    virtualenv only works if it was built for the same minor version. Saying so
    explicitly beats an ImportError three frames into the application.
    """
    import os
    import site
    import sys

    if not path:
        return None
    if not os.path.isdir(path):
        return 'no such virtualenv: ' + path

    found = []
    lib = os.path.join(path, 'lib')
    if os.path.isdir(lib):
        for name in sorted(os.listdir(lib)):
            candidate = os.path.join(lib, name, 'site-packages')
            if os.path.isdir(candidate):
                found.append((name, candidate))
    win = os.path.join(path, 'Lib', 'site-packages')
    if os.path.isdir(win):
        found.append(('python%d.%d' % sys.version_info[:2], win))

    if not found:
        return 'no site-packages directory under ' + path

    want = 'python%d.%d' % sys.version_info[:2]
    if not any(name == want for name, _ in found):
        have = ', '.join(name for name, _ in found)
        return ('virtualenv %s was built for %s but the embedded interpreter is %s'
                % (path, have, want))

    # A virtualenv that does not include system site packages means exactly
    # that, and one that does still expects its own packages to win.
    include_system = True
    config = os.path.join(path, 'pyvenv.cfg')
    if os.path.isfile(config):
        with open(config) as fh:
            for line in fh:
                key, _, value = line.partition('=')
                if key.strip() == 'include-system-site-packages':
                    include_system = value.strip().lower() == 'true'

    before = list(sys.path)
    for name, directory in found:
        if name == want:
            site.addsitedir(directory)

    # addsitedir appends, which would leave a system-wide package shadowing the
    # virtualenv copy -- so installing a dependency into the environment would
    # silently have no effect. Whatever it added belongs in front instead.
    added = [p for p in sys.path if p not in before]
    rest = [p for p in sys.path if p not in added]
    if not include_system:
        root = os.path.abspath(path)
        rest = [p for p in rest
                if not (('site-packages' in p or 'dist-packages' in p)
                        and not os.path.abspath(p).startswith(root))]
    sys.path[:] = added + rest

    sys.prefix = path
    sys.exec_prefix = path
    return None
"""#

    nonisolated(unsafe) public private(set) static var glue: PyObj! = nil
    nonisolated(unsafe) public private(set) static var sysStderr: PyObj! = nil

    /// Boots CPython. `program` and `home` may be nil.
    public static func initialize(program: UnsafePointer<CChar>?,
                                  home: UnsafePointer<CChar>?,
                                  isolated: Bool) -> Bool {
        if pg_py_init(program, home, isolated ? 1 : 0) != 0 {
            Log.error("failed to initialise the Python interpreter")
            return false
        }
        guard let mod = pg_py_exec_module("_peregrine", glueSource) else {
            PyError.logPending("loading the peregrine support module")
            return false
        }
        glue = mod
        guard Interned.initialize() else {
            PyError.logPending("interning protocol constants")
            return false
        }
        guard let sys = pg_py_import("sys") else {
            PyError.logPending("importing sys")
            return false
        }
        sysStderr = pg_getattr(sys, "stderr")
        pg_decref(sys)
        if sysStderr == nil {
            PyError.logPending("reading sys.stderr")
            return false
        }
        return true
    }

    public static func finalize() {
        pg_py_finalize()
    }

    @discardableResult
    public static func addSysPath(_ dir: UnsafePointer<CChar>) -> Bool {
        pg_py_add_syspath(dir) == 0
    }

    /// Fetches a named function from the glue module. Borrowed reference held
    /// for the life of the process.
    public static func glueFunction(_ name: UnsafePointer<CChar>) -> PyObj? {
        guard let f = pg_getattr(glue, name) else {
            PyError.logPending("looking up a peregrine helper")
            return nil
        }
        return f   // intentionally leaked: process-lifetime singleton
    }

    /// Resolves `"module:attribute"` (or `"module.attribute"`) to a callable.
    ///
    /// Returns an owned reference.
    public static func loadApplication(_ spec: UnsafePointer<CChar>) -> PyRef {
        // Split on the first ':'; fall back to the last '.' so both
        // "app:application" and "app.application" work.
        var length = 0
        while spec[length] != 0 { length += 1 }
        var split = -1
        var i = 0
        while i < length {
            if spec[i] == 58 { split = i; break }   // ':'
            i += 1
        }
        if split < 0 {
            var j = length - 1
            while j > 0 {
                if spec[j] == 46 { split = j; break }   // '.'
                j -= 1
            }
        }

        if split <= 0 {
            // A bare module name: import it and look for a conventional
            // attribute rather than failing outright.
            guard let mod = pg_py_import(spec) else {
                PyError.logPending("importing the application module")
                return PyRef()
            }
            defer { pg_decref(mod) }
            for candidate in ["application", "app", "asgi", "wsgi"] {
                if pg_hasattr(mod, candidate) == 1 {
                    return PyRef(stealing: pg_getattr(mod, candidate))
                }
            }
            Log.error("module has no application/app attribute; use module:attribute")
            return PyRef()
        }

        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: length + 1) { buf in
            let p = buf.baseAddress!
            memcpy(p, spec, split)
            p[split] = 0
            guard let mod = pg_py_import(p) else {
                PyError.logPending("importing the application module")
                return PyRef()
            }
            defer { pg_decref(mod) }

            // Walk the remaining dotted path.
            var current = PyRef(retaining: mod)
            var start = split + 1
            while start < length {
                var end = start
                while end < length && spec[end] != 46 { end += 1 }
                let n = end - start
                memcpy(p, spec + start, n)
                p[n] = 0
                let next = pg_getattr(current.borrowed, p)
                if next == nil {
                    PyError.logPending("resolving the application attribute")
                    return PyRef()
                }
                current = PyRef(stealing: next)
                start = end + 1
            }
            return current
        }
    }

    /// Asks the glue module whether an application speaks WSGI or ASGI.
    public static func detectProtocol(_ app: PyObj) -> AppProtocol {
        guard let fn = pg_getattr(glue, "detect_protocol") else {
            PyError.logPending("detect_protocol")
            return .asgi
        }
        defer { pg_decref(fn) }
        guard let result = pg_call1(fn, app) else {
            PyError.logPending("detecting the application protocol")
            return .asgi
        }
        defer { pg_decref(result) }
        var n: pg_ssize_t = 0
        guard let s = pg_str_utf8_data(result, &n) else { return .asgi }
        return (n == 4 && s[0] == 119) ? .wsgi : .asgi   // 'w'
    }
}
