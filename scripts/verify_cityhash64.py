#!/usr/bin/env python3
"""CityHash64 — constants must match IDA _hidden_1946_ @ 0x101092DEC."""
import struct

k0 = 0x9DDEEA08EB382D69
k1 = 0xB492B66FBE98F273
k2 = 0x9AE16A3B2F90404F
k3 = 0x622015F714C7D297
kMul = 0x4B6D499041670D8D


def u64(x):
    return x & 0xFFFFFFFFFFFFFFFF


def fetch64(s, i):
    return struct.unpack_from("<Q", s, i)[0]


def fetch32(s, i):
    return struct.unpack_from("<I", s, i)[0]


def rotate(val, shift):
    val = u64(val)
    if shift == 0:
        return val
    return u64((val >> shift) | (val << (64 - shift)))


def hash_len16(u, v):
    return u64(k0 * (u ^ v) ^ ((k0 * (u ^ v)) >> 47) ^ v)


def hash_len0to16(s):
    length = len(s)
    if length >= 8:
        mul = u64(k0 * length)
        a = u64(fetch64(s, 0) + k0)
        b = fetch64(s, length - 8)
        c = u64(mul + rotate(b, length)) ^ a
        return u64(hash_len16(c, b) ^ mul)
    if length >= 4:
        mul = u64(k0 * length)
        a = fetch32(s, 0)
        return u64(hash_len16(length + (a << 3), fetch32(s, length - 4)) ^ mul)
    if length:
        a, b, c = s[0], s[length >> 1], s[length - 1]
        y = u64(k0 * a + k2 * (b + length * c))
        return u64(k0 * (y ^ (y >> 47)) ^ k2)
    return k2


def hash_len17to32(s):
    length = len(s)
    mul = u64(k0 * length)
    a = u64(fetch64(s, 0) * k0)
    b = fetch64(s, length - 8)
    c = rotate(b, length + 8) ^ a
    d = rotate(a, length) ^ b
    return u64(hash_len16(c, d) ^ mul)


def hash_len33to64(s):
    length = len(s)
    mul = u64(k0 * length)
    a = u64(fetch64(s, 0) * k0)
    b = fetch64(s, 8)
    c = u64(fetch64(s, length - 8) * kMul)
    d = u64(fetch64(s, length - 16) * k2)
    e = u64(fetch64(s, 16) * k0)
    f = u64(fetch64(s, 24) * k1)
    g = u64(rotate(a + b, 43) + rotate(c, 30) + d)
    h = u64(rotate(e + f, 42) + g)
    return u64(hash_len16(h, rotate(c + d, 33) + a + e) ^ mul)


def cityhash64(s: bytes) -> int:
    n = len(s)
    if n <= 16:
        return hash_len0to16(s)
    if n <= 32:
        return hash_len17to32(s)
    if n <= 64:
        return hash_len33to64(s)
    raise NotImplementedError("len > 64 — use long CityHash64 from binary")


def hex_filename(s: bytes) -> str:
    """Matches std::ostream with ios_base::hex (flag 0x8) then operator<<(uint64)."""
    return format(cityhash64(s), "x") + ".png"


if __name__ == "__main__":
    # IDA _hidden_1947_ empty-string return @ 0x1010930BC
    assert cityhash64(b"") == 0x9AE16A3B2F90404F, "empty hash must match IDA"

    tests = [
        b"achievement.buildWorkBench",
        b"buildWorkBench",
        b"MinutesPlayed",
    ]
    for t in tests:
        print(f"{t.decode()!r} -> {cityhash64(t):016x} -> {hex_filename(t)}")

    print("on-disk example: 1bab08e8eff4f340.png (Xbox id string UNRESOLVED)")
