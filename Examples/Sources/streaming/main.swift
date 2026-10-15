// swift run streaming -- --port 8080
//
//   curl -N localhost:8080/countdown?from=5
//   curl -s localhost:8080/export.csv?rows=1000000 | tail -1
//   curl -s -T photo.jpg localhost:8080/uploads/photo.jpg     (up to 64 MiB)
//
// UPLOAD_DIRECTORY sets where uploads go; it is created if missing.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import StreamingExample

let directory = getenv("UPLOAD_DIRECTORY").map { String(cString: $0) } ?? "uploads"
mkdir(directory, 0o755)
streamingApp(uploadDirectory: directory).run()
