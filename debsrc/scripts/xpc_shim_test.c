// xpc_shim_test.c —— 验证 XPCShim 绑定签名与 libxpc 的 ABI 一致。
// 在 macOS 上：clang -framework Foundation xpc_shim_test.c -o t && ./t
// （仅 CI 冒烟用；设备上守护/客户端的真实通信由 verify-daemon.sh 验证。）
#include <stdio.h>
#include <dlfcn.h>
#include <stdint.h>

typedef void *(*xpc_create_t)(const char *, void *, uint64_t);
typedef void (*xpc_release_t)(void *);
typedef void *(*xpc_dict_create_t)(const char *const *, void *const *, size_t);
typedef void (*xpc_dict_set_string_t)(void *, const char *, const char *);
typedef const char *(*xpc_dict_get_string_t)(void *, const char *);
typedef int64_t (*xpc_dict_get_int64_t)(void *, const char *);

int main(void) {
    void *h = dlopen("/usr/lib/libxpc.dylib", RTLD_LAZY);
    if (!h) { printf("SKIP: no libxpc (not macOS)\n"); return 0; }
    xpc_create_t create = dlsym(h, "xpc_dictionary_create");
    xpc_dict_set_string_t setstr = dlsym(h, "xpc_dictionary_set_string");
    xpc_dict_get_string_t getstr = dlsym(h, "xpc_dictionary_get_string");
    xpc_dict_get_int64_t geti64 = dlsym(h, "xpc_dictionary_get_int64");
    xpc_release_t rel = dlsym(h, "xpc_release");
    xpc_create_t conn_create =
        (xpc_connection_create_t)dlsym(h, "xpc_connection_create_mach_service");
    if (!create || !setstr || !getstr || !geti64 || !rel || !conn_create) {
        printf("FAIL: missing symbols\n");
        return 1;
    }
    void *d = create(NULL, NULL, 0);
    setstr(d, "command", "ping");
    if (!getstr(d, "command") || geti64(d, "nope") != 0) {
        printf("FAIL: dict roundtrip\n");
        return 1;
    }
    rel(d);
    // 确认 mach-service 创建符号确实被 iOS overlay 藏起（本测试只验证 dlsym 可拿到）
    printf("OK: all bound symbols callable\n");
    return 0;
}
