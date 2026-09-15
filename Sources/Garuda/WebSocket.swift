// WebSocket framing types kept on the connection slab. There is no
// application-level WebSocket handling yet: an upgrade request is routed like
// any other request, or refused with 501 under --no-websockets.

import GarudaHTTP

public struct WebSocketState {
    public var accepted = false
    public var closeSent = false
    public var closeReceived = false
    public var connectDelivered = false
    public var disconnectDelivered = false
    public var messageOpcode: UInt8 = 0
    public var assembling = false
    public var validator = UTF8Validator()
    public var queuedBytes = 0
    public var pingSentAt: UInt64 = 0
    public var closeCode: UInt16 = WSCloseCode.abnormal
    public var acceptKey: UnsafeMutablePointer<UInt8>? = nil
    public var deflate: WSDeflateAgreement? = nil
    public var deflater: UnsafeMutableRawPointer? = nil
    public var inflater: UnsafeMutableRawPointer? = nil
    public var messageCompressed = false

    public init() {}
}

extension Worker {
    func websocketQueueFull(_ slot: Int) -> Bool { false }

    mutating func handleWebSocketReadable(_ slot: Int) {
        closeConnection(slot)
    }

    mutating func sweepWebSocket(_ slot: Int, now: UInt64) {
        _ = now
        closeConnection(slot)
    }

    mutating func sendCloseFrame(_ slot: Int, code: UInt16,
                                 reason: UnsafePointer<UInt8>?, reasonLength: Int) {
        _ = code
        _ = reason
        _ = reasonLength
        closeConnection(slot)
    }
}
