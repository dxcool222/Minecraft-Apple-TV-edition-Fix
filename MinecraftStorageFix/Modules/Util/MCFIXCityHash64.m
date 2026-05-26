//
//  MCFIXCityHash64.m — CityHash64 + NSString filename helper for achievement icons.
//

#import "MCFIXCityHash64.h"
#import <Foundation/Foundation.h>
#import <string.h>

static const uint64_t k0 = 0x9DDEEA08EB382D69ULL;
static const uint64_t k1 = 0xB492B66FBE98F273ULL;
static const uint64_t k2 = 0x9AE16A3B2F90404FULL;
static const uint64_t kMul = 0x4B6D499041670D8DULL;

static inline uint64_t u64(uint64_t x) {
    return x;
}

static inline uint64_t fetch64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, sizeof(v));
    return v;
}

static inline uint32_t fetch32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, sizeof(v));
    return v;
}

static inline uint64_t rotate(uint64_t val, int shift) {
    if (shift == 0) {
        return val;
    }
    return u64((val >> shift) | (val << (64 - shift)));
}

static uint64_t hash_len16(uint64_t u, uint64_t v) {
    uint64_t x = u64(k0 * (u ^ v));
    return u64((x ^ (x >> 47)) ^ v);
}

static uint64_t hash_len0to16(const uint8_t *s, size_t length) {
    if (length >= 8) {
        uint64_t mul = u64(k0 * length);
        uint64_t a = u64(fetch64(s) + k0);
        uint64_t b = fetch64(s + length - 8);
        uint64_t c = u64(mul + rotate(b, (int)length)) ^ a;
        return u64(hash_len16(c, b) ^ mul);
    }
    if (length >= 4) {
        uint64_t mul = u64(k0 * length);
        uint32_t a = fetch32(s);
        return u64(hash_len16(length + ((uint64_t)a << 3), fetch32(s + length - 4)) ^ mul);
    }
    if (length > 0) {
        uint8_t a = s[0];
        uint8_t b = s[length >> 1];
        uint8_t c = s[length - 1];
        uint64_t y = u64(k0 * a + k2 * (b + length * c));
        return u64((k0 * (y ^ (y >> 47))) ^ k2);
    }
    return k2;
}

static uint64_t hash_len17to32(const uint8_t *s, size_t length) {
    uint64_t mul = u64(k0 * length);
    uint64_t a = u64(fetch64(s) * k0);
    uint64_t b = fetch64(s + length - 8);
    uint64_t c = rotate(b, (int)length + 8) ^ a;
    uint64_t d = rotate(a, (int)length) ^ b;
    return u64(hash_len16(c, d) ^ mul);
}

static uint64_t hash_len33to64(const uint8_t *s, size_t length) {
    uint64_t mul = u64(k0 * length);
    uint64_t a = u64(fetch64(s) * k0);
    uint64_t b = fetch64(s + 8);
    uint64_t c = u64(fetch64(s + length - 8) * kMul);
    uint64_t d = u64(fetch64(s + length - 16) * k2);
    uint64_t e = u64(fetch64(s + 16) * k0);
    uint64_t f = u64(fetch64(s + 24) * k1);
    uint64_t g = u64(rotate(a + b, 43) + rotate(c, 30) + d);
    uint64_t h = u64(rotate(e + f, 42) + g);
    return u64(hash_len16(h, rotate(c + d, 33) + a + e) ^ mul);
}

uint64_t MCFIXCityHash64(const void *data, size_t len) {
    const uint8_t *s = (const uint8_t *)data;
    if (len <= 16) {
        return hash_len0to16(s, len);
    }
    if (len <= 32) {
        return hash_len17to32(s, len);
    }
    if (len <= 64) {
        return hash_len33to64(s, len);
    }
    return hash_len33to64(s, 64);
}
