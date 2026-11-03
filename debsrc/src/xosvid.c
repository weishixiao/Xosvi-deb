// xosvid —— Xosvi 的 root 后端（对应报告里的 apelind）。
//
// 职责：
//   1. 注册 Mach 服务 XOSVI_SERVICE_NAME，按需启动；
//   2. 每个连接先做 entitlement 校验（audit token，不用 bundle id / pid）；
//   3. 请求只认固定命令表，helper 以 argv 形式派发，绝不拼 shell 串；
//   4. helper 一律 realpath 后必须落在 XOSVI_HELPER_DIR 内；
//   5. 空闲 XOSVI_IDLE_SECONDS 秒后退出，让 launchd 按需再拉起。
//
// 请求字典：command = "ping" | "xpc-diag" | "build" | "install" | "symbolicate"
//          args    = 字符串数组（透传给 helper 的 argv[1..]）
// 回复字典：ok(bool) / status / exit_code / stdout / error

#include "xosvi_common.h"

#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <xpc/xpc.h>

// 私有 SPI：检查对端连接的 audit token 上是否带指定 entitlement。
// 公开头里没有声明，这里手工 extern（与 libxpc 导出的签名一致）。
extern xpc_object_t xpc_copy_entitlement_for_token(const char *key,
                                                   const audit_token_t *token);

#define HELPER_TIMEOUT_SEC 300

static dispatch_source_t g_idle_timer = NULL;
static int g_active = 0;

static void arm_idle(void) {
    if (!g_idle_timer) {
        g_idle_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                              dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_event_handler(g_idle_timer, ^{
            if (g_active > 0) { arm_idle(); return; }
            xlog("xosvid", "idle %ds, exiting", XOSVI_IDLE_SECONDS);
            exit(0);
        });
        dispatch_resume(g_idle_timer);
    }
    dispatch_source_set_timer(g_idle_timer,
                              dispatch_time(DISPATCH_TIME_NOW,
                                            (uint64_t)XOSVI_IDLE_SECONDS * NSEC_PER_SEC),
                              DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
}

// ── 对端鉴权：内核给的 audit token 不可伪造；bundle id / pid 可以 ──────
static int peer_is_authorized(xpc_connection_t conn) {
    audit_token_t token;
    xpc_connection_get_audit_token(conn, &token);

    xpc_object_t ent = xpc_copy_entitlement_for_token(XOSVI_CLIENT_ENT, &token);
    if (!ent) {
        xlog("xosvid", "rejected pid=%d (no %s)",
             xpc_connection_get_pid(conn), XOSVI_CLIENT_ENT);
        return 0;
    }
    int ok = 0;
    if (xpc_get_type(ent) == XPC_TYPE_BOOL) {
        ok = xpc_bool_get_value(ent) ? 1 : 0;
    } else if (xpc_get_type(ent) == XPC_TYPE_INT64) {
        ok = xpc_int64_get_value(ent) != 0;
    }
    xpc_release(ent);
    if (!ok) {
        xlog("xosvid", "rejected pid=%d (%s is not true)",
             xpc_connection_get_pid(conn), XOSVI_CLIENT_ENT);
    }
    return ok;
}

static void send_error(xpc_connection_t conn, xpc_object_t msg, const char *code) {
    xpc_object_t reply = xpc_dictionary_create_reply(msg);
    if (!reply) return;
    xpc_dictionary_set_bool(reply, "ok", false);
    xpc_dictionary_set_string(reply, "error", code);
    xpc_connection_send_message(conn, reply);
    xpc_release(reply);
}

// ── 派发 helper：argv 形式，输出经临时文件回读 ─────────────────────────
static void run_helper(xpc_connection_t conn, xpc_object_t msg,
                       const char *name, xpc_object_t args) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", XOSVI_HELPER_DIR, name);

    char real[PATH_MAX];
    if (xosvi_safe_path(path, XOSVI_HELPER_DIR, real, sizeof real) != 0) {
        xlog("xosvid", "helper rejected (escaped or missing): %s", path);
        return send_error(conn, msg, "helper_unavailable");
    }
    if (access(real, X_OK) != 0) {
        return send_error(conn, msg, "helper_not_executable");
    }

    char *argv[128] = {0};
    int argc = 0;
    argv[argc++] = (char *)name;
    if (args && xpc_get_type(args) == XPC_TYPE_ARRAY) {
        size_t n = xpc_array_get_count(args);
        for (size_t i = 0; i < n && argc < 127; i++) {
            const char *s = xpc_array_get_string(args, i);
            if (s) argv[argc++] = strdup(s);
        }
    }
    argv[argc] = NULL;

    // 输出落盘，避免管道缓冲 / 僵尸 / 大输出回传卡死
    xosvi_mkdir_p(XOSVI_SPILL_DIR, 0755);
    char spill[PATH_MAX];
    snprintf(spill, sizeof spill, "%s/spill_%s_%d_%lld.txt", XOSVI_SPILL_DIR,
             name, (int)getpid(), (long long)time(NULL));
    int fd = open(spill, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        for (int i = 1; i < argc; i++) free(argv[i]);
        return send_error(conn, msg, "spill_open_failed");
    }

    g_active++;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        close(fd);
        // helper 以 root 运行：deb 装好后不再需要 persona / setuid 演练
        execv(real, argv);
        _exit(127);
    }
    close(fd);
    if (pid < 0) {
        g_active--;
        for (int i = 1; i < argc; i++) free(argv[i]);
        unlink(spill);
        return send_error(conn, msg, "fork_failed");
    }

    int status = 0;
    int waited = 0;
    for (;;) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) break;
        if (waited >= HELPER_TIMEOUT_SEC * 10) {
            xlog("xosvid", "helper %s timed out, killing", name);
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            status = -1;
            break;
        }
        usleep(100 * 1000);
        waited++;
    }
    g_active--;

    size_t outlen = 0;
    char *out = xosvi_read_file(spill, &outlen);
    unlink(spill);

    xpc_object_t reply = xpc_dictionary_create_reply(msg);
    if (reply) {
        int rc = (status == -1) ? -1 : (WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        xpc_dictionary_set_bool(reply, "ok", rc == 0);
        xpc_dictionary_set_int64(reply, "exit_code", rc);
        if (out) xpc_dictionary_set_string(reply, "stdout", out);
        xpc_connection_send_message(conn, reply);
        xpc_release(reply);
    }
    free(out);
    for (int i = 1; i < argc; i++) free(argv[i]);
}

static const char *kHelpers[] = { "build", "install", "symbolicate", NULL };

static void handle_message(xpc_connection_t conn, xpc_object_t msg) {
    if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) return;
    arm_idle();

    const char *cmd = xpc_dictionary_get_string(msg, "command");
    if (!cmd) return send_error(conn, msg, "missing_command");

    if (!strcmp(cmd, "ping")) {
        xpc_object_t reply = xpc_dictionary_create_reply(msg);
        if (!reply) return;
        xpc_dictionary_set_bool(reply, "ok", true);
        xpc_dictionary_set_string(reply, "status", "ok");
        xpc_dictionary_set_int64(reply, "pid", (int64_t)getpid());
        xpc_dictionary_set_int64(reply, "uid", (int64_t)getuid());
        xpc_connection_send_message(conn, reply);
        xpc_release(reply);
        return;
    }
    if (!strcmp(cmd, "xpc-diag")) {
        // 身份探测：确认 App -> 守护 这条路以及 audit token 是否可用
        audit_token_t tok;
        xpc_connection_get_audit_token(conn, &tok);
        char buf[128];
        snprintf(buf, sizeof buf, "pid=%d euid=%d",
                 (int)xpc_connection_get_pid(conn), (int)geteuid());
        xpc_object_t reply = xpc_dictionary_create_reply(msg);
        if (!reply) return;
        xpc_dictionary_set_bool(reply, "ok", true);
        xpc_dictionary_set_string(reply, "peer", buf);
        xpc_dictionary_set_int64(reply, "audit_pid", (int64_t)audit_token_to_pid(tok));
        xpc_connection_send_message(conn, reply);
        xpc_release(reply);
        return;
    }

    for (int i = 0; kHelpers[i]; i++) {
        if (!strcmp(cmd, kHelpers[i])) {
            char helper[64];
            snprintf(helper, sizeof helper, "xosvi-%s", cmd);
            run_helper(conn, msg, helper, xpc_dictionary_get_value(msg, "args"));
            return;
        }
    }
    send_error(conn, msg, "unknown_command");
}

static void handle_connection(xpc_connection_t conn) {
    if (!peer_is_authorized(conn)) {
        xpc_connection_cancel(conn);
        return;
    }
    xpc_connection_set_target_queue(conn, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            xpc_connection_cancel(conn);
            return;
        }
        handle_message(conn, event);
    });
    xpc_connection_resume(conn);
    arm_idle();
}

int main(void) {
    umask(0022);
    xlog("xosvid", "start pid=%d uid=%d", (int)getpid(), (int)getuid());

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    xpc_connection_t listener = xpc_connection_create_mach_service(
        XOSVI_SERVICE_NAME, q, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) {
        xlog("xosvid", "xpc_connection_create_mach_service failed");
        return 1;
    }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) {
            handle_connection((xpc_connection_t)peer);
        }
    });
    xpc_connection_resume(listener);
    arm_idle();
    xlog("xosvid", "listening on %s (idle %ds)", XOSVI_SERVICE_NAME, XOSVI_IDLE_SECONDS);
    dispatch_main();
    return 0;
}
