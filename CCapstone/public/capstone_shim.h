// capstone_shim.h — 反汇编桥接（Xosvi）
//
// 为什么需要：本机越狱（rootHide）拒绝执行 App 内的第三方二进制，
// r2 / cstool 都起不来（posix_spawn → ENOSYS 85）。capstone 静态库
// 已经随包分发（bin/libcapstone.a），这里把它链接进主二进制，
// 让反汇编在主进程内完成，不依赖任何子进程。

#ifndef CAPSTONE_SHIM_H
#define CAPSTONE_SHIM_H

#include <stddef.h>
#include <stdint.h>

#define CSX_ARCH_ARM64  0
#define CSX_ARCH_ARM    1
#define CSX_ARCH_X86_64 2
#define CSX_ARCH_X86    3

/// 反汇编一段机器码。
/// 返回 malloc 的 NUL 结尾文本，每行 "0x地址: 字节 助记符 操作数"；
/// 调用方用 csx_free() 释放；失败返回 NULL。
char *csx_disasm(const void *code, size_t len, uint64_t address, int arch,
                 size_t maxInstructions, size_t *outLen, int *errOut);

void csx_free(void *p);

#endif
