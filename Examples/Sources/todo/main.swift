// swift run todo -- --port 8080
//
//   curl -s localhost:8080/todos -d '{"title":"write the docs"}'
//   curl -s localhost:8080/todos
//   curl -s -X PATCH localhost:8080/todos/1 -d '{"done":true}'
//
// TODO_DATABASE sets the file; every worker opens the same one.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import TodoExample

let path = getenv("TODO_DATABASE").map { String(cString: $0) } ?? "todos.db"
exit(todoApp(databasePath: path).run())
