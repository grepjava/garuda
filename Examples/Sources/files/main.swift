//===----------------------------------------------------------------------===//
// The file service.
//
//   swift run files                     serve on :8080, storing in /tmp/garuda-files
//   swift run files -- --port 9000      the server's own flags still apply
//   FILES_DIR=/srv/files swift run files
//
// The download side is the server's static route rather than a handler, so the
// two flags for it are added to whatever the command line said: the files go
// out with sendfile, ETag, byte ranges and a listing, and the application only
// has to put them in a directory.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Garuda
import FilesExample

let directory = getenv("FILES_DIR").map { String(cString: $0) } ?? "/tmp/garuda-files"
let configuration = FilesConfiguration(directory: directory)
let app = filesApp(configuration)

// A leading `--` is what `swift run files -- --port 9000` leaves behind.
var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--" { arguments.removeFirst() }
arguments += ["--static-dir", "/files=" + configuration.storeDirectory, "--static-listing"]
exit(app.run(arguments: arguments))
