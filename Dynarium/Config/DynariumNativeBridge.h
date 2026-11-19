// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef DYNARIUM_NATIVE_BRIDGE_H
#define DYNARIUM_NATIVE_BRIDGE_H

#include <errno.h>
#include <os/proc.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/clonefile.h>
#include <sys/mman.h>
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

static inline bool dynarium_probe_extended_va_space(void)
{
    static const uintptr_t hints[5] = {
        (uintptr_t)0x0000000c00000000ULL, /* 48 GiB */
        (uintptr_t)0x0000000d00000000ULL, /* 52 GiB */
        (uintptr_t)0x0000000e00000000ULL, /* 56 GiB */
        (uintptr_t)0x0000001000000000ULL, /* 64 GiB */
        (uintptr_t)0U
    };
    const size_t probeSize = 65536U;
    const uintptr_t linkFloor = (uintptr_t)0x0000000c00000000ULL;
    for (int i = 0; i < 5; ++i) {
        void* addr = mmap((void*)hints[i], probeSize, PROT_NONE,
            MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
        if (addr == MAP_FAILED)
            continue;
        const uintptr_t base = (uintptr_t)addr;
        (void)munmap(addr, probeSize);
        if (base >= linkFloor)
            return true;
    }
    return false;
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
