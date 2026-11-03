// xosvi-symbolicate —— 崩溃符号化 helper（对应报告里 Xrash 的分工）。
//
// 用法：
//   xosvi-symbolicate info <macho|dSYM...>
//       打印每个 Mach-O 的 LC_UUID / 架构 / 是否来自 dSYM
//   xosvi-symbolicate match <crash.ips|crash> <macho|dSYM...>
//       提取崩溃报告里的 UUID，与给定二进制逐一比对
//
// 这是**不依赖 atos/dsymutil 的最小实现**：只解决「该用哪个 dSYM」这一步，
// 真正的地址→符号解析由 App 侧（已带 MachOKit）完成。

#include "xosvi_common.h"

#include <ctype.h>
#include <dirent.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>

static int macho_uuid(const char *path, char out[64], char arch_out[32], char *is_dsym) {
    out[0] = '\0';
    arch_out[0] = '\0';
    if (is_dsym) *is_dsym = 0;

    struct stat st;
    if (stat(path, &st) != 0) return -1;

    // dSYM 是目录：进 Contents/Resources/DWARF/ 找里面的二进制
    if (S_ISDIR(st.st_mode)) {
        char dwarf[PATH_MAX];
        snprintf(dwarf, sizeof dwarf, "%s/Contents/Resources/DWARF", path);
        DIR *dd = opendir(dwarf);
        if (!dd) return -1;
        struct dirent *e;
        int found = -1;
        while ((e = readdir(dd)) != NULL) {
            if (e->d_name[0] == '.') continue;
            char cand[PATH_MAX];
            snprintf(cand, sizeof cand, "%s/%s", dwarf, e->d_name);
            char u[64], a[32];
            if (macho_uuid(cand, u, a, NULL) == 0) {
                snprintf(out, 64, "%s", u);
                snprintf(arch_out, 32, "%s", a);
                found = 0;
                if (is_dsym) *is_dsym = 1;
                break;
            }
        }
        closedir(dd);
        return found;
    }

    FILE *f = fopen(path, "rb");
    if (!f) return -1;

    uint32_t magic = 0;
    if (fread(&magic, sizeof magic, 1, f) != 1) { fclose(f); return -1; }

    long slice_off = 0;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        // fat 头是 big-endian
        struct fat_header fh;
        rewind(f);
        if (fread(&fh, sizeof fh, 1, f) != 1) { fclose(f); return -1; }
        uint32_t nfat = OSSwapBigToHostInt32(fh.nfat_arch);
        struct fat_arch fa;
        for (uint32_t i = 0; i < nfat; i++) {
            if (fread(&fa, sizeof fa, 1, f) != 1) break;
            uint32_t cpu = OSSwapBigToHostInt32(fa.cputype);
            if (cpu == CPU_TYPE_ARM64 || i == 0) {
                slice_off = (long)OSSwapBigToHostInt32(fa.offset);
                break;
            }
        }
        fseek(f, slice_off, SEEK_SET);
        if (fread(&magic, sizeof magic, 1, f) != 1) { fclose(f); return -1; }
    }

    if (magic != MH_MAGIC_64) { fclose(f); return -1; }

    struct mach_header_64 mh;
    fseek(f, slice_off, SEEK_SET);
    if (fread(&mh, sizeof mh, 1, f) != 1) { fclose(f); return -1; }
    snprintf(arch_out, 32, "%s", (mh.cputype == CPU_TYPE_ARM64) ? "arm64" : "other");

    long pos = slice_off + (long)sizeof mh;
    for (uint32_t i = 0; i < mh.ncmds; i++) {
        struct load_command lc;
        fseek(f, pos, SEEK_SET);
        if (fread(&lc, sizeof lc, 1, f) != 1) break;
        if (lc.cmd == LC_UUID && lc.cmdsize >= sizeof(struct uuid_command)) {
            struct uuid_command uc;
            fseek(f, pos, SEEK_SET);
            if (fread(&uc, sizeof uc, 1, f) == 1) {
                snprintf(out, 64,
                         "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                         uc.uuid[0], uc.uuid[1], uc.uuid[2], uc.uuid[3],
                         uc.uuid[4], uc.uuid[5], uc.uuid[6], uc.uuid[7],
                         uc.uuid[8], uc.uuid[9], uc.uuid[10], uc.uuid[11],
                         uc.uuid[12], uc.uuid[13], uc.uuid[14], uc.uuid[15]);
                fclose(f);
                return 0;
            }
        }
        if (lc.cmdsize == 0) break;
        pos += lc.cmdsize;
    }
    fclose(f);
    return -1;
}

static int is_hex(char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

// 从 .ips（JSON 头 + 正文）或旧式 .crash 里找第一个 8-4-4-4-12 UUID。
static int crash_uuid(const char *path, char out[64]) {
    size_t len = 0;
    char *data = xosvi_read_file(path, &len);
    if (!data) return -1;
    int found = -1;
    for (size_t i = 0; i + 36 <= len; i++) {
        int ok = 1;
        for (int j = 0; j < 36; j++) {
            char c = data[i + (size_t)j];
            if (j == 8 || j == 13 || j == 18 || j == 23) {
                if (c != '-') { ok = 0; break; }
            } else if (!is_hex(c)) {
                ok = 0;
                break;
            }
        }
        if (!ok) continue;
        char prev = (i == 0) ? ' ' : data[i - 1];
        char next = (i + 36 < len) ? data[i + 36] : ' ';
        if (is_hex(prev) || is_hex(next)) continue;   // 避免截取更长的十六进制串
        snprintf(out, 64, "%.36s", data + i);
        for (int k = 0; k < 36; k++) out[k] = (char)toupper((unsigned char)out[k]);
        found = 0;
        break;
    }
    free(data);
    return found;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr,
                "usage: xosvi-symbolicate info <macho|dSYM...>\n"
                "       xosvi-symbolicate match <crash-report> <macho|dSYM...>\n");
        return 2;
    }
    if (!strcmp(argv[1], "info")) {
        int bad = 0;
        for (int i = 2; i < argc; i++) {
            char uuid[64] = {0}, arch[32] = {0}, dsym = 0;
            if (macho_uuid(argv[i], uuid, arch, &dsym) != 0) {
                printf("%s\tno-uuid\n", argv[i]);
                bad = 1;
                continue;
            }
            printf("%s\t%s\t%s%s\n", argv[i], uuid, arch, dsym ? "\tdsym" : "");
        }
        return bad;
    }
    if (!strcmp(argv[1], "match")) {
        char want[64] = {0};
        if (argc < 4) {
            fprintf(stderr, "usage: xosvi-symbolicate match <crash-report> <macho|dSYM...>\n");
            return 2;
        }
        if (crash_uuid(argv[2], want) != 0) {
            fprintf(stderr, "error: no UUID found in %s\n", argv[2]);
            return 3;
        }
        printf("crash_uuid=%s\n", want);
        int hits = 0;
        for (int i = 3; i < argc; i++) {
            char uuid[64] = {0}, arch[32] = {0}, dsym = 0;
            if (macho_uuid(argv[i], uuid, arch, &dsym) != 0) {
                printf("MISS\t%s\n", argv[i]);
                continue;
            }
            int same = (strcasecmp(uuid, want) == 0);
            printf("%s\t%s\t%s\t%s%s\n", same ? "MATCH" : "DIFF", uuid, arch, argv[i],
                   dsym ? "\tdsym" : "");
            if (same) hits++;
        }
        printf("matches=%d\n", hits);
        return hits > 0 ? 0 : 4;
    }
    fprintf(stderr, "error: unknown subcommand %s\n", argv[1]);
    return 2;
}
