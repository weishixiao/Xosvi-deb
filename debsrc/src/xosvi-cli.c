// xosvi-cli —— 命令行客户端，用来在没有 App 的情况下自测 XPC 链路。
//
// 用法：
//   xosvi-cli ping
//   xosvi-cli diag
//   xosvi-cli build <project_dir> <script> [args...]
//   xosvi-cli install install|remove|purge|list [arg]
//   xosvi-cli symbolicate info|match <args...>
//
// 必须带 wiki.qaq.xosvi.client entitlement 才能连上守护；
// 构建脚本用 debsrc/Support/cli.entitlements 给它签名。

#include "xosvi_common.h"

#include <dispatch/dispatch.h>
#include <xpc/xpc.h>

// 请求在一个块里完成：发出去 → 起超时 → 等信号量 → 收尾。
// 不用 dispatch_main()——它不返回，超时分支无处收尾。
static int request(const char *command, int nargs, char **args) {
    __block int done = 0;
    __block int code = 1;

    dispatch_semaphore_t finish = dispatch_semaphore_create(0);

    void (^run)(void) = ^{
        xpc_connection_t conn = xpc_connection_create_mach_service(
            XOSVI_SERVICE_NAME, dispatch_get_main_queue(), 0);
        if (!conn) {
            fprintf(stderr, "error: cannot create connection to %s\n", XOSVI_SERVICE_NAME);
            code = 1;
            done = 1;
            dispatch_semaphore_signal(finish);
            return;
        }
        xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_ERROR) {
                const char *d = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION);
                fprintf(stderr, "xpc error: %s\n", d ? d : "unknown");
            }
        });
        xpc_connection_resume(conn);

        xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(msg, "command", command);
        if (nargs > 0) {
            xpc_object_t arr = xpc_array_create(NULL, 0);
            for (int i = 0; i < nargs; i++) {
                xpc_array_set_string(arr, XPC_ARRAY_APPEND, args[i]);
            }
            xpc_dictionary_set_value(msg, "args", arr);
            xpc_release(arr);
        }

        xpc_connection_send_message_with_reply(conn, msg, dispatch_get_main_queue(),
                                              ^(xpc_object_t reply) {
            if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
                const char *d = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION);
                fprintf(stderr, "xpc error: %s\n", d ? d : "unknown");
            } else {
                const char *err = xpc_dictionary_get_string(reply, "error");
                if (err) {
                    fprintf(stderr, "error: %s\n", err);
                } else {
                    const char *status = xpc_dictionary_get_string(reply, "status");
                    if (status) {
                        printf("status=%s pid=%lld uid=%lld\n", status,
                               (long long)xpc_dictionary_get_int64(reply, "pid"),
                               (long long)xpc_dictionary_get_int64(reply, "uid"));
                        code = 0;
                    }
                    const char *peer = xpc_dictionary_get_string(reply, "peer");
                    if (peer) {
                        printf("peer=%s audit_pid=%lld\n", peer,
                               (long long)xpc_dictionary_get_int64(reply, "audit_pid"));
                        code = 0;
                    }
                    const char *out = xpc_dictionary_get_string(reply, "stdout");
                    if (out) fputs(out, stdout);
                    if (xpc_dictionary_get_value(reply, "exit_code")) {
                        int64_t rc = xpc_dictionary_get_int64(reply, "exit_code");
                        printf("exit_code=%lld\n", (long long)rc);
                        code = (rc == 0) ? 0 : (int)rc;
                    }
                }
            }
            done = 1;
            dispatch_semaphore_signal(finish);
        });
        xpc_release(msg);

        // 超时：30 秒（按需启动允许守护被 launchd 现拉起来）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (!done) {
                fprintf(stderr, "error: timed out after 30s (service %s)\n", XOSVI_SERVICE_NAME);
                done = 1;
                code = 1;
                dispatch_semaphore_signal(finish);
            }
        });
    };

    dispatch_async(dispatch_get_main_queue(), run);
    dispatch_semaphore_wait(finish, DISPATCH_TIME_FOREVER);
    return code;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
                "usage: xosvi-cli ping\n"
                "       xosvi-cli diag\n"
                "       xosvi-cli build <project_dir> <script> [args...]\n"
                "       xosvi-cli install install|remove|purge|list [arg]\n"
                "       xosvi-cli symbolicate info|match <args...>\n");
        return 2;
    }
    const char *cmd = argv[1];
    if (!strcmp(cmd, "ping")) return request("ping", 0, NULL);
    if (!strcmp(cmd, "diag")) return request("xpc-diag", 0, NULL);
    if (!strcmp(cmd, "build") || !strcmp(cmd, "install") || !strcmp(cmd, "symbolicate")) {
        if (argc < 3) {
            fprintf(stderr, "error: %s needs arguments\n", cmd);
            return 2;
        }
        return request(cmd, argc - 2, argv + 2);
    }
    fprintf(stderr, "error: unknown command %s\n", cmd);
    return 2;
}
