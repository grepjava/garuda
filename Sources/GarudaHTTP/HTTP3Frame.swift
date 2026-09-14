//===----------------------------------------------------------------------===//
// HTTP/3 framing constants (RFC 9114).
//
// Almost everything HTTP/2 needed from its framing layer -- stream
// identifiers, flow control, priority, resets -- QUIC already provides, so
// HTTP/3's frames are far smaller in number and carry no stream identifier at
// all: which stream a frame belongs to is a property of the stream it arrived
// on. What is left is a type, a length and a payload, all varints.
//
// The reserved types are worth spelling out. HTTP/2's frame numbers were
// deliberately not reused, and the ones that would collide are errors rather
// than unknown-and-ignored, so that a proxy which forwards HTTP/2 frames into
// an HTTP/3 connection is caught rather than half-understood.
//===----------------------------------------------------------------------===//

public enum HTTP3FrameType {
    public static let data: UInt64 = 0x00
    public static let headers: UInt64 = 0x01
    public static let cancelPush: UInt64 = 0x03
    public static let settings: UInt64 = 0x04
    public static let pushPromise: UInt64 = 0x05
    public static let goaway: UInt64 = 0x07
    public static let maxPushID: UInt64 = 0x0d
    /// draft-ietf-webtrans-http3: the first varint on a client-initiated
    /// bidirectional stream that belongs to a WebTransport session rather than
    /// carrying a request. The session identifier follows, and everything after
    /// that is the session's own bytes rather than frames.
    public static let webTransportStream: UInt64 = 0x41

    /// Frame types HTTP/2 used that HTTP/3 forbids.
    @inlinable
    public static func isReservedFromHTTP2(_ type: UInt64) -> Bool {
        type == 0x02 || type == 0x06 || type == 0x08 || type == 0x09
    }
}

public enum HTTP3StreamType {
    public static let control: UInt64 = 0x00
    public static let push: UInt64 = 0x01
    public static let qpackEncoder: UInt64 = 0x02
    public static let qpackDecoder: UInt64 = 0x03
    /// draft-ietf-webtrans-http3: a unidirectional stream belonging to a
    /// WebTransport session, whose identifier follows the type.
    public static let webTransport: UInt64 = 0x54
}

public enum HTTP3Setting {
    public static let qpackMaxTableCapacity: UInt64 = 0x01
    public static let maxFieldSectionSize: UInt64 = 0x06
    public static let qpackBlockedStreams: UInt64 = 0x07
    /// RFC 9220. Extended CONNECT is what carries both WebSocket over HTTP/3
    /// and WebTransport.
    public static let enableConnectProtocol: UInt64 = 0x08
    /// RFC 9297.
    public static let h3Datagram: UInt64 = 0x33
    /// draft-ietf-webtrans-http3.
    public static let webTransportMaxSessions: UInt64 = 0xc671_706a

    /// Settings identifiers HTTP/2 used, which HTTP/3 reserves so that a
    /// blind translation is caught.
    @inlinable
    public static func isReservedFromHTTP2(_ id: UInt64) -> Bool {
        id == 0x02 || id == 0x03 || id == 0x04 || id == 0x05
    }
}

public enum HTTP3Error {
    public static let noError: UInt64 = 0x0100
    public static let generalProtocolError: UInt64 = 0x0101
    public static let internalError: UInt64 = 0x0102
    public static let streamCreationError: UInt64 = 0x0103
    public static let closedCriticalStream: UInt64 = 0x0104
    public static let frameUnexpected: UInt64 = 0x0105
    public static let frameError: UInt64 = 0x0106
    public static let excessiveLoad: UInt64 = 0x0107
    public static let idError: UInt64 = 0x0108
    public static let settingsError: UInt64 = 0x0109
    public static let missingSettings: UInt64 = 0x010a
    public static let requestRejected: UInt64 = 0x010b
    public static let requestCancelled: UInt64 = 0x010c
    public static let requestIncomplete: UInt64 = 0x010d
    public static let messageError: UInt64 = 0x010e
    public static let connectError: UInt64 = 0x010f
    public static let versionFallback: UInt64 = 0x0110

    public static let qpackDecompressionFailed: UInt64 = 0x0200
    public static let qpackEncoderStreamError: UInt64 = 0x0201
    public static let qpackDecoderStreamError: UInt64 = 0x0202

    /// draft-ietf-webtrans-http3: the session a stream belonged to has ended.
    public static let webTransportSessionGone: UInt64 = 0x170d_7b68
    /// A stream arrived for a session that has not been established, and we
    /// were unwilling to hold it until one appeared.
    public static let webTransportBufferedStreamRejected: UInt64 = 0x3994_bd84
}

/// The capsule protocol (RFC 9297), as WebTransport uses it.
///
/// Once a CONNECT stream has been accepted it stops carrying HTTP/3 frames and
/// starts carrying capsules. The shape is the same -- a type, a length and a
/// payload, all varints -- but the numbering is a separate registry, which is
/// why these are not `HTTP3FrameType` values.
public enum HTTP3Capsule {
    /// draft-ietf-webtrans-http3: an application close code and a UTF-8 reason.
    public static let closeWebTransportSession: UInt64 = 0x2843
    /// The peer will accept no new streams but has not closed yet.
    public static let drainWebTransportSession: UInt64 = 0x78ae
}
