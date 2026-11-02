// PythonInProcessBridge.swift — 把 shell 语法的 `python3 ...` 转成 PyEvalTool 的进程内调用
//
// 动机：越狱（rootHide / Relaxin）对 posix_spawn 返回 ENOSYS(85)，App 内 bin/python3
// 永远起不来。但 PyEvalTool（dlopen Python.framework + pyx_init/pyx_run_file）是通的。
// 于是 shell 里的 python3 不再 spawn，转调同一条进程内腿——两套腿合成一套。
//
// 本文件只做「argv 解析 + 返回结构转换」，绝不 spawn。

import Foundation

enum PythonInProcessBridge {

    /// shell_exec 的返回结构（与 ShellTool 其它分支保持一致）
    static func run(command: String, limit: Int = 200_000) -> [String: Any] {
        let body = dropInterpreter(command)
        let args = ShellExecTool.shellSplitArgs(body)

        // 1) 无参 / --version / -V / -h / --help → 等价于 py status 的版本探针
        if args.isEmpty || isVersionOrHelpOnly(args) {
            return call(["command": "eval",
                         "code": "import sys; print(sys.version); print(sys.executable or '(embedded-in-process)')",
                         "limit": 4000],
                        echo: command, limit: limit)
        }

        // 2) -c <code>
        if let i = args.firstIndex(where: { $0 == "-c" }) {
            guard i + 1 < args.count else {
                return failure(command, "python3: argument expected for the -c option", 2, hint: nil)
            }
            // `-c` 之后的第一个非选项串是 code（-c 只吃一个实参）
            let code = args[i + 1]
            // 剩余的实参按 CPython 语义成为 sys.argv[1:]
            let rest = Array(args.dropFirst(i + 2)).filter { !isPreOption($0) }
            return call(["command": "eval", "code": wrapArgv(code, rest), "limit": limit],
                        echo: command, limit: limit)
        }

        // 3) script.py [args...]
        if let first = args.first(where: { !$0.hasPrefix("-") }) {
            let expanded = (first as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                return failure(command,
                               "python3: can't open file '\(first)': No such file or directory",
                               2,
                               hint: "进程内解释器看不到 iSH 的 Alpine 路径；确认路径在 App 容器内。"
                                   + "要 Alpine 版 Python 用 sh -c 'python3 ...'")
            }
            return call(["command": "script", "path": expanded, "limit": limit],
                        echo: command, limit: limit)
        }

        // 4) -m module → 目前不映射（importlib.run_module 会动 sys.argv，风险高），
        //    明确报错，不要把用户引到 spawn 上。
        if let i = args.firstIndex(of: "-m"), i + 1 < args.count {
            return failure(command, "python3 -m \(args[i + 1]): 进程内模式不支持 -m",
                           1,
                           hint: "改用 `py command:eval code:\"import runpy; runpy.run_module('\(args[i + 1])', run_name='__main__')\"`"
                               + "，或把模块入口写成脚本后 `python3 <script.py>`")
        }

        return failure(command, "python3: 无法解析参数（仅支持 -c / <script.py> / --version）", 2, hint: nil)
    }

    // MARK: - 内部

    private static func call(_ params: [String: Any], echo: String, limit: Int) -> [String: Any] {
        do {
            let r = try PyEvalTool().invoke(params)
            var out = (r["stdout"] as? String) ?? ""
            if out.count > limit { out = String(out.prefix(limit)) + "\n…(截断)" }
            return ["command": echo,
                    "exit_code": (r["ok"] as? Bool == true) ? 0 : 1,
                    "stdout": out,
                    "ios_native": true,
                    "runtime_actual": "in-process-cpython",
                    "hint": "Python 运行在 App 进程内（dlopen Python.framework），不经 posix_spawn。"]
        } catch {
            // pyx_init 失败（Python.framework / stdlib 缺失）也走这里，不回退 spawn
            return failure(echo, String(describing: error), 1,
                           hint: "进程内解释器初始化失败，不等于可以回退 spawn（本机 spawn 恒 ENOSYS 85）。"
                               + "跑 `py command:status` 看 framework / stdlib 路径。")
        }
    }

    private static func failure(_ echo: String, _ msg: String, _ code: Int, hint: String?) -> [String: Any] {
        var r: [String: Any] = ["command": echo, "exit_code": code, "stdout": msg]
        if let hint { r["hint"] = hint }
        return r
    }

    /// 去掉开头的解释器名（python3 / python / /xx/bin/python3）
    private static func dropInterpreter(_ command: String) -> String {
        let t = command.trimmingCharacters(in: .whitespaces)
        for prefix in ["python3", "python"] where t == prefix || t.hasPrefix(prefix + " ") {
            return String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private static func isPreOption(_ a: String) -> Bool {
        ["-u", "-B", "-E", "-s", "-S", "-O", "-OO", "-q"].contains(a)
    }

    private static func isVersionOrHelpOnly(_ args: [String]) -> Bool {
        let meaningful = args.filter { !isPreOption($0) }
        guard meaningful.count == 1, let only = meaningful.first else { return false }
        return ["--version", "-V", "-h", "--help"].contains(only)
    }

    /// 把额外实参注入 sys.argv，保持 CPython 的 `sys.argv[0] == "-c"` 语义
    private static func wrapArgv(_ code: String, _ rest: [String]) -> String {
        guard !rest.isEmpty else { return code }
        let lit = rest.map(pyStringLiteral).joined(separator: ", ")
        return "import sys as _s; _s.argv = [\"-c\"] + [\(lit)]\n" + code
    }

    /// 生成 Python 源码里的安全字符串字面量（先转义反斜杠，再转义双引号）
    static func pyStringLiteral(_ s: String) -> String {
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + esc + "\""
    }
}
