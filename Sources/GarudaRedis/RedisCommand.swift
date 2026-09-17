//===----------------------------------------------------------------------===//
// Writing commands, and the few exchanges a connection has before it is used.
//
// A command is always an array of bulk strings, whatever its arguments are.
// No argument is ever written inline, so no value -- a key holding a newline,
// a payload that looks like another command -- can be taken for protocol.
//===----------------------------------------------------------------------===//

import AvianCore

/// A value that can be an argument to a command.
public protocol RedisArgument {
    /// Appends the argument's bytes.
    func appendRedisArgument(to bytes: inout [UInt8])
}

extension String: RedisArgument {
    public func appendRedisArgument(to bytes: inout [UInt8]) { bytes.append(contentsOf: utf8) }
}

extension Substring: RedisArgument {
    public func appendRedisArgument(to bytes: inout [UInt8]) { bytes.append(contentsOf: utf8) }
}

extension Array: RedisArgument where Element == UInt8 {
    public func appendRedisArgument(to bytes: inout [UInt8]) { bytes.append(contentsOf: self) }
}

extension Int: RedisArgument {
    public func appendRedisArgument(to bytes: inout [UInt8]) { bytes.append(contentsOf: String(self).utf8) }
}

extension Int64: RedisArgument {
    public func appendRedisArgument(to bytes: inout [UInt8]) { bytes.append(contentsOf: String(self).utf8) }
}

extension UInt64: RedisArgument {
    public func appendRedisArgument(to bytes: inout [UInt8]) { bytes.append(contentsOf: String(self).utf8) }
}

extension Double: RedisArgument {
    public func appendRedisArgument(to bytes: inout [UInt8]) {
        // Redis reads inf and -inf; Swift writes them the same way.
        bytes.append(contentsOf: String(self).utf8)
    }
}

extension Bool: RedisArgument {
    public func appendRedisArgument(to bytes: inout [UInt8]) { bytes.append(self ? 49 : 48) }
}

/// One command, as the arguments it will be written with.
public struct RedisCommand: Sendable, Equatable {
    public private(set) var arguments: [[UInt8]]

    public init(_ name: String, arguments: [any RedisArgument]) {
        self.arguments = [Array(name.utf8)]
        self.arguments.reserveCapacity(arguments.count + 1)
        for argument in arguments { append(argument) }
    }

    public init(_ name: String, _ arguments: any RedisArgument...) {
        self.init(name, arguments: arguments)
    }

    public mutating func append(_ argument: any RedisArgument) {
        var bytes: [UInt8] = []
        argument.appendRedisArgument(to: &bytes)
        arguments.append(bytes)
    }

    /// The command's name, upper-cased, for deciding how to treat its reply.
    public var name: String {
        String(decoding: arguments[0].map { $0 >= 97 && $0 <= 122 ? $0 - 32 : $0 }, as: UTF8.self)
    }

    /// Appends the command as RESP: `*n`, then `$len` and the bytes of each
    /// argument.
    public func write(into out: inout ByteBuffer) {
        writeHeader(UInt8(ascii: "*"), arguments.count, into: &out)
        for argument in arguments {
            writeHeader(UInt8(ascii: "$"), argument.count, into: &out)
            argument.withUnsafeBufferPointer { p in
                if let base = p.baseAddress, p.count > 0 { out.write(base, p.count) }
            }
            out.writeByte(13)
            out.writeByte(10)
        }
    }

    public func bytes() -> [UInt8] {
        var out = ByteBuffer(capacity: 64)
        defer { out.destroy() }
        write(into: &out)
        return Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
    }

    private func writeHeader(_ type: UInt8, _ n: Int, into out: inout ByteBuffer) {
        out.writeByte(type)
        out.writeDecimal(n)
        out.writeByte(13)
        out.writeByte(10)
    }
}

// MARK: - Starting a connection

/// What the caller should do after handing the handshake a reply.
public enum RedisStep: Equatable, Sendable {
    /// Write this command, then hand over its reply.
    case send(RedisCommand)
    /// The connection is ready for commands.
    case ready
}

/// Why a connection could not start.
public enum RedisHandshakeError: Error, Equatable, Sendable {
    /// The server refused to authenticate: a wrong password, no such user.
    case authentication(RedisServerError)
    /// The server refused the database, or another setup command.
    case refused(RedisServerError)
    /// A reply the handshake did not expect.
    case unexpectedReply
}

/// HELLO 3 with the credentials, which leaves the connection speaking RESP3.
/// A server too old for HELLO -- Redis before 6 -- is spoken to in RESP2,
/// with AUTH. Then the name, if one is set, and the database, if not 0.
public struct RedisHandshake {
    public let username: String?
    public let password: String?
    public let clientName: String?
    public let database: Int

    public private(set) var protocolVersion = 3
    /// What HELLO said about the server: `version`, `mode`, `role`.
    public private(set) var server: [String: String] = [:]

    private enum Stage { case hello, auth, setName, select, done }
    private var stage = Stage.hello

    public init(username: String? = nil, password: String? = nil, clientName: String? = nil,
                database: Int = 0) {
        self.username = username
        self.password = password
        self.clientName = clientName
        self.database = database
    }

    public mutating func start() -> RedisCommand {
        stage = .hello
        var hello = RedisCommand("HELLO", 3)
        if let password {
            hello.append("AUTH")
            hello.append(username ?? "default")
            hello.append(password)
        }
        if let clientName {
            hello.append("SETNAME")
            hello.append(clientName)
        }
        return hello
    }

    /// Handles the reply to the command last sent.
    public mutating func receive(_ reply: RedisValue) throws(RedisHandshakeError) -> RedisStep {
        switch stage {
        case .hello:
            if case .error(let error) = reply {
                // HELLO itself unknown: a server older than RESP3. Anything
                // else -- WRONGPASS, NOAUTH -- is the answer.
                guard error.message.lowercased().hasPrefix("err unknown command") else {
                    if error.code == "NOPROTO" {
                        // A server that knows HELLO and not version 3.
                        return try downgrade()
                    }
                    throw .authentication(error)
                }
                return try downgrade()
            }
            guard let pairs = reply.pairs else { throw .unexpectedReply }
            for pair in pairs {
                guard let key = pair.key.string else { continue }
                if let value = pair.value.string { server[key] = value }
            }
            return next(after: .setName)
        case .auth:
            if case .error(let error) = reply { throw .authentication(error) }
            return next(after: .auth)
        case .setName:
            if case .error(let error) = reply { throw .refused(error) }
            return next(after: .setName)
        case .select:
            if case .error(let error) = reply { throw .refused(error) }
            stage = .done
            return .ready
        case .done:
            throw .unexpectedReply
        }
    }

    private mutating func downgrade() throws(RedisHandshakeError) -> RedisStep {
        protocolVersion = 2
        if let password {
            stage = .auth
            if let username { return .send(RedisCommand("AUTH", username, password)) }
            return .send(RedisCommand("AUTH", password))
        }
        return nextAfterAuth()
    }

    private mutating func nextAfterAuth() -> RedisStep {
        // HELLO carries the name; over RESP2 it takes a command of its own.
        if let clientName {
            stage = .setName
            return .send(RedisCommand("CLIENT", "SETNAME", clientName))
        }
        return nextAfterName()
    }

    private mutating func nextAfterName() -> RedisStep {
        if database != 0 {
            stage = .select
            return .send(RedisCommand("SELECT", database))
        }
        stage = .done
        return .ready
    }

    private mutating func next(after finished: Stage) -> RedisStep {
        switch finished {
        case .auth: return nextAfterAuth()
        default: return nextAfterName()
        }
    }
}
