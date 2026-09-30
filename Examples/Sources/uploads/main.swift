//===----------------------------------------------------------------------===//
// Photo uploads, per user and resumable.
//
//   swift run uploads                        serve on :8080, storing in /tmp/garuda-uploads
//   swift run uploads -- --port 9000         the server's own flags still apply
//   UPLOADS_DIR=/srv/photos swift run uploads
//
// Two users, with the tokens `ada-token` and `grace-token`:
//
//   curl -i -X POST --data-binary @cat.png -H 'Authorization: Bearer ada-token' \
//        -H 'Content-Type: image/png' -H 'Upload-Complete: ?1' \
//        localhost:8080/users/ada/photos
//   curl -H 'Authorization: Bearer ada-token' localhost:8080/users/ada/photos
//
// Open http://localhost:8080 for resuming an upload by hand.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Garuda
import UploadsExample

let directory = getenv("UPLOADS_DIR").map { String(cString: $0) } ?? "/tmp/garuda-uploads"
let configuration = UploadsConfiguration(directory: directory,
                                         tokens: ["ada-token": "ada", "grace-token": "grace"])
exit(uploadsApp(configuration).run())
