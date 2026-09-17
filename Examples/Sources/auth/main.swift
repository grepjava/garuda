// swift run auth -- --port 8080 --rate-limit 10/m
//
//   curl -s localhost:8080/signup -d '{"username":"ada","password":"correct horse"}'
//   TOKEN=$(curl -s localhost:8080/login -d '{"username":"ada","password":"correct horse"}' | sed 's/.*"token":"\([^"]*\)".*/\1/')
//   curl -s localhost:8080/me -H "authorization: Bearer $TOKEN"
//
// AUTH_DATABASE sets the file; every worker opens the same one.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import AuthExample

let path = getenv("AUTH_DATABASE").map { String(cString: $0) } ?? "auth.db"
exit(authApp(databasePath: path).run())
