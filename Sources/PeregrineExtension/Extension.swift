//===----------------------------------------------------------------------===//
// peregrine._native: the server as a CPython extension module.
//
// The executable embeds libpython. This is the other way round: python starts,
// imports this module, and calls serve() with a command line, which runs the
// same parser and the same supervisor as the executable. Only the source of
// the interpreter changes -- the python that imported the module rather than
// libpython3.x.so. A distribution python is a statically linked,
// position-dependent executable, and framework code runs measurably faster in
// one than in a shared library; see BENCHMARKS.md.
//
// Built with PEREGRINE_EXTENSION=1, by scripts/build-extension.sh.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import CPeregrine
import PeregrineServer

@_cdecl("PyInit__native")
public func pyInitNative() -> OpaquePointer? {
    let serve: @convention(c) (OpaquePointer?, OpaquePointer?) -> OpaquePointer? = nativeServe
    return pg_native_module_create(unsafeBitCast(serve, to: UnsafeMutableRawPointer.self))
}

/// `serve(argv)`: runs the server and returns its exit status.
///
/// It returns only in the supervisor. A worker is a child forked inside this
/// call and it exits from inside it too, finalizing the interpreter on the way
/// out exactly as a worker of the executable does.
///
/// The arguments are copied into memory that is never freed: the configuration
/// keeps pointers into them for the life of the process, and `--static-dir`
/// writes into its own.
private func nativeServe(_ module: OpaquePointer?, _ arg: OpaquePointer?) -> OpaquePointer? {
    guard let list = arg, pg_is_list(list) != 0 else {
        pg_err_set_str(pg_exc_type(), "serve() takes the command line as a list of str")
        return nil
    }
    let count = Int(pg_list_size(list))
    let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: count + 1)
    for k in 0..<count {
        var length: pg_ssize_t = 0
        guard let item = pg_list_get(list, pg_ssize_t(k)), pg_is_str(item) != 0,
              let text = pg_str_utf8_data(item, &length) else {
            if pg_err_check() == 0 {
                pg_err_set_str(pg_exc_type(), "serve() takes the command line as a list of str")
            }
            return nil
        }
        argv[k] = strdup(text)
    }
    argv[count] = nil
    return pg_int(Int(PeregrineCLI.main(argc: count, argv: argv)))
}
