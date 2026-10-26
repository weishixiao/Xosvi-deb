import Foundation

/// v6.6.11：Hax 电脑（AI 可调用的 Linux 工作站）。
///
/// 与 UI 上的「Hax 电脑」面板是同一套能力：AI 在对话中遇到不会的 API、需要验证一段代码、
/// 或者要查资料时，直接调这个工具自己动手，结果回显在会话窗口里，不需要用户切到终端手动跑。
///
/// 子命令：
///   status  环境状态（rootfs / 引擎 / 越狱 / 工具链）
///   exec    在 Alpine 里执行命令（默认工作目录 /root，root 权限视角）
///   search  网络搜索（复用 web.search 的多引擎）
///   fetch   抓取网页正文（复用 web.fetch）
///   read    读文件（iOS 真实路径或 Alpine 路径都可以）
///   write   写文件（自动判断落到 iOS 还是 Alpine）
///   install 安装软件包（apk add / pip install 自动识别）
///   code    在 Hax 电脑里跑一段代码（python3 / sh / node），返回输出
final class HaxComputerTool: MCPTool {
    let definition = ToolDefinition(
        name: "hax",
        summary: "Hax computer: a real Alpine Linux box the AI can drive itself. Use for: verify code before answering, run shell/python to check behavior, search the web when unsure, read/write files, install packages. Don't use for: editing the user's iOS app project files directly (use project tools), simple one-off file listing (use shell.exec). Example: user asks 'does this regex work?' → hax {command:'code', lang:'python3', code:'import re; print(re.match(...))'}; stuck on a library error → hax {command:'search', query:'flask 3.0 ImportError werkzeug'}.",
        parameters: [
            "command": "status / exec / search / fetch / read / write / install / code",
            "cmd": "For exec: shell command (runs in Alpine, cwd=/root)",
            "code": "For code: source code to run",
            "lang": "For code: python3 (default) / sh / node / lua",
            "query": "For search: keywords",
            "url": "For fetch: http(s) URL",
            "path": "For read/write: absolute path (iOS path or Alpine path)",
            "content": "For write: file content (utf8)",
            "pkg": "For install: package name (auto: apk add or pip install)",
            "timeout": "Seconds (default 60, max 600)"
        ],
        verified: true,
        category: "terminal",
        prerequisites: [
            "需要 设置 → 安全 → 打开「Alpine/iSH 引擎」（默认关闭防闪退）",
            "exec/code 在 rootfs 内运行，首次调用会自动 boot 内核（数秒）"
        ])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = (params["command"] as? String)?.lowercased(), !command.isEmpty else {
            throw MCPError.invalidParams("command required: status/exec/search/fetch/read/write/install/code")
        }
        let timeout = min(max(params["timeout"] as? Int ?? 60, 5), 600)

        switch command {
        case "status":   return try status()
        case "exec":     return try exec(params, timeout: timeout)
        case "code":     return try runCode(params, timeout: timeout)
        case "search":   return try search(params)
        case "fetch":    return try fetch(params)
        case "read":     return try readFile(params)
        case "write":    return try writeFile(params)
        case "install":  return try install(params, timeout: timeout)
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: status/exec/search/fetch/read/write/install/code")
        }
    }

    // MARK: - status

    private func status() throws -> [String: Any] {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let rootfs = docs.appendingPathComponent("alpine-rootfs").path
        let dataPath = rootfs + "/data"
        let installed = fm.fileExists(atPath: dataPath)
        let engineOn = UserDefaults.standard.bool(forKey: "alpineEngineEnabled")
        let booted = ISHEngine.isBooted
        let jb = JBEnvironment.kind.rawValue

        var message = "Hax 电脑："
        if !engineOn {
            message += "引擎未开启（设置 → 安全 → Alpine/iSH 引擎）"
        } else if !installed {
            message += "引擎已开，rootfs 未安装（首次 exec 会自动解压）"
        } else if booted {
            message += "运行中"
        } else {
            message += "就绪（首次 exec 会 boot 内核，约数秒）"
        }

        return [
            "message": message,
            "engine_enabled": engineOn,
            "rootfs_installed": installed,
            "rootfs_path": rootfs,
            "kernel_booted": booted,
            "jailbreak": jb,
            "jailbreak_root": JBEnvironment.rootPrefix.isEmpty ? "(none)" : JBEnvironment.rootPrefix
        ]
    }

    // MARK: - exec / code

    private func exec(_ params: [String: Any], timeout: Int) throws -> [String: Any] {
        guard let cmd = params["cmd"] as? String, !cmd.isEmpty else {
            throw MCPError.invalidParams("cmd required")
        }
        // 默认工作目录 /root（root 权限视角）
        let wrapped = "cd /root 2>/dev/null || cd /; \(cmd)"
        let r = ISHEngine.exec(wrapped, timeout: TimeInterval(timeout))
        return [
            "message": r.exitCode == 0 ? "执行成功" : "退出码 \(r.exitCode)",
            "stdout": r.output,
            "exit_code": Int(r.exitCode),
            "timed_out": r.timedOut,
            "cwd": "/root",
            "engine": "alpine-iSH"
        ]
    }

    private func runCode(_ params: [String: Any], timeout: Int) throws -> [String: Any] {
        guard let code = params["code"] as? String, !code.isEmpty else {
            throw MCPError.invalidParams("code required")
        }
        let lang = (params["lang"] as? String ?? "python3").lowercased()

        // 写入临时脚本再用对应解释器跑（避免 heredoc 引号问题）
        let tmpName = "hax_\(Int(Date().timeIntervalSince1970))_\(UInt32.random(in: 100...999))"
        let tmpPath = "/tmp/\(tmpName)"
        let b64 = Data(code.utf8).base64EncodedString()

        let interp: String
        let ext: String
        switch lang {
        case "sh", "bash": interp = "/bin/sh"; ext = "sh"
        case "node":       interp = "node";    ext = "js"
        case "lua":        interp = "lua";     ext = "lua"
        default:           interp = "python3"; ext = "py"
        }
        let scriptPath = "\(tmpPath).\(ext)"
        let prep = "mkdir -p /tmp && printf '%s' '\(b64)' | base64 -d > '\(scriptPath)'"
        let run = "cd /root 2>/dev/null || cd /; \(prep) && \(interp) '\(scriptPath)'"
        let r = ISHEngine.exec(run, timeout: TimeInterval(timeout))
        _ = ISHEngine.exec("rm -f '\(scriptPath)'", timeout: 10)

        return [
            "message": r.exitCode == 0 ? "\(lang) 运行完成" : "\(lang) 退出码 \(r.exitCode)",
            "stdout": r.output,
            "exit_code": Int(r.exitCode),
            "timed_out": r.timedOut,
            "lang": lang
        ]
    }

    // MARK: - search / fetch

    private func search(_ params: [String: Any]) throws -> [String: Any] {
        guard let q = params["query"] as? String, !q.isEmpty else {
            throw MCPError.invalidParams("query required")
        }
        var p: [String: Any] = ["query": q]
        if let limit = params["limit"] as? Int { p["limit"] = limit }
        let r = try WebSearchTool().invoke(p)
        return [
            "message": "搜索结果（\(q)）",
            "result": r
        ]
    }

    private func fetch(_ params: [String: Any]) throws -> [String: Any] {
        guard let url = params["url"] as? String, !url.isEmpty else {
            throw MCPError.invalidParams("url required")
        }
        let r = try WebFetchTool().invoke(["url": url])
        return [
            "message": "已抓取 \(url)",
            "result": r
        ]
    }

    // MARK: - file

    private func readFile(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("path required")
        }
        // ① 先按 iOS 真实路径读
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            return ["message": "已读取（iOS 路径）", "path": path, "content": text, "source": "ios"]
        }
        // ② 退回 Alpine 读
        let r = ISHEngine.exec("cat '\(path.replacingOccurrences(of: "'", with: "'\\''"))'", timeout: 30)
        if r.exitCode == 0 {
            return ["message": "已读取（Alpine 路径）", "path": path, "content": r.output, "source": "alpine"]
        }
        return ["message": "读取失败", "path": path, "error": r.output]
    }

    private func writeFile(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty,
              let content = params["content"] as? String else {
            throw MCPError.invalidParams("path and content required")
        }
        // Alpine 路径（/root /home /etc /tmp 等）→ base64 经 shell 写入
        let alpinePrefixes = ["/root/", "/home/", "/etc/", "/usr/", "/var/", "/tmp/", "/opt/"]
        if alpinePrefixes.contains(where: { path.hasPrefix($0) }) && !path.contains("/Documents/") {
            let b64 = Data(content.utf8).base64EncodedString()
            let dir = (path as NSString).deletingLastPathComponent
            let cmd = "mkdir -p '\(dir)' && printf '%s' '\(b64)' | base64 -d > '\(path)'"
            let r = ISHEngine.exec(cmd, timeout: 60)
            return [
                "message": r.exitCode == 0 ? "已写入（Alpine 路径）" : "写入失败",
                "path": path,
                "exit_code": Int(r.exitCode),
                "source": "alpine"
            ]
        }
        // iOS 真实路径 → FileManager
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return ["message": "已写入（iOS 路径）", "path": path, "source": "ios"]
        } catch {
            return ["message": "写入失败：\(error.localizedDescription)", "path": path]
        }
    }

    // MARK: - install

    private func install(_ params: [String: Any], timeout: Int) throws -> [String: Any] {
        guard let pkg = params["pkg"] as? String, !pkg.isEmpty else {
            throw MCPError.invalidParams("pkg required")
        }
        // pip 包名常见特征（含 -/_ 且不是 apk 常见包时优先 pip）
        let isPip = pkg.contains("==") || pkg.contains(">=")
            || ["requests", "numpy", "pandas", "flask", "django", "beautifulsoup4"].contains(pkg.lowercased())
        if isPip {
            let r = ISHEngine.exec("pip3 install --quiet '\(pkg)'", timeout: TimeInterval(timeout))
            return [
                "message": r.exitCode == 0 ? "pip 安装成功：\(pkg)" : "pip 安装失败（退出码 \(r.exitCode)）",
                "output": r.output,
                "manager": "pip3",
                "exit_code": Int(r.exitCode)
            ]
        }
        let r = ISHEngine.apkAdd([pkg], timeout: TimeInterval(timeout))
        return [
            "message": r.exitCode == 0 ? "apk 安装成功：\(pkg)" : "apk 安装失败（退出码 \(r.exitCode)）",
            "output": r.output,
            "manager": "apk",
            "exit_code": Int(r.exitCode)
        ]
    }
}
