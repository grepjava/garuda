// swift run uploads -- --port 8080
//
// Two users, with the tokens `ada-token` and `grace-token`:
//
//   curl -i -X POST --data-binary @cat.png -H 'Authorization: Bearer ada-token' \
//        -H 'Content-Type: image/png' -H 'Upload-Complete: ?1' \
//        localhost:8080/users/ada/photos
//   curl -H 'Authorization: Bearer ada-token' localhost:8080/users/ada/photos
//
// Open http://localhost:8080 for resuming an upload by hand.
//
// UPLOADS_DIR sets where uploads and photos are kept (/tmp/garuda-uploads
// unless it says otherwise); it is created if missing.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import UploadsExample

let directory = getenv("UPLOADS_DIR").map { String(cString: $0) } ?? "/tmp/garuda-uploads"
let configuration = UploadsConfiguration(directory: directory,
                                         tokens: ["ada-token": "ada", "grace-token": "grace"])
uploadsApp(configuration).run()
