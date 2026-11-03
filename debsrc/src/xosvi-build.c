// xosvi-build —— 构建 helper（对应 apelin-build）。
//
// 用法：xosvi-build [--as-mobile] <project_dir> <script> [args...]
//
// 安全约束（报告 6.1.4）：
//   · 没有自由 shell 串：script 必须是 project_dir 里已存在的文件，
//     realpath 后仍必须落在 project_dir 内；
//   · 默认以 root 执行（构建产物要写系统路径）；--as-mobile 时降到 uid 501。

#include "xosvi_common.h"

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: xosvi-build [--as-mobile] <project_dir> <script> [args...]\n");
        return 2;
    }
    int as_mobile = 0;
    int argi = 1;
    if (!strcmp(argv[argi], "--as-mobile")) {
        as_mobile = 1;
        argi++;
        if (argc < argi + 2) {
            fprintf(stderr, "usage: xosvi-build --as-mobile <project_dir> <script> [args...]\n");
            return 2;
        }
    }

    const char *proj = argv[argi];
    char real_proj[PATH_MAX];
    int rc = xosvi_safe_path(proj, XOSVI_DATA_ROOT, real_proj, sizeof real_proj);
    if (rc != 0) {
        fprintf(stderr, "error: project dir is outside %s (rc=%d)\n", XOSVI_DATA_ROOT, rc);
        return 3;
    }

    char cand[PATH_MAX];
    if (argv[argi + 1][0] == '/') {
        snprintf(cand, sizeof cand, "%s", argv[argi + 1]);
    } else {
        snprintf(cand, sizeof cand, "%s/%s", real_proj, argv[argi + 1]);
    }
    char real_script[PATH_MAX];
    if (xosvi_safe_path(cand, real_proj, real_script, sizeof real_script) != 0) {
        fprintf(stderr, "error: script escapes the project root: %s\n", cand);
        return 3;
    }
    if (access(real_script, R_OK) != 0) {
        fprintf(stderr, "error: script not readable: %s (%s)\n", real_script, strerror(errno));
        return 3;
    }

    // child argv = [script, args...]
    int nargs = argc - argi - 1;
    char **child = (char **)calloc((size_t)nargs + 1, sizeof(char *));
    if (!child) return 4;
    child[0] = real_script;
    for (int i = 1; i < nargs; i++) child[i] = argv[argi + 1 + i];
    child[nargs] = NULL;

    xlog("build", "exec %s (%d args, as_mobile=%d)", real_script, nargs - 1, as_mobile);
    pid_t pid = fork();
    if (pid == 0) {
        if (as_mobile) {
            setgid(501);
            setuid(501);
        }
        execv(real_script, child);
        fprintf(stderr, "error: exec failed: %s\n", strerror(errno));
        _exit(127);
    }
    if (pid < 0) {
        fprintf(stderr, "error: fork failed\n");
        free(child);
        return 4;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    free(child);

    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    xlog("build", "exit %d", code);
    fflush(stdout);
    return code == 0 ? 0 : (code > 0 ? code : 1);
}
