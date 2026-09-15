//===----------------------------------------------------------------------===//
// Route table: method and path bytes to a route, with its parameters.
//
// Built once, before the first fork, and never changed afterwards; every
// worker matches against the copy it inherited. A pattern is split on "/" into
// segments, each a literal, a `:name` taking one non-empty segment, or a last
// `*name` taking the rest of the path. "/" is one empty literal segment, so
// "/user" and "/user/" are different routes, as they are to a client.
//
// Matching walks the request path as it arrived -- still percent-encoded -- one
// segment at a time. At each step a literal is tried before a parameter, and a
// parameter before the rest, backtracking when a branch leads nowhere, so
// "/user/me" can sit beside "/user/:id". Nothing is allocated and nothing is
// reference counted: a parameter is an offset and a length in the path, and
// the compiled table is flat memory that is only ever read.
//===----------------------------------------------------------------------===//

import GarudaCore
import GarudaHTTP

/// The parameters a match captured, as offsets into the matched path.
public struct RouteParameters {
    public static let capacity = 8

    @usableFromInline var stored = 0
    @usableFromInline var starts = SIMD8<Int32>()
    @usableFromInline var lengths = SIMD8<Int32>()

    public init() {}

    /// How many parameters the match captured.
    @inlinable public var count: Int { stored }

    /// Where parameter `i` sits in the path it was matched against.
    @inlinable
    public subscript(i: Int) -> (start: Int, count: Int) {
        (Int(starts[i]), Int(lengths[i]))
    }

    @inlinable
    mutating func append(_ start: Int, _ length: Int) {
        starts[stored] = Int32(truncatingIfNeeded: start)
        lengths[stored] = Int32(truncatingIfNeeded: length)
        stored &+= 1
    }
}

public enum RoutePatternError: Error, Equatable {
    case mustStartWithSlash
    case emptyParameterName
    case restMustBeLast
    case tooManyParameters
    case duplicate
}

/// One position in the trie. `routes` holds a route index per method, by
/// `HTTPMethod.rawValue`, or -1.
@usableFromInline
struct RouteNode {
    @usableFromInline var edgeStart: Int32 = 0
    @usableFromInline var edgeCount: Int32 = 0
    @usableFromInline var parameter: Int32 = -1
    @usableFromInline var rest: Int32 = -1
    @usableFromInline var routes = SIMD16<Int32>(repeating: -1)
}

/// A literal segment leading to `child`: `count` bytes at `start` in the
/// byte pool.
@usableFromInline
struct RouteEdge {
    @usableFromInline var start: Int32
    @usableFromInline var count: Int32
    @usableFromInline var child: Int32
}

/// The table as it is built: ordinary arrays, since this happens once.
public struct RouteTable {
    private var nodes: [(node: RouteNode, literals: [([UInt8], Int)])] = [(RouteNode(), [])]

    public init() {}

    /// Adds `pattern` for `method` as route `route`. Returns how many
    /// parameters it captures.
    @discardableResult
    public mutating func add(_ method: HTTPMethod, _ pattern: String, route: Int32) throws -> Int {
        let utf8 = Array(pattern.utf8)
        guard utf8.first == 0x2F else { throw RoutePatternError.mustStartWithSlash }
        let segments = utf8.dropFirst().split(separator: 0x2F, omittingEmptySubsequences: false)
        var node = 0
        var parameters = 0
        for (i, segment) in segments.enumerated() {
            if segment.first == 0x3A {                      // :name
                guard segment.count > 1 else { throw RoutePatternError.emptyParameterName }
                parameters += 1
                if nodes[node].node.parameter < 0 {
                    nodes.append((RouteNode(), []))
                    nodes[node].node.parameter = Int32(nodes.count - 1)
                }
                node = Int(nodes[node].node.parameter)
            } else if segment.first == 0x2A {               // *name
                guard segment.count > 1 else { throw RoutePatternError.emptyParameterName }
                guard i == segments.count - 1 else { throw RoutePatternError.restMustBeLast }
                parameters += 1
                if nodes[node].node.rest < 0 {
                    nodes.append((RouteNode(), []))
                    nodes[node].node.rest = Int32(nodes.count - 1)
                }
                node = Int(nodes[node].node.rest)
            } else {
                let literal = Array(segment)
                if let found = nodes[node].literals.first(where: { $0.0 == literal }) {
                    node = found.1
                } else {
                    nodes.append((RouteNode(), []))
                    nodes[node].literals.append((literal, nodes.count - 1))
                    node = nodes.count - 1
                }
            }
        }
        guard parameters <= RouteParameters.capacity else { throw RoutePatternError.tooManyParameters }
        let m = Int(method.rawValue)
        guard nodes[node].node.routes[m] < 0 else { throw RoutePatternError.duplicate }
        nodes[node].node.routes[m] = route
        return parameters
    }

    /// Lays the table out as flat memory for matching. The result is never
    /// freed: it lives as long as the process serves it.
    public func compile() -> CompiledRoutes {
        let edgeTotal = nodes.reduce(0) { $0 + $1.literals.count }
        let byteTotal = nodes.reduce(0) { $0 + $1.literals.reduce(0) { $0 + $1.0.count } }
        let n = UnsafeMutablePointer<RouteNode>.allocate(capacity: nodes.count)
        let e = UnsafeMutablePointer<RouteEdge>.allocate(capacity: max(1, edgeTotal))
        let b = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, byteTotal))
        var edgeAt = 0
        var byteAt = 0
        for (i, entry) in nodes.enumerated() {
            var node = entry.node
            node.edgeStart = Int32(edgeAt)
            node.edgeCount = Int32(entry.literals.count)
            for (literal, child) in entry.literals {
                for (k, byte) in literal.enumerated() { b[byteAt + k] = byte }
                (e + edgeAt).initialize(to: RouteEdge(start: Int32(byteAt), count: Int32(literal.count),
                                                      child: Int32(child)))
                edgeAt += 1
                byteAt += literal.count
            }
            (n + i).initialize(to: node)
        }
        return CompiledRoutes(nodes: n, edges: e, bytes: b)
    }
}

/// The table as it is matched against. Three pointers, so copying it costs
/// nothing and touching it counts no references.
public struct CompiledRoutes {
    @usableFromInline let nodes: UnsafeMutablePointer<RouteNode>
    @usableFromInline let edges: UnsafeMutablePointer<RouteEdge>
    @usableFromInline let bytes: UnsafeMutablePointer<UInt8>

    init(nodes: UnsafeMutablePointer<RouteNode>, edges: UnsafeMutablePointer<RouteEdge>,
         bytes: UnsafeMutablePointer<UInt8>) {
        self.nodes = nodes
        self.edges = edges
        self.bytes = bytes
    }

    /// The route for `method` and `path`, or -1. HEAD falls back to GET.
    @inlinable
    public func match(_ method: HTTPMethod, _ path: UnsafePointer<UInt8>, _ count: Int,
                      into parameters: inout RouteParameters) -> Int32 {
        guard count > 0, path[0] == 0x2F else { return -1 }
        parameters.stored = 0
        let route = walk(0, path, 0, count, Int(method.rawValue), &parameters)
        if route >= 0 || method != .head { return route }
        parameters.stored = 0
        return walk(0, path, 0, count, Int(HTTPMethod.get.rawValue), &parameters)
    }

    /// `at` is the "/" before the next segment, or `count` when the path is
    /// used up.
    @usableFromInline
    func walk(_ index: Int, _ path: UnsafePointer<UInt8>, _ at: Int, _ count: Int,
              _ method: Int, _ parameters: inout RouteParameters) -> Int32 {
        let node = nodes[index]
        if at == count { return node.routes[method] }

        let start = at &+ 1
        var end = start
        while end < count && path[end] != 0x2F { end &+= 1 }
        let length = end &- start

        var k = Int(node.edgeStart)
        let last = k &+ Int(node.edgeCount)
        while k < last {
            let edge = edges[k]
            k &+= 1
            guard Int(edge.count) == length else { continue }
            let literal = bytes + Int(edge.start)
            var i = 0
            while i < length && literal[i] == path[start &+ i] { i &+= 1 }
            guard i == length else { continue }
            let route = walk(Int(edge.child), path, end, count, method, &parameters)
            if route >= 0 { return route }
        }

        if node.parameter >= 0 && length > 0 && parameters.count < RouteParameters.capacity {
            let saved = parameters.count
            parameters.append(start, length)
            let route = walk(Int(node.parameter), path, end, count, method, &parameters)
            if route >= 0 { return route }
            parameters.stored = saved
        }

        if node.rest >= 0 && parameters.count < RouteParameters.capacity {
            let route = nodes[Int(node.rest)].routes[method]
            if route >= 0 {
                parameters.append(start, count &- start)
                return route
            }
        }
        return -1
    }
}
