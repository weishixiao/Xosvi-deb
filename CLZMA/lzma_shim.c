// lzma_shim.c — .lzma-alone 解码（公有领域 LZMA SDK 的 LzmaDec）
//
// 输入布局（LZMA alone，标准 13 字节头）：
//   byte 0      : props = (pb * 5 + lp) * 9 + lc
//   byte 1..4   : dictionary size (LE32)
//   byte 5..12  : uncompressed size (LE64)；全 0xFF 表示未知（流尾有 EOS 标记）
//   byte 13..   : LZMA1 压缩流

#include "include/lzma_shim.h"
#include "sdk/LzmaDec.h"

#include <stdlib.h>
#include <string.h>

#define SHIM_PROPS_SIZE 5
#define SHIM_HEADER_SIZE 13
#define SHIM_DEFAULT_MAX ((size_t)1 << 30)   /* 1GB */
#define SHIM_CHUNK ((size_t)1 << 20)         /* 每次至少扩展 1MB */

static void *SzAlloc(ISzAllocPtr p, size_t size) { (void)p; return malloc(size); }
static void SzFree(ISzAllocPtr p, void *address) { (void)p; free(address); }
static const ISzAlloc g_Alloc = { SzAlloc, SzFree };

void lzma_shim_free(void *p) { free(p); }

static int grow(unsigned char **buf, size_t *cap, size_t need)
{
    size_t newCap = *cap ? *cap : SHIM_CHUNK;
    while (newCap < need) {
        if (newCap > (SHIM_DEFAULT_MAX)) return 0;
        newCap <<= 1;
    }
    unsigned char *nb = (unsigned char *)realloc(*buf, newCap);
    if (!nb) return 0;
    *buf = nb;
    *cap = newCap;
    return 1;
}

void *lzma_alone_decode(const void *src, size_t srcLen,
                        size_t *outLen, int *errOut, size_t maxSize)
{
    if (outLen) *outLen = 0;
    if (errOut) *errOut = -1;
    if (!src || srcLen <= SHIM_HEADER_SIZE || !outLen) return NULL;

    const unsigned char *in = (const unsigned char *)src;
    const size_t limit = maxSize ? maxSize : SHIM_DEFAULT_MAX;

    unsigned char props[SHIM_PROPS_SIZE];
    props[0] = in[0];
    memcpy(props + 1, in + 1, 4);            /* dictionary size, LE32 */

    unsigned long long declared =
        (unsigned long long)in[5]         | ((unsigned long long)in[6]  << 8)  |
        ((unsigned long long)in[7]  << 16) | ((unsigned long long)in[8]  << 24) |
        ((unsigned long long)in[9]  << 32) | ((unsigned long long)in[10] << 40) |
        ((unsigned long long)in[11] << 48) | ((unsigned long long)in[12] << 56);

    int knownSize = (declared != 0xFFFFFFFFFFFFFFFFULL);
    if (knownSize) {
        if (declared > (unsigned long long)limit) { if (errOut) *errOut = -2; return NULL; }
        if (declared == 0) {
            /* 空文件：返回一个 1 字节的空缓冲，避免调用方把 NULL 当失败 */
            unsigned char *empty = (unsigned char *)malloc(1);
            if (empty) { if (errOut) *errOut = 0; }
            return empty;
        }
    }

    CLzmaDec dec;
    LzmaDec_Construct(&dec);
    if (LzmaDec_Allocate(&dec, props, SHIM_PROPS_SIZE, &g_Alloc) != SZ_OK) {
        if (errOut) *errOut = -3;
        return NULL;
    }
    LzmaDec_Init(&dec);

    unsigned char *out = NULL;
    size_t cap = 0, total = 0;
    size_t srcPos = SHIM_HEADER_SIZE;
    int rc = -4;

    for (;;) {
        if (knownSize) {
            if (total >= (size_t)declared) { rc = 0; break; }
            if (!grow(&out, &cap, (size_t)declared)) { rc = -5; break; }
        } else {
            if (total + SHIM_CHUNK > limit) { rc = -2; break; }
            if (!grow(&out, &cap, total + SHIM_CHUNK)) { rc = -5; break; }
        }

        SizeT destLen = (SizeT)(cap - total);
        SizeT inLen = (SizeT)(srcLen - srcPos);
        ELzmaFinishMode finish = knownSize ? LZMA_FINISH_END : LZMA_FINISH_ANY;
        ELzmaStatus status = LZMA_STATUS_NOT_SPECIFIED;

        SRes res = LzmaDec_DecodeToBuf(&dec, out + total, &destLen,
                                       in + srcPos, &inLen, finish, &status);
        srcPos += (size_t)inLen;
        total += (size_t)destLen;

        if (res != SZ_OK) { rc = -6; break; }
        if (status == LZMA_STATUS_FINISHED_WITH_MARK) { rc = 0; break; }
        if (knownSize && total >= (size_t)declared) { rc = 0; break; }
        if (status == LZMA_STATUS_MAYBE_FINISHED_WITHOUT_MARK && inLen == 0) { rc = 0; break; }
        if (inLen == 0 && destLen == 0) { rc = -7; break; }   /* 卡死/截断 */
        if (srcPos >= srcLen && status == LZMA_STATUS_NEEDS_MORE_INPUT) { rc = -7; break; }
    }

    LzmaDec_Free(&dec, &g_Alloc);

    if (rc != 0) {
        free(out);
        if (errOut) *errOut = rc;
        return NULL;
    }
    *outLen = total;
    if (errOut) *errOut = 0;
    return out;
}
