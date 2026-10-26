// py_shim.h — 进程内 CPython 嵌入（Xosvi）
//
// 为什么需要：本机越狱对 posix_spawn 返回 ENOSYS(85)，bin/python3 这个
// CLI 永远起不来。但 Python.framework 和整套 stdlib 本来就在 App 包里，
// 只是之前靠 spawn 一个 CLI 去启动它。
//
// 这里改用 dlopen 把框架加载进当前进程，dlsym 取 Py_* 入口，
// 直接在同一进程里跑 Python——一次 spawn 都不需要。
//
// 约束：Python 与 App 共享生命周期，解释器崩溃会带崩 App；
// 且无法安全地打断正在执行的代码（没有超时杀进程这条路）。

#ifndef PY_SHIM_H
#define PY_SHIM_H

#include <stddef.h>

/// 初始化进程内解释器（幂等）。成功返回 0。
/// frameworkPath: .../Frameworks/Python.framework/Python
/// home:          .../python（PYTHONHOME）
/// pythonPath:    冒号分隔的 sys.path 目录列表
/// err/errCap:    失败信息
int pyx_init(const char *frameworkPath, const char *home, const char *pythonPath,
             char *err, size_t errCap);

/// 解释器是否已就绪
int pyx_ready(void);

/// 执行一个 .py 文件，stdout/stderr 写入 outPath（UTF-8）。
/// envPath: 可选的环境变量 JSON 文件（{"KEY":"VALUE"}），执行前更新 os.environ；可为 NULL。
/// 返回 0 成功（脚本可能自身抛错，错误已写进 outPath）；-1 解释器未就绪。
int pyx_run_file(const char *codePath, const char *outPath, const char *envPath,
                 char *err, size_t errCap);

#endif
