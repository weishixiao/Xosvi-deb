// xosvi_common.h —— 守护与 helper 共用的小工具。
// 只写可移植 C（iOS SDK + Darwin），不依赖 Foundation。
#ifndef XOSVI_COMMON_H
#define XOSVI_COMMON_H

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "xosvi_config.h"

static inline void xlog(const char *tag, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    fprintf(stderr, "[%02d:%02d:%02d][%s] ", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, tag);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

// realpath + 前缀检查。成功返回 0；越界返回 -2；无法解析返回 -1。
static inline int xosvi_safe_path(const char *path, const char *must_prefix,
                                  char *out, size_t outlen) {
    char rp[PATH_MAX];
    if (!realpath(path, rp)) return -1;
    if (must_prefix && strncmp(rp, must_prefix, strlen(must_prefix)) != 0) return -2;
    if (out) snprintf(out, outlen, "%s", rp);
    return 0;
}

// 读整个文件（末尾补 '\0'）。调用方负责 free。
static inline char *xosvi_read_file(const char *path, size_t *outlen) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long n = ftell(f);
    if (n < 0) { fclose(f); return NULL; }
    rewind(f);
    char *buf = (char *)calloc(1, (size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    if (outlen) *outlen = got;
    return buf;
}

// 递归创建目录（mkdir -p），已存在视为成功。
static inline int xosvi_mkdir_p(const char *path, mode_t mode) {
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, mode) != 0 && errno != EEXIST) return -1;
            *p = '/';
        }
    }
    if (mkdir(tmp, mode) != 0 && errno != EEXIST) return -1;
    return 0;
}

#endif
