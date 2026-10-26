// lzma_shim.h — 进程内 LZMA 解码桥接（Xosvi）
//
// 为什么需要它：Apple 的 Compression 框架里 COMPRESSION_LZMA 只支持
// 「XZ 容器中的 LZMA2」，解不了 deb 最常见的 .lzma-alone（13 字节头）。
// 而 iOS 上拉起 python3/bsdtar 子进程又可能被 AMFI 拒绝（Bad executable），
// package unpack 于是永远失败。这里用公有领域的 LZMA SDK 解码器在进程内解。

#ifndef LZMA_SHIM_H
#define LZMA_SHIM_H

#include <stddef.h>

/// 解码 .lzma-alone 数据（13 字节头 + LZMA1 流）。
///
/// - 返回值：malloc 出来的缓冲区，调用方用 lzma_shim_free() 释放；失败返回 NULL。
/// - outLen：输出长度。
/// - knownSize：头里声明的原始大小（未知时为 0，此时一直解到 EOS 标记）。
/// - maxSize：输出上限（0 = 使用内部默认 1GB），防止恶意包撑爆内存。
void *lzma_alone_decode(const void *src, size_t srcLen,
                        size_t *outLen, int *errOut, size_t maxSize);

/// 释放 lzma_alone_decode 返回的缓冲区。
void lzma_shim_free(void *p);

/// 解码 .xz 容器（LZMA2 + CRC32/CRC64 校验，支持 BCJ 过滤）。
///
/// - 返回值：malloc 出来的缓冲区，调用方用 lzma_shim_free() 释放；失败返回 NULL。
/// - outLen：输出长度。
/// - errOut：错误码（0 成功；-2 超过上限；-7 数据截断；-8 格式/选项错误）。
/// - maxSize：输出上限（0 = 使用内部默认 1GB）。
void *xz_stream_decode(const void *src, size_t srcLen,
                       size_t *outLen, int *errOut, size_t maxSize);

#endif /* LZMA_SHIM_H */
