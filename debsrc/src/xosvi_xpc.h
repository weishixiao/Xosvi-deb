// xosvi_xpc.h —— 自带声明的 libxpc 私有接口。
//
// 为什么不用 <xpc/xpc.h>：
//   iOS SDK 把 xpc_connection_create_mach_service / xpc_connection_get_pid
//   标成 `API_UNAVAILABLE(ios)`（它们只对系统进程公开）。第三方向二进制
//   在越狱环境下照常能调——符号在 libxpc 里就有，只是头文件不给声明。
//   所以这里按 libxpc 的 ABI 重新声明一遍，**不 include SDK 的 xpc 头**。
//
//   这份声明与 SDK 头逐字段等价，只是不带 availability 标记。

#ifndef XOSVI_XPC_H
#define XOSVI_XPC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

// ── 基础类型（与 OS_xpc_object 的 C 视图一致）────────────────────────────
typedef void *xpc_object_t;
typedef struct _xpc_connection_s *xpc_connection_t;
typedef struct _xpc_type_s *xpc_type_t;

typedef struct {
    unsigned int val[8];
} xosvi_audit_token_t;

// ── 类型对象（libxpc 导出的全局符号）────────────────────────────────────
extern struct _xpc_type_s _xpc_type_bool;
extern struct _xpc_type_s _xpc_type_int64;
extern struct _xpc_type_s _xpc_type_string;
extern struct _xpc_type_s _xpc_type_array;
extern struct _xpc_type_s _xpc_type_dictionary;
extern struct _xpc_type_s _xpc_type_connection;
extern struct _xpc_type_s _xpc_type_error;

#define XPC_TYPE_BOOL       (&_xpc_type_bool)
#define XPC_TYPE_INT64      (&_xpc_type_int64)
#define XPC_TYPE_STRING     (&_xpc_type_string)
#define XPC_TYPE_ARRAY      (&_xpc_type_array)
#define XPC_TYPE_DICTIONARY (&_xpc_type_dictionary)
#define XPC_TYPE_CONNECTION (&_xpc_type_connection)
#define XPC_TYPE_ERROR      (&_xpc_type_error)

#define XPC_CONNECTION_MACH_SERVICE_LISTENER (1ull << 0)
#define XPC_ARRAY_APPEND ((size_t)-1)

// 错误对象里取描述文本用的键（libxpc 导出的常量字符串）
extern const char *const XPC_ERROR_KEY_DESCRIPTION;

// ── 连接 ────────────────────────────────────────────────────────────────
xpc_connection_t xpc_connection_create_mach_service(const char *name,
                                                    void *targetq,
                                                    uint64_t flags);
void xpc_connection_set_event_handler(xpc_connection_t connection,
                                      void (^handler)(xpc_object_t event));
void xpc_connection_set_target_queue(xpc_connection_t connection, void *targetq);
void xpc_connection_resume(xpc_connection_t connection);
void xpc_connection_cancel(xpc_connection_t connection);
void xpc_connection_send_message(xpc_connection_t connection, xpc_object_t message);
void xpc_connection_send_message_with_reply(xpc_connection_t connection,
                                            xpc_object_t message,
                                            void *replyq,
                                            void (^handler)(xpc_object_t reply));
void xpc_connection_get_audit_token(xpc_connection_t connection,
                                    xosvi_audit_token_t *token);
pid_t xpc_connection_get_pid(xpc_connection_t connection);

// ── 类型判定 / 取值 ──────────────────────────────────────────────────────
xpc_type_t xpc_get_type(xpc_object_t object);
bool xpc_bool_get_value(xpc_object_t object);
int64_t xpc_int64_get_value(xpc_object_t object);

// ── 字典 ────────────────────────────────────────────────────────────────
xpc_object_t xpc_dictionary_create(const char *const *keys,
                                   const xpc_object_t *values,
                                   size_t count);
xpc_object_t xpc_dictionary_create_reply(xpc_object_t original);
void xpc_dictionary_set_bool(xpc_object_t dict, const char *key, bool value);
void xpc_dictionary_set_int64(xpc_object_t dict, const char *key, int64_t value);
void xpc_dictionary_set_string(xpc_object_t dict, const char *key, const char *value);
void xpc_dictionary_set_value(xpc_object_t dict, const char *key, xpc_object_t value);
bool xpc_dictionary_get_bool(xpc_object_t dict, const char *key);
int64_t xpc_dictionary_get_int64(xpc_object_t dict, const char *key);
const char *xpc_dictionary_get_string(xpc_object_t dict, const char *key);
xpc_object_t xpc_dictionary_get_value(xpc_object_t dict, const char *key);
xpc_object_t xpc_dictionary_get_array(xpc_object_t dict, const char *key);

// ── 数组 ────────────────────────────────────────────────────────────────
xpc_object_t xpc_array_create(const xpc_object_t *objects, size_t count);
void xpc_array_set_string(xpc_object_t array, size_t index, const char *value);
size_t xpc_array_get_count(xpc_object_t array);
const char *xpc_array_get_string(xpc_object_t array, size_t index);

// ── 生命周期 ────────────────────────────────────────────────────────────
void xpc_release(xpc_object_t object);

// audit_token_to_pid 在 libbsm（iOS 上没有导出头，且不一定可链接），
// 这里按内核 ABI 直接取：audit_token_t 的 val[5] 就是 pid。
static inline int xosvi_audit_token_pid(xosvi_audit_token_t token) {
    return (int)token.val[5];
}

#endif
