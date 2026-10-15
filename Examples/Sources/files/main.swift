// swift run files -- --port 8080
//
//   curl -s -X POST --data-binary @photo.jpg -H 'Upload-Complete: ?1' \
//        -H 'Content-Disposition: attachment; filename="photo.jpg"' localhost:8080/files
//   curl -s localhost:8080/files/
//   curl -s -r 0-1023 localhost:8080/files/photo.jpg
//   curl -s -X DELETE localhost:8080/files/photo.jpg
//
// FILES_DIR sets where uploads and files are kept (/tmp/garuda-files unless
// it says otherwise); it is created if missing.
//
// The download side is the server's static route rather than a handler, so
// the flags for it are added to whatever the command line said: the files go
// out with sendfile, ETag, byte ranges and a listing, and the application
// only has to put them in a directory.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import FilesExample

let directory = getenv("FILES_DIR").map { String(cString: $0) } ?? "/tmp/garuda-files"
let configuration = FilesConfiguration(directory: directory)
let app = filesApp(configuration)

let route = configuration.staticDirectory
app.run(arguments: CommandLine.arguments
            + ["--static-dir", route.prefix + "=" + route.directory, "--static-listing"])
