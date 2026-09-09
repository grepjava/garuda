"""Emits the RFC 7541 Huffman and static tables as Swift source.

Run once; the output is committed. The tables come from the RFC by way of the
`hpack` package, which is only a build-time convenience -- nothing in the server
depends on it.
"""

import io
import sys

from hpack.huffman_constants import REQUEST_CODES, REQUEST_CODES_LENGTH
from hpack.table import HeaderTable

out = io.StringIO()
w = out.write

w("""//===----------------------------------------------------------------------===//
// HPACK tables (RFC 7541 appendices A and B).
//
// Generated -- see scripts/gen-hpack-tables.py. Do not edit by hand.
//
// The Huffman code is canonical: within each code length the codes ascend in
// symbol order, and each length starts where the previous one left off. The
// decoder relies on that, and a unit test re-derives every code from the
// lengths alone to prove the table still has the property.
//===----------------------------------------------------------------------===//

public enum HPACKTables {

    /// Huffman code per symbol, right-aligned in a UInt32. Index 256 is EOS.
    public static let huffmanCodes: [UInt32] = [
""")

for i in range(0, 257, 6):
    row = ", ".join("0x%08x" % REQUEST_CODES[j] for j in range(i, min(i + 6, 257)))
    w("        %s,\n" % row)

w("""    ]

    /// Code length in bits per symbol, 5...30.
    public static let huffmanLengths: [UInt8] = [
""")

for i in range(0, 257, 16):
    row = ", ".join("%2d" % REQUEST_CODES_LENGTH[j] for j in range(i, min(i + 16, 257)))
    w("        %s,\n" % row)

w("""    ]

    /// The static table, RFC 7541 appendix A. Entry 1 is at index 0, so a
    /// wire index `i` names `staticTable[i - 1]`.
    public static let staticTable: [(name: String, value: String)] = [
""")

table = HeaderTable()
for name, value in table.STATIC_TABLE:
    name = name.decode()
    value = value.decode()
    w('        ("%s", "%s"),\n' % (name, value))

w("""    ]
}
""")

sys.stdout.write(out.getvalue())
