#!/usr/bin/env python3
"""demo/bigip-cookie.py <value> [...]: decode an unencrypted BIG-IP persistence cookie value (IPv4, default route domain), e.g.
201331722.20480.0000 -> 10.20.0.12:80 (part 7). The address is the member's IPv4 as a 32-bit integer stored byte by byte in
reverse (little-endian); the port is the 16-bit port with its two bytes swapped; the last field is reserved (0000)."""
import socket, struct, sys
for v in sys.argv[1:]:
    v = v.split("=", 1)[-1]
    a, p, _ = v.split(".")
    ip = socket.inet_ntoa(struct.pack("<I", int(a)))
    port = struct.unpack("<H", struct.pack(">H", int(p)))[0]
    print(f"{v}\n  address {int(a)} = 0x{int(a):08X} -> bytes reversed -> {ip}\n  port    {int(p)} = 0x{int(p):04X} -> bytes swapped -> {port}\n  member  {ip}:{port}")
