"""Generate QUIC packet-protection vectors with aioquic, an independent
implementation, so the Swift side is checked against something that is not
itself. The two packets below are RFC 9001 appendix A.3 and A.5, so the output
is also checked against the RFC's own published bytes."""
import binascii

from cryptography.hazmat.primitives import hashes as _h

from aioquic.quic.crypto import CryptoPair, CryptoContext
from aioquic.quic.packet import QuicProtocolVersion
from aioquic.tls import hkdf_extract, hkdf_expand_label


def hx(b):
    return binascii.hexlify(b).decode()


def swift_bytes(name, b):
    body = ", ".join("0x%02x" % c for c in b)
    return "    static let %s: [UInt8] = [%s]" % (name, body)


DCID = bytes.fromhex("8394c8f03e515708")

salt = bytes.fromhex("38762cf7f55934b34d179ae6a4c80cadccbb7f0a")
initial_secret = hkdf_extract(_h.SHA256(), salt, DCID)
cs = hkdf_expand_label(_h.SHA256(), initial_secret, b"client in", b"", 32)
ss = hkdf_expand_label(_h.SHA256(), initial_secret, b"server in", b"", 32)
print("initial_secret        =", hx(initial_secret))
print("client_initial_secret =", hx(cs))
print("server_initial_secret =", hx(ss))
for nm, sec in (("client", cs), ("server", ss)):
    print("  %s key=%s iv=%s hp=%s" % (
        nm,
        hx(hkdf_expand_label(_h.SHA256(), sec, b"quic key", b"", 16)),
        hx(hkdf_expand_label(_h.SHA256(), sec, b"quic iv", b"", 12)),
        hx(hkdf_expand_label(_h.SHA256(), sec, b"quic hp", b"", 16))))

# ---- RFC 9001 A.3: the server's Initial packet -------------------------
server = CryptoPair()
server.setup_initial(cid=DCID, is_client=False, version=QuicProtocolVersion.VERSION_1)

# c1 | version | dcid(0) | scid(8) | token(0) | length=117 | pn=0x3a83
plain_header = bytes.fromhex("c1000000010008f067a5502a4262b50040753a83")
plain_payload = bytes.fromhex(
    "02000000000600405a020000560303ee"
    "fce7f7b37ba1d1632e96677825ddf739"
    "88cfc79825df566dc5430b9a045a1200"
    "130100002e00330024001d00209d3c94"
    "0d89690b84d08a60993c144eca684d10"
    "81287c834d5311bcf32bb9da1a002b00"
    "020304"
)
assert len(plain_payload) == 99, len(plain_payload)
encrypted = server.encrypt_packet(plain_header, plain_payload, 0x3a83)
RFC_A3 = ("cf000000010008f067a5502a4262b5004075c0d95a482cd0991cd25b0aac406a58"
          "16b6394100f37a1c69797554780bb38cc5a99f5ede4cf73c3ec2493a1839b3dbc"
          "ba3f6ea46c5b7684df3548e7ddeb9c3bf9c73cc3f3bded74b562bfb19fb84022f"
          "8ef4cdd93795d77d06edbb7aaf2f58891850abbdca3d20398c276456cbc421584"
          "07dd074ee")
print("")
print("# server initial packet")
print("  packet  =", hx(encrypted))
print("  matches RFC A.3:", hx(encrypted).startswith(RFC_A3))

# ---- RFC 9001 A.5: ChaCha20-Poly1305, short header ---------------------
secret = bytes.fromhex("9ac312a7f877468ebe69422748ad00a1"
                       "5443f18203a07d6060f688f30f21632b")
ctx = CryptoContext()
ctx.setup(cipher_suite=0x1303, secret=secret, version=QuicProtocolVersion.VERSION_1)
enc = ctx.encrypt_packet(bytes.fromhex("4200bff4"), bytes.fromhex("01"), 654360564)
print("")
print("# chacha20 short header")
print("  packet =", hx(enc))
print("  matches RFC A.5:", hx(enc) == "4cfe4189655e5cd55c41f69080575d7999c25a5bfb")

print("")
print("# ---- swift ----")
print(swift_bytes("serverInitialHeader", plain_header))
print(swift_bytes("serverInitialPayload", plain_payload))
print(swift_bytes("serverInitialPacket", encrypted))
print(swift_bytes("chachaSecret", secret))
print(swift_bytes("chachaPacket", enc))
