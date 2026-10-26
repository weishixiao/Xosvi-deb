import Foundation

/// v6.6.12：引擎控制工具 —— 让 AI 自主管理 Alpine/iSH 引擎。
///
/// 背景：Xosvi 有大量工具依赖 Alpine（db/file/package/tool.install/shell 的 apk 分支等），
/// 而引擎默认关闭（历史上 arm64 上 iSH 段错误导致闪退）。AI 遇到这类工具被门控挡住时，
/// 以前只能让用户去设置里手动开。本工具让 AI 自己就能开/关/诊断。
///
/// 子命令：
///   status   引擎状态 + 依赖 Alpine 的工具清单
///   on       开启引擎
///   off      关闭引擎
///   restart  重置引擎状态（崩溃后恢复；不会重启 App）
///   probe    逐项能力探测（原生 vs Alpine）
final class EngineTool: MCPTool {
    let definition = ToolDefinition(
        name: "engine",
        summary: "Control the Alpine/iSH engine that db/file/package/tool.install depend on. Commands: status / on / off / restart / reset-rootfs / probe. Use for: engine off and a tool needs it, check which tools need Alpine, recover after an engine crash (repeated 'rc=-2' → reset-rootfs then fully relaunch the app). Don't use for: running commands inside Alpine (use hax or shell.exec). Example: db fails with 'iSH 已关闭' → engine {command:'on'} then retry.",
        parameters: [
            "command": "status / on / off / restart / reset-rootfs / probe"
        ],
        verified: true,
        category: "terminal",
        prerequisites: [
            "开启引擎后 iSH 在 arm64 上有段错误风险；exec 已走 TrollishRunner 子进程隔离，崩溃只死子进程"
        ])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = (params["command"] as? String)?.lowercased(), !command.isEmpty else {
            throw MCPError.invalidParams("command required: status/on/off/restart/probe")
        }
        switch command {
        case "status":  return status()
        case "on":      return setEnabled(true)
        case "off":     return setEnabled(false)
        case "restart": return restart()
        case "reset-rootfs", "reset_rootfs", "resetrootfs": return resetRootfs()
        case "probe":   return probe()
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: status/on/off/restart/reset-rootfs/probe")
        }
    }

    // MARK: - status

    private func status() -> [String: Any] {
        let enabled = UserDefaults.standard.bool(forKey: "alpineEngineEnabled")
        let booted = ISHEngine.isBooted
        let isolated = TrollishRunner.enabled

        var message: String
        if !enabled {
            // v7.3.0：自动开启恒为开，用户不用管
            message = "引擎关闭（下次需要时 exec 会自动开启）"
        } else if booted {
            message = "引擎运行中"
        } else {
            message = "引擎已启用，未 boot（首次调用会解压 rootfs，约 5-10 秒）"
        }

        return [
            "message": message,
            "engine_enabled": enabled,
            "auto_start": autoStart,
            "kernel_booted": booted,
            "child_isolation": isolated,
            "jailbreak": JBEnvironment.kind.rawValue,
            "rootfs": ISHEngine.rootfsInfo(),
            "alpine_dependent_tools": [
                ["tool": "db",            "why": "sqlite3 查 App 数据库；无 Alpine 时回退 iOS 原生 sqlite3"],
                ["tool": "file",          "why": "file/strings 分析二进制；无 Alpine 时回退原生 file"],
                ["tool": "package",       "why": "deb/ipa 解包（ar/tar/zip）；无 Alpine 时回退原生 bsdtar"],
                ["tool": "tool.install",  "why": "apk add / pip install 必须 Alpine"],
                ["tool": "shell.exec",    "why": "runtime=alpine 时走引擎；runtime=ios 不需要"],
                ["tool": "hax",           "why": "exec/code/install 必须 Alpine；search/fetch/read 不需要"],
                ["tool": "app.decrypt",   "why": "部分砸壳路径调用 ldid/otool"]
            ],
            "native_alternatives": [
                "ls / cat / grep / find / du / stat（ShellTool 原生管线）",
                "sqlite3（iOS 系统自带）",
                "plutil（plist 解析）",
                "strings / nm / hexdump / objdump（原生 binutils）",
                "python3（App 内置原生 ARM64 CPython，可跑 numpy）",
                "bsdtar（原生解包 zip/tar/ipa）"
            ],
            "hint": "AI 可直接调 engine {command:\"on\"} 开启，无需用户手动操作"
        ]
    }

    // MARK: - 开关

    private func setEnabled(_ on: Bool) -> [String: Any] {
        UserDefaults.standard.set(on, forKey: "alpineEngineEnabled")
        AuditLog.shared.log("engine.toggle", detail: on ? "on (by AI)" : "off (by AI)")
        return [
            "message": on ? "Alpine/iSH 引擎已开启" : "Alpine/iSH 引擎已关闭（原生工具不受影响）",
            "engine_enabled": on,
            "kernel_booted": ISHEngine.isBooted
        ]
    }

    private func restart() -> [String: Any] {
        // 重置 boot 状态——下次调用会重新 cish_boot（崩溃后恢复用）
        let wasEnabled = UserDefaults.standard.bool(forKey: "alpineEngineEnabled")
        ISHEngine.resetRuntimeState()
        return [
            "message": wasEnabled
                ? "引擎运行态已重置，下次命令会重新 boot（若反复崩溃请重启 App）"
                : "引擎未启用；已重置运行态",
            "engine_enabled": wasEnabled,
            "kernel_booted": ISHEngine.isBooted
        ]
    }

    /// v6.6.10：重建 rootfs——真机上 `rm -rf *` 曾删掉 guest 的 /proc 等挂载点，
    /// 之后每次 spawn 都是 rc=-2，而 restart 只重置 state、复用同一份坏 rootfs，永远好不了。
    private func resetRootfs() -> [String: Any] {
        let r = ISHEngine.resetRootfs()
        return [
            "ok": r.ok,
            "message": r.message,
            "rootfs_existed": r.rootfsExists,
            "rootfs": ISHEngine.rootfsInfo(),
            "next": r.ok
                ? "完全关闭 App（上滑杀掉）→ 重新打开 → 首次 shell 调用会自动重新解压 rootfs 并启动引擎"
                : "删除失败：请到 设置 → 通用 → iPhone 储存空间 或文件 App 里手动删除 App 的 Documents/alpine-rootfs"
        ]
    }

    // MARK: - 能力探测

    private func probe() -> [String: Any] {
        var rows: [[String: Any]] = []

        // 原生能力
        let nativeChecks: [(String, String)] = [
            ("sqlite3", "/usr/bin/sqlite3"),
            ("file", "/usr/bin/file"),
            ("strings", "/usr/bin/strings"),
            ("plutil", "/usr/bin/plutil"),
            ("bsdtar", "/usr/bin/tar")
        ]
        for (name, path) in nativeChecks {
            rows.append([
                "capability": name,
                "native": FileManager.default.isExecutableFile(atPath: path)
                    || FileManager.default.fileExists(atPath: path),
                "path": path
            ])
        }

        // Alpine 能力
        let enabled = UserDefaults.standard.bool(forKey: "alpineEngineEnabled")
        var alpineRows: [[String: Any]] = []
        if enabled {
            let r = ISHEngine.exec("for c in apk git python3 node sqlite3 file tar; do printf '%s=' $c; command -v $c >/dev/null && echo ok || echo missing; done", timeout: 25)
            for line in r.output.components(separatedBy: .newlines) where line.contains("=") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    alpineRows.append(["tool": parts[0], "status": parts[1], "exit": Int(r.exitCode)])
                }
            }
        }

        return [
            "message": enabled ? "能力探测完成（原生 + Alpine）" : "引擎未启用，仅探测原生能力",
            "native": rows,
            "alpine": alpineRows,
            "engine_enabled": enabled
        ]
    }
}
