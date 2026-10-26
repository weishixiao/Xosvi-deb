// PyEvalTool.swift — 进程内 CPython 执行（不 spawn 任何子进程）
//
// 背景：越狱对 posix_spawn 返回 ENOSYS(85)，bin/python3 永远起不来。
// Python.framework + stdlib 本来就在包里，改成 dlopen 进当前进程后
// 直接跑解释器，一次 spawn 都不需要。

import Foundation
import CPyEmbed

final class PyEvalTool: MCPTool {
    let definition = ToolDefinition(
        name: "py",
        summary: "Run Python in-process (no subprocess). Commands: eval (code) / script (path) / status. Use for: parsing/patching bytes, struct unpack, regex over binaries, quick calculations — on devices where spawning python3 is blocked by the jailbreak (ENOSYS 85). Don't use for: long-running servers (interpreter shares the app process). Example: py command:eval code:\"print(open('/tmp/a.bin','rb').read(8).hex())\"",
        parameters: [
            "command": "eval / script / status",
            "code": "Python source (for eval)",
            "path": "absolute .py path (for script)",
            "limit": "max output chars (default 200000)"
        ],
        verified: true, category: "terminal", prerequisites: [
            "首次调用会初始化解释器（约 1 秒）；之后常驻进程",
            "解释器与 App 同进程：死循环会卡住调用线程，且没有安全的超时强杀"
        ])

    private static let lock = NSLock()
    private static var initialized = false
    private static var initError = ""

    private var frameworkPath: String { Bundle.main.bundlePath + "/Frameworks/Python.framework/Python" }
    private var homePath: String { Bundle.main.bundlePath + "/python" }
    private var pathList: String {
        let base = homePath + "/lib/python3.14"
        return [base, base + "/lib-dynload", base + "/site-packages"].joined(separator: ":")
    }

    private func ensureInit() -> String {
        PyEvalTool.lock.lock()
        defer { PyEvalTool.lock.unlock() }
        if PyEvalTool.initialized { return "" }
        if !PyEvalTool.initError.isEmpty { return PyEvalTool.initError }

        guard FileManager.default.fileExists(atPath: frameworkPath) else {
            PyEvalTool.initError = "Python.framework 不在包里：\(frameworkPath)"
            return PyEvalTool.initError
        }
        // 关键：stdlib 路径不对时 Py_Initialize 会走 Py_FatalError →
        // 直接 exit()/abort 掉整个 App（不是抛异常）。所以先自己校验 encodings，
        // 缺了就完全不初始化。
        let encodings = homePath + "/lib/python3.14/encodings/__init__.py"
        guard FileManager.default.fileExists(atPath: encodings) else {
            PyEvalTool.initError = "stdlib 缺失（找不到 \(encodings)）——初始化会 fatal，已放弃"
            return PyEvalTool.initError
        }
        var err = [CChar](repeating: 0, count: 1024)
        let rc = frameworkPath.withCString { fp in
            homePath.withCString { hm in
                pathList.withCString { pp in
                    pyx_init(fp, hm, pp, &err, err.count)
                }
            }
        }
        if rc != 0 {
            PyEvalTool.initError = String(cString: err)
            return PyEvalTool.initError
        }
        PyEvalTool.initialized = true
        return ""
    }

    private func run(code: String, limit: Int) throws -> String {
        let e = ensureInit()
        if !e.isEmpty {
            throw MCPError.classified("py: 解释器初始化失败 — \(e)", code: "PY_INIT_FAILED",
                                      reason: "environment",
                                      nextStep: "确认 App 包内存在 Frameworks/Python.framework 与 python/lib/python3.14；或改用 diagnose spawn 检查环境")
        }
        let tmp = NSTemporaryDirectory()
        let id = UUID().uuidString
        let codePath = tmp + "/pycode_\(id).py"
        let outPath = tmp + "/pyout_\(id).txt"
        let envPath = tmp + "/pyenv_\(id).json"
        defer {
            try? FileManager.default.removeItem(atPath: codePath)
            try? FileManager.default.removeItem(atPath: outPath)
            try? FileManager.default.removeItem(atPath: envPath)
        }
        try code.write(toFile: codePath, atomically: true, encoding: .utf8)
        // v6.6.19：用户环境变量注入 os.environ
        try? EnvVars.pythonEnvJSON().write(toFile: envPath, atomically: true, encoding: .utf8)

        var err = [CChar](repeating: 0, count: 1024)
        let rc = codePath.withCString { cp in
            outPath.withCString { op in
                envPath.withCString { ep in
                    pyx_run_file(cp, op, ep, &err, err.count)
                }
            }
        }
        let out = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
        if rc != 0 && out.isEmpty {
            throw MCPError.classified("py: 执行失败 — \(String(cString: err))", code: "PY_RUN_FAILED",
                                      reason: "tool", nextStep: "检查代码语法；解释器级错误无 traceback 时多为 stdlib 路径问题")
        }
        return out.count > limit ? String(out.prefix(limit)) + "\n…(截断)" : out
    }

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = (params["command"] as? String)?.lowercased(), !command.isEmpty else {
            throw MCPError.invalidParams("py: missing command (eval / script / status)")
        }
        let limit = max(1000, (params["limit"] as? Int) ?? 200_000)

        switch command {
        case "status":
            let e = ensureInit()
            if !e.isEmpty {
                return ["ready": false, "error": e, "framework": frameworkPath, "home": homePath,
                        "python_path": pathList]
            }
            let ver = (try? run(code: "import sys; print(sys.version); print(sys.executable or '(embedded)')", limit: 4000)) ?? ""
            return ["ready": true, "framework": frameworkPath, "home": homePath,
                    "python_path": pathList, "version": ver.trimmingCharacters(in: .whitespacesAndNewlines),
                    "note": "解释器运行在 App 进程内，不经过任何子进程"]

        case "eval":
            guard let code = params["code"] as? String, !code.isEmpty else {
                throw MCPError.invalidParams("py eval: missing code")
            }
            let out = try run(code: code, limit: limit)
            return ["command": "eval", "ok": true, "stdout": out, "runtime": "in-process CPython"]

        case "script":
            guard let path = params["path"] as? String, !path.isEmpty else {
                throw MCPError.invalidParams("py script: missing path")
            }
            guard let code = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw MCPError.classified("py: 读不到脚本 \(path)", code: "NOT_FOUND",
                                          reason: "path", nextStep: "确认路径与编码（UTF-8）")
            }
            let out = try run(code: code, limit: limit)
            return ["command": "script", "ok": true, "path": path, "stdout": out, "runtime": "in-process CPython"]

        default:
            throw MCPError.invalidParams("py: unknown command '\(command)' (eval / script / status)")
        }
    }
}
