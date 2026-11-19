// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef DYNARIUM_NATIVE_BRIDGE_H
#define DYNARIUM_NATIVE_BRIDGE_H

#include <errno.h>
#include <os/proc.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/clonefile.h>
#include <zlib.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline int dynarium_zlib_init_gzip(z_stream* strm)
{
    return inflateInit2(strm, MAX_WBITS + 32);
}

static inline int dynarium_zlib_init_raw(z_stream* strm)
{
    return inflateInit2(strm, -MAX_WBITS);
}

static inline int dynarium_zlib_inflate(z_stream* strm, int flush)
{
    return inflate(strm, flush);
}

static inline int dynarium_zlib_inflate_end(z_stream* strm)
{
    return inflateEnd(strm);
}

static inline int dynarium_apfs_clonefile(const char* src, const char* dst)
{
    return clonefile(src, dst, 0) == 0 ? 0 : errno;
}

static inline uint64_t dynarium_available_memory_bytes(void)
{
    return (uint64_t)os_proc_available_memory();
}

static inline bool dynarium_is_all_zero(const void* ptr, size_t len)
{
    const uint8_t* p = (const uint8_t*)ptr;
    while (len >= sizeof(uint64_t)) {
        uint64_t v = 0;
        __builtin_memcpy(&v, p, sizeof(v));
        if (v != 0)
            return false;
        p += sizeof(uint64_t);
        len -= sizeof(uint64_t);
    }
    while (len > 0) {
        if (*p++ != 0)
            return false;
        --len;
    }
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
