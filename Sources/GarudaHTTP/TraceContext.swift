//===----------------------------------------------------------------------===//
// W3C Trace Context: reading a traceparent header.
//
// `traceparent` names the trace a request belongs to and the span that sent
// it: `version-trace_id-parent_id-flags`, in lowercase hex. Version 00 is
// exactly 55 characters. A later version may run longer, with a dash after
// the flags, so that a reader knowing only 00 can still take the fields it
// knows. Version ff is invalid, and so is a trace or parent ID of all zeros.
// A value that breaks any of this is ignored, as the specification asks.
//===----------------------------------------------------------------------===//

public enum TraceContext {
    public static let traceIDLength = 32
    public static let parentIDLength = 16
    /// Where the two IDs start in a traceparent value.
    public static let traceIDOffset = 3
    public static let parentIDOffset = 36

    /// Whether `p[0..<n]` is a traceparent value that can be read.
    public static func valid(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        guard n >= 55 else { return false }
        @inline(__always) func hex(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)
        }
        func allHex(_ from: Int, _ count: Int) -> Bool {
            var i = from
            while i < from + count {
                if !hex(p[i]) { return false }
                i += 1
            }
            return true
        }
        func allZero(_ from: Int, _ count: Int) -> Bool {
            var i = from
            while i < from + count {
                if p[i] != 0x30 { return false }
                i += 1
            }
            return true
        }
        guard allHex(0, 2), p[2] == 0x2D,
              allHex(traceIDOffset, traceIDLength), p[35] == 0x2D,
              allHex(parentIDOffset, parentIDLength), p[52] == 0x2D,
              allHex(53, 2) else { return false }
        if p[0] == 0x66 && p[1] == 0x66 { return false }           // version ff
        if p[0] == 0x30 && p[1] == 0x30 {
            if n != 55 { return false }                            // 00 is exact
        } else if n > 55 && p[55] != 0x2D {
            return false
        }
        return !allZero(traceIDOffset, traceIDLength)
            && !allZero(parentIDOffset, parentIDLength)
    }
}
