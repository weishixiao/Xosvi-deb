// xz_shim.c — .xz 容器解码（xz-embedded，0BSD）
//
// deb 的 data.tar 也可能用 .xz（LZMA2 + xz 容器 + CRC 校验）。
// Apple Compression 的 COMPRESSION_LZMA 虽然声称支持「XZ 里的 LZMA2」，
// 但 compression_decode_buffer 实际对常规 xz 文件返回 0（未做流式容器解析），
// 而在部分越狱/AMFI 环境里 python3 子进程又起不来（Bad executable），
// 所以这里内置 xz-embedded 在进程内解码，彻底不依赖子进程。

#include "xz/xz_config.h"   /* 同时引入 xz.h、stdlib/string，并启用 CRC64/BCJ */
#include "include/lzma_shim.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef XZ_SHIM_CHUNK
#define XZ_SHIM_CHUNK ((size_t)1 << 20)
#endif
#ifndef XZ_SHIM_DEFAULT_MAX
#define XZ_SHIM_DEFAULT_MAX ((size_t)1 << 30)   /* 1GB */
#endif

void *xz_stream_decode(const void *src, size_t srcLen,
                       size_t *outLen, int *errOut, size_t maxSize)
{
    if (outLen) *outLen = 0;
    if (errOut) *errOut = -1;
    if (!src || srcLen == 0 || !outLen) return NULL;

    /* CRC 查表必须显式初始化：内核在启动时做，用户态不做就会把合法的
       xz 头/块判成 DATA_ERROR（实测每个文件都在 12 字节后失败）。 */
    static volatile int crcReady = 0;
    if (!crcReady) {
        xz_crc32_init();
#ifdef XZ_USE_CRC64
        xz_crc64_init();
#endif
        crcReady = 1;
    }

    const size_t limit = maxSize ? maxSize : XZ_SHIM_DEFAULT_MAX;

    struct xz_dec *s = xz_dec_init(XZ_DYNALLOC, (uint32_t)-1);
    if (!s) { if (errOut) *errOut = -3; return NULL; }

    uint8_t *out = (uint8_t *)malloc(XZ_SHIM_CHUNK);
    if (!out) { xz_dec_end(s); if (errOut) *errOut = -5; return NULL; }
    size_t cap = XZ_SHIM_CHUNK;

    struct xz_buf b;
    memset(&b, 0, sizeof(b));
    b.in = (const uint8_t *)src;
    b.in_pos = 0;
    b.in_size = srcLen;
    b.out = out;
    b.out_pos = 0;
    b.out_size = cap;

    int rc = -4;

    for (;;) {
        if (b.out_pos == cap) {
            if (cap >= limit) { rc = -2; break; }
            size_t newCap = cap << 1;
            if (newCap > limit) newCap = limit;
            uint8_t *nb = (uint8_t *)realloc(out, newCap);
            if (!nb) { rc = -5; break; }
            out = nb;
            cap = newCap;
            b.out = out;
            b.out_size = cap;
        }

        const size_t inBefore = b.in_pos;
        const size_t outBefore = b.out_pos;
        enum xz_ret ret = xz_dec_run(s, &b);

        if (ret == XZ_STREAM_END) { rc = 0; break; }
        if (ret == XZ_OK) {
            if (b.in_pos == inBefore && b.out_pos == outBefore) { rc = -7; break; }  /* 无进展 */
            continue;
        }
        if (ret == XZ_BUF_ERROR) {
            /* 输出还有空间却没进展 → 输入被截断；输出已满则扩容后重试 */
            if (b.out_pos < b.out_size) { rc = -7; break; }
            continue;
        }
        if (ret == XZ_MEM_ERROR) { rc = -5; break; }
        if (ret == XZ_MEMLIMIT_ERROR) { rc = -2; break; }
        if (ret == XZ_FORMAT_ERROR || ret == XZ_OPTIONS_ERROR) { rc = -8; break; }
        rc = -6;  /* XZ_DATA_ERROR */
        break;
    }

    xz_dec_end(s);

    if (rc != 0) {
        free(out);
        if (errOut) *errOut = rc;
        return NULL;
    }
    *outLen = b.out_pos;
    if (errOut) *errOut = 0;
    return out;
}
