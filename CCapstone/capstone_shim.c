// capstone_shim.c — capstone 5.x 的最小封装

#include "capstone_shim.h"
#include <capstone/capstone.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void csx_free(void *p) { free(p); }

char *csx_disasm(const void *code, size_t len, uint64_t address, int arch,
                 size_t maxInstructions, size_t *outLen, int *errOut)
{
    if (outLen) *outLen = 0;
    if (errOut) *errOut = 0;
    if (!code || len == 0) { if (errOut) *errOut = -2; return NULL; }

    cs_arch a;
    cs_mode m = CS_MODE_ARM;
    switch (arch) {
        case CSX_ARCH_ARM64:  a = CS_ARCH_ARM64; m = CS_MODE_ARM; break;
        case CSX_ARCH_ARM:    a = CS_ARCH_ARM;   m = CS_MODE_ARM; break;
        case CSX_ARCH_X86_64: a = CS_ARCH_X86;   m = CS_MODE_64;  break;
        case CSX_ARCH_X86:    a = CS_ARCH_X86;   m = CS_MODE_32;  break;
        default: if (errOut) *errOut = -1; return NULL;
    }

    csh handle;
    if (cs_open(a, m, &handle) != CS_ERR_OK) { if (errOut) *errOut = -1; return NULL; }
    cs_option(handle, CS_OPT_DETAIL, CS_OPT_OFF);

    cs_insn *insn = NULL;
    size_t count = cs_disasm(handle, (const uint8_t *)code, len, address,
                             maxInstructions, &insn);
    if (count == 0) {
        cs_close(&handle);
        if (errOut) *errOut = -2;
        return NULL;
    }

    // 每行最多约 200 字节，按条数预留
    size_t cap = count * 192 + 64;
    char *out = (char *)malloc(cap);
    if (!out) {
        cs_free(insn, count);
        cs_close(&handle);
        if (errOut) *errOut = -1;
        return NULL;
    }

    size_t used = 0;
    for (size_t i = 0; i < count; i++) {
        char bytes[3 * 8 + 1];
        size_t bp = 0;
        for (size_t k = 0; k < insn[i].size && k < 8; k++) {
            bp += (size_t)snprintf(bytes + bp, sizeof(bytes) - bp, "%02x", insn[i].bytes[k]);
        }
        bytes[bp] = '\0';
        int w = snprintf(out + used, cap - used, "0x%llx: %-16s %s %s\n",
                         (unsigned long long)insn[i].address, bytes,
                         insn[i].mnemonic, insn[i].op_str);
        if (w <= 0 || (size_t)w >= cap - used) break;
        used += (size_t)w;
    }

    cs_free(insn, count);
    cs_close(&handle);
    if (outLen) *outLen = used;
    return out;
}
