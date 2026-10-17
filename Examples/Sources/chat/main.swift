// swift run chat -- --port 8080 --shards 4
//
// Open http://localhost:8080 in two browser windows and join the same room.
// With several shards the two connections usually land on different
// processes, and still hear each other.
//
//   curl -N localhost:8080/rooms/lobby/events
//   curl -s localhost:8080/rooms/lobby/messages -d '{"name":"curl","text":"hello"}'

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif
import ChatExample

chatApp().run()
