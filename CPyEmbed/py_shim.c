// py_shim.c — 用 dlopen/dlsym 在进程内跑 CPython
//
// 不链接 Python.framework、不需要 Python 头文件：
// 运行时按绝对路径 dlopen，再用 dlsym 取 Py_* 符号。
// 这样既不受 spawn 拦截影响，也不依赖构建期的 framework 路径。

#include "py_shim.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void  (*fn_Initialize)(void);
typedef int   (*fn_IsInitialized)(void);
typedef int   (*fn_RunSimpleString)(const char *);
typedef int   (*fn_GILStateEnsure)(void);
typedef void  (*fn_GILStateRelease)(int);

static void *g_framework = NULL;
static fn_Initialize g_init = NULL;
static fn_IsInitialized g_isInit = NULL;
static fn_RunSimpleString g_run = NULL;
static fn_GILStateEnsure g_gilEnsure = NULL;
static fn_GILStateRelease g_gilRelease = NULL;

static void seterr(char *err, size_t cap, const char *msg) {
    if (!err || cap == 0) return;
    snprintf(err, cap, "%s", msg ? msg : "");
}

int pyx_ready(void) {
    return g_run != NULL && g_isInit != NULL && g_isInit();
}

int pyx_init(const char *frameworkPath, const char *home, const char *pythonPath,
             char *err, size_t errCap)
{
    seterr(err, errCap, "");
    if (pyx_ready()) return 0;

    // 1) PYTHONHOME / PYTHONPATH 必须在 Py_Initialize 之前生效：
    //    Py_Initialize 会读环境变量定位 stdlib（encodings 等），
    //    路径不对会直接 fatal "Failed to import encodings module"。
    if (home && home[0]) setenv("PYTHONHOME", home, 1);
    if (pythonPath && pythonPath[0]) setenv("PYTHONPATH", pythonPath, 1);

    // 2) 加载框架
    if (!g_framework) {
        g_framework = dlopen(frameworkPath, RTLD_NOW | RTLD_GLOBAL);
        if (!g_framework) {
            char buf[512];
            const char *e = dlerror();
            snprintf(buf, sizeof buf, "dlopen 失败: %s", e ? e : "(no dlerror)");
            seterr(err, errCap, buf);
            return -1;
        }
    }

    g_init       = (fn_Initialize)dlsym(g_framework, "Py_Initialize");
    g_isInit     = (fn_IsInitialized)dlsym(g_framework, "Py_IsInitialized");
    g_run        = (fn_RunSimpleString)dlsym(g_framework, "PyRun_SimpleString");
    g_gilEnsure  = (fn_GILStateEnsure)dlsym(g_framework, "PyGILState_Ensure");
    g_gilRelease = (fn_GILStateRelease)dlsym(g_framework, "PyGILState_Release");

    if (!g_init || !g_isInit || !g_run || !g_gilEnsure || !g_gilRelease) {
        seterr(err, errCap, "dlsym 失败：Python.framework 缺少 Py_* 入口");
        return -1;
    }

    if (!g_isInit()) {
        g_init();
    }
    if (!g_isInit()) {
        seterr(err, errCap, "Py_Initialize 后 Py_IsInitialized 仍为 0（stdlib 路径可能不对）");
        return -1;
    }
    seterr(err, errCap, "ok");
    return 0;
}

int pyx_run_file(const char *codePath, const char *outPath, const char *envPath,
                 char *err, size_t errCap)
{
    seterr(err, errCap, "");
    if (!pyx_ready()) { seterr(err, errCap, "解释器未初始化"); return -1; }

    // 用文件路径传代码/环境/输出，避免把用户内容拼进字符串字面量（转义地狱）。
    static char code[8192];
    snprintf(code, sizeof code,
        "import sys, io, os, json, traceback\n"
        "_code_path = %c%s%c\n"
        "_out_path  = %c%s%c\n"
        "_env_path  = %c%s%c\n"
        "if _env_path:\n"
        "    try:\n"
        "        with open(_env_path, encoding='utf-8') as _ef:\n"
        "            os.environ.update({str(k): str(v) for k, v in json.load(_ef).items()})\n"
        "    except Exception:\n"
        "        pass\n"
        "_buf = io.StringIO()\n"
        "_old = sys.stdout\n"
        "sys.stdout = _buf\n"
        "try:\n"
        "    _src = open(_code_path, encoding='utf-8').read()\n"
        "    exec(compile(_src, '<py.eval>', 'exec'), {'__name__': '__main__'})\n"
        "except BaseException:\n"
        "    traceback.print_exc(file=_buf)\n"
        "finally:\n"
        "    sys.stdout = _old\n"
        "    try:\n"
        "        open(_out_path, 'w', encoding='utf-8').write(_buf.getvalue())\n"
        "    except Exception:\n"
        "        pass\n",
        '\'', codePath, '\'', '\'', outPath, '\'', '\'', envPath ? envPath : "", '\'');

    int gil = g_gilEnsure();
    int rc = g_run(code);
    g_gilRelease(gil);

    if (rc != 0) {
        seterr(err, errCap, "PyRun_SimpleString 返回非 0");
        return rc;
    }
    return 0;
}
