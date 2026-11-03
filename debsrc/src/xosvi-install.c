// xosvi-install —— 装包 helper（对应 irisin-install 的分工，但刻意克制）。
//
// 定位：**不从零重写 dpkg**。越狱环境里 dpkg / dpkg-deb 本来就在；
// 自研 ar/tar/status 解析只会引入一批新坑（依赖解析、conffiles、triggers、
// 版本比较全要自己实现）。所以：
//
//   · 本机有 dpkg    → 直接把成熟的 dpkg 管起来（锁、maintscript 环境、
//                      status 数据库、依赖、triggers 都由 dpkg 负责）；
//   · 本机没有 dpkg  → 明确报错，让上层改用 Irisin / Sileo / Zebra，
//                      而不是拿半成品去改 /var/lib/dpkg。
//
// 用法：
//   xosvi-install install <pkg.deb>
//   xosvi-install remove  <package-id>
//   xosvi-install purge   <package-id>
//   xosvi-install list

#include "xosvi_common.h"

#include <libgen.h>

#define DEB_MAX_BYTES (2048L * 1024L * 1024L)   // 2 GB 上限

static void find_dpkg(char *out, size_t outlen) {
    const char *cands[] = {
        "/var/jb/usr/bin/dpkg", "/usr/bin/dpkg", "/bin/dpkg", NULL
    };
    for (int i = 0; cands[i]; i++) {
        if (access(cands[i], X_OK) == 0) {
            snprintf(out, outlen, "%s", cands[i]);
            return;
        }
    }
    out[0] = '\0';
}

// 以 argv 形式跑 dpkg，并设好非交互环境（避免维护脚本卡在提问上）。
static int run_dpkg(const char *dpkg, char *const argv[]) {
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        setenv("DEBIAN_FRONTEND", "noninteractive", 1);
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1);
        execv(dpkg, argv);
        fprintf(stderr, "error: exec %s failed: %s\n", dpkg, strerror(errno));
        _exit(127);
    }
    if (pid < 0) return -1;
    int status = 0;
    waitpid(pid, &status, 0);
    fflush(stdout);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static int check_deb(const char *path, char *err, size_t errlen) {
    struct stat st;
    if (stat(path, &st) != 0) {
        snprintf(err, errlen, "cannot stat %s: %s", path, strerror(errno));
        return -1;
    }
    if (!S_ISREG(st.st_mode)) {
        snprintf(err, errlen, "%s is not a regular file", path);
        return -1;
    }
    if (st.st_size <= 0 || st.st_size > DEB_MAX_BYTES) {
        snprintf(err, errlen, "implausible size: %lld bytes", (long long)st.st_size);
        return -1;
    }
    FILE *f = fopen(path, "rb");
    if (!f) {
        snprintf(err, errlen, "cannot open %s: %s", path, strerror(errno));
        return -1;
    }
    char magic[8] = {0};
    size_t got = fread(magic, 1, sizeof magic, f);
    fclose(f);
    if (got != 8 || memcmp(magic, "!<arch>\n", 8) != 0) {
        snprintf(err, errlen, "%s is not a .deb (bad ar magic)", path);
        return -1;
    }
    return 0;
}

// package id 不许带路径 / 空白 / 以 '-' 开头（防止被 dpkg 当成选项参数）
static int valid_pkg_id(const char *id) {
    if (!id || !*id || id[0] == '-') return 0;
    for (const char *p = id; *p; p++) {
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') || *p == '.' || *p == '+' || *p == '-')) {
            return 0;
        }
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
                "usage: xosvi-install install <pkg.deb>\n"
                "       xosvi-install remove  <package-id>\n"
                "       xosvi-install purge   <package-id>\n"
                "       xosvi-install list\n");
        return 2;
    }

    char dpkg[PATH_MAX];
    find_dpkg(dpkg, sizeof dpkg);
    const char *sub = argv[1];

    if (!dpkg[0] && strcmp(sub, "list") != 0) {
        fprintf(stderr,
                "error: dpkg not found (looked in /var/jb/usr/bin and /usr/bin).\n"
                "       Install packages through Irisin / Sileo / Zebra instead.\n");
        return 3;
    }

    if (!strcmp(sub, "install")) {
        if (argc < 3) { fprintf(stderr, "error: missing .deb path\n"); return 2; }
        char real[PATH_MAX];
        if (xosvi_safe_path(argv[2], NULL, real, sizeof real) != 0) {
            fprintf(stderr, "error: cannot resolve %s\n", argv[2]);
            return 3;
        }
        char err[512] = {0};
        if (check_deb(real, err, sizeof err) != 0) {
            fprintf(stderr, "error: %s\n", err);
            return 4;
        }
        printf("plan: %s -i %s\n", dpkg, real);
        fflush(stdout);
        char *dpkg_argv[] = { dpkg, "-i", real, NULL };
        int rc = run_dpkg(dpkg, dpkg_argv);
        printf("result: exit=%d\n", rc);
        return rc == 0 ? 0 : 5;
    }

    if (!strcmp(sub, "remove") || !strcmp(sub, "purge")) {
        if (argc < 3) { fprintf(stderr, "error: missing package id\n"); return 2; }
        if (!valid_pkg_id(argv[2])) {
            fprintf(stderr, "error: invalid package id: %s\n", argv[2]);
            return 3;
        }
        const char *flag = strcmp(sub, "purge") ? "-r" : "-P";
        printf("plan: %s %s %s\n", dpkg, flag, argv[2]);
        fflush(stdout);
        char *dpkg_argv[] = { dpkg, (char *)flag, argv[2], NULL };
        int rc = run_dpkg(dpkg, dpkg_argv);
        printf("result: exit=%d\n", rc);
        return rc == 0 ? 0 : 5;
    }

    if (!strcmp(sub, "list")) {
        if (dpkg[0]) {
            char *dpkg_argv[] = { dpkg, "-l", NULL };
            int rc = run_dpkg(dpkg, dpkg_argv);
            return rc == 0 ? 0 : 5;
        }
        const char *status_files[] = {
            "/var/jb/var/lib/dpkg/status", "/var/lib/dpkg/status", NULL
        };
        for (int i = 0; status_files[i]; i++) {
            size_t len = 0;
            char *data = xosvi_read_file(status_files[i], &len);
            if (!data) continue;
            printf("# %s\n", status_files[i]);
            char *save = NULL;
            for (char *line = strtok_r(data, "\n", &save); line;
                 line = strtok_r(NULL, "\n", &save)) {
                if (!strncmp(line, "Package: ", 9) || !strncmp(line, "Version: ", 9)) {
                    printf("%s\n", line);
                }
            }
            free(data);
            return 0;
        }
        fprintf(stderr, "error: no dpkg and no readable status database\n");
        return 3;
    }

    fprintf(stderr, "error: unknown subcommand %s\n", sub);
    return 2;
}
