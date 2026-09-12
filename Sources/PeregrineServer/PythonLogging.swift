//===----------------------------------------------------------------------===//
// Putting Python's logging output into the server's log.
//
// Two log streams on one file descriptor is the usual arrangement and it is a
// poor one: the server writes structured lines with a level and a pid, the
// application writes whatever logging.basicConfig left it with, and a collector
// parsing the result has to guess which is which -- or gets JSON on some lines
// and not others. Neither half can be filtered by level without filtering both.
//
// The bridge is one callable, installed into the `_peregrine` module at
// start-up, that writes a line through `Log`. `peregrine.logging` on the Python
// side is a logging.Handler that calls it, so `dictConfig` can name it like any
// other handler and the application keeps using `logging.getLogger(...)`.
//
// What it deliberately is not: a redirection of `sys.stdout`. Taking over a
// stream the application may be using for its own output is a surprise, and
// print() is not logging.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrinePython

extension Peregrine {

    /// Installs the logging bridge into the `_peregrine` module.
    ///
    /// Once per interpreter, during boot, before the application is imported --
    /// so that a module-level `logging` call in the application is already
    /// going to the right place.
    static func installPythonLogging() {
        guard let install = Interpreter.glueFunction("_install_log") else { return }
        guard let sink = PyTrampoline.make(pythonLogSink, context: 0) else {
            pg_err_clear()
            return
        }
        defer { pg_decref(sink) }
        guard let level = pg_int(Int(Log.level.rawValue)) else {
            pg_err_clear()
            return
        }
        defer { pg_decref(level) }
        if let result = pg_call2(install, sink, level) {
            pg_decref(result)
        } else {
            pg_err_clear()
            Log.warn("could not install the Python logging bridge")
        }
    }
}

/// `(level: int, message: str) -> None`, called from Python.
///
/// The level is clamped rather than validated: this is called from a logging
/// handler, and a bad level is not worth turning into an exception that hides
/// the message somebody was trying to record.
private func pythonLogSink(_ context: UInt64, _ args: PyObj?) -> PyObj? {
    guard let args, pg_tuple_size(args) >= 2 else { return nil }
    guard let levelObj = pg_tuple_get(args, 0), let messageObj = pg_tuple_get(args, 1) else {
        return nil
    }

    let raw = pg_int_as_long(levelObj)
    let level: LogLevel
    switch raw {
    case ..<1:  level = .debug
    case 1:     level = .info
    case 2:     level = .warning
    default:    level = .error
    }
    guard Log.enabled(level) else { return nil }

    var length: pg_ssize_t = 0
    guard let bytes = pg_str_utf8_data(messageObj, &length) else {
        pg_err_clear()
        return nil
    }
    let count = Int(length)
    Log.emit(level) { line in
        bytes.withMemoryRebound(to: UInt8.self, capacity: count) { p in
            // One line per record. A message carrying newlines -- a traceback,
            // most often -- would otherwise produce something a line-oriented
            // collector reads as several records of unknown level.
            var start = 0
            var i = 0
            while i < count {
                if p[i] == 0x0A {
                    line.bytes(p + start, i - start)
                    if i + 1 < count { line.str(" | ") }
                    start = i + 1
                }
                i += 1
            }
            if start < count { line.bytes(p + start, count - start) }
        }
    }
    return nil
}
