import Foundation
import Darwin

/// v7.16.6：rootd 桥——给 AI 一条**真正可用的 root 通道**。
///
/// 历史问题（2026-10-31 真机 23 小时会话）：setuid helper 早就 root:wheel 了，
/// 但 `shell.exec` 的白名单挡着绝对路径 / 裸名，AI 根本调不起来；LaunchDaemon 也一直没装成。
/// 与其在 App 里开一个"任意二进制执行"的口子（等于把 root 权限直接交给模型输出，
/// 还要重新签名重装），不如复用 deb 装的 rootd：
///   · `/var/mobile/Library/Rootd/.cmd`    写入一段脚本
///   · `/var/mobile/Library/Rootd/.out`    读结果
///   · `/var/mobile/Library/Rootd/.status` IDLE / RUNNING / DONE rc=N
/// 权限完全在系统侧（deb + launchd），App 侧不新增任何特权代码。
final class RootdTool: MCPTool {
    let definition = ToolDefinition(
        name: "root",
        summary: "Run a command as root through the rootd daemon (installed by the newterm-autoroot deb with a LaunchDaemon, survives reboot). Commands: status / exec / probe / enable / disable. Use for: chown/chmod, launchctl, editing /Library, anything shell.exec refuses. Don't use for: normal file reads (use shell.exec) or when rootd is not installed (status will say so). Example: root command:exec cmd:\"id -u\"",
        parameters: [
            "command": "status / exec / probe / enable / disable",
            "cmd": "shell script text (for exec) — runs as root via the daemon",
            "timeout": "seconds to wait for the result (default 30, max 300)"
        ],
        returns: [
            "stdout": "命令输出（exec）",
            "exit_code": "退出码（exec）",
            "status": "daemon 状态：IDLE / RUNNING / DONE rc=N",
            "dirs": "各候选目录的可用性（status / probe）",
            "diagnosis": "失败时的现场诊断"
        ],
        verified: false, category: "shell",
        prerequisites: ["需要先安装 newterm-autoroot deb（含 rootd LaunchDaemon）；status 返回 daemon_alive:false 时先让用户在终端跑 sh /var/mobile/.newterm-autoroot/selfcheck.sh"])

    /// 主目录 + roothide/rootfs 别名（同一份文件在不同进程视图里可能挂在不同路径）
    static let candidateDirs = [
        "/var/mobile/Library/Rootd",
        "/rootfs/var/mobile/Library/Rootd"
    ]

    private var fm: FileManager { FileManager.default }

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let sub = ((params["command"] as? String) ?? "status").lowercased()
        switch sub {
        case "status": return statusReport()
        case "probe":  return probe()
        case "enable": return setDisabled(false)
        case "disable": return setDisabled(true)
        case "exec":
            guard let cmd = params["cmd"] as? String, !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.invalidParams("cmd required. Usage: root command:exec cmd:\"id -u\"")
            }
            let timeout = min(max(Double((params["timeout"] as? Int) ?? 30), 3), 300)
            return try run(cmd, timeout: timeout)
        default:
            throw MCPError.invalidParams("unknown command \(sub); use status / exec / probe / enable / disable")
        }
    }

    // MARK: - 目录探测

    private struct DirState {
        let path: String
        let exists: Bool
        let writable: Bool
        let status: String
        let daemonAlive: Bool

        /// 目录可写且守护进程活着 —— 才能真正投递命令
        var usable: Bool { exists && writable && daemonAlive }
    }

    private func dirState(_ dir: String) -> DirState {
        let exists = fm.fileExists(atPath: dir) || FSStat.exists(dir)
        let writable = exists && fm.isWritableFile(atPath: dir)
        let status = (try? String(contentsOfFile: dir + "/.status", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var alive = false
        if let raw = try? String(contentsOfFile: dir + "/rootd.pid", encoding: .utf8),
           let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            alive = kill(pid, 0) == 0
        }
        return DirState(path: dir, exists: exists, writable: writable, status: status, daemonAlive: alive)
    }

    private func usableDirs() -> [DirState] {
        Self.candidateDirs.map(dirState).filter { $0.exists && $0.writable }
    }

    // MARK: - 子命令

    private func statusReport() -> [String: Any] {
        let states = Self.candidateDirs.map(dirState)
        let dirs: [[String: Any]] = states.map {
            ["path": $0.path, "exists": $0.exists, "writable": $0.writable,
             "status": $0.status, "daemon_alive": $0.daemonAlive]
        }
        let alive = states.contains { $0.daemonAlive }
        var out: [String: Any] = [
            "installed": states.contains { $0.exists },
            "daemon_alive": alive,
            "dirs": dirs,
            "jb_kind": JBEnvironment.kind.rawValue,
            "jbroot": JBEnvironment.jbrootPath ?? "",
            "rootfs": JBEnvironment.rootfsPrefix.isEmpty ? "无" : JBEnvironment.rootfsPrefix
        ]
        if !states.contains(where: { $0.exists }) {
            out["hint"] = "rootd 未安装：宿主需安装 newterm-autoroot deb（或手动跑 /var/mobile/.newterm-autoroot/selfcheck.sh 排查）"
        } else if !alive {
            out["hint"] = "目录在但守护进程没跑：让用户在终端执行 sh /var/mobile/.newterm-autoroot/selfcheck.sh，或 launchctl kickstart -k system/com.xosvi.rootd"
        } else if !states.contains(where: { $0.writable }) {
            out["hint"] = "目录存在但不可写（应为 root:wheel + 1777）：让用户 chmod 1777 /var/mobile/Library/Rootd"
        }
        return out
    }

    /// 探针：向每个可写目录写一条 `id -u`，看哪个真能被 rootd 执行
    private func probe() -> [String: Any] {
        var results: [[String: Any]] = []
        for dir in Self.candidateDirs {
            let st = dirState(dir)
            guard st.exists, st.writable else {
                results.append(["dir": dir, "skipped": "不可用"])
                continue
            }
            guard st.daemonAlive else {
                results.append(["dir": dir, "skipped": "daemon 未运行"])
                continue
            }
            var r: [String: Any] = ["dir": dir]
            do {
                let res = try run("id -u", timeout: 8, forceDir: dir)
                r["uid"] = res["stdout"] ?? ""
                r["ok"] = res["completed"] ?? false
            } catch {
                r["error"] = "\(error)"
            }
            results.append(r)
        }
        let ok = results.contains { ($0["uid"] as? String)?.contains("0") == true }
        return ["working": ok, "results": results,
                "hint": ok ? "root 通道可用" : "所有目录都拿不到 uid=0：多半是 App 沙箱视图与 root 视图不一致，见 results 里的 completed/error"]
    }

    private func setDisabled(_ disabled: Bool) -> [String: Any] {
        let dirs = usableDirs()
        guard !dirs.isEmpty else {
            return ["ok": false, "error": "找不到可写的 Rootd 目录（rootd 未安装？）"]
        }
        var done: [String] = []
        for d in dirs {
            let f = d.path + "/disabled"
            if disabled {
                if (try? "1".write(toFile: f, atomically: true, encoding: .utf8)) != nil { done.append(d.path) }
            } else {
                try? fm.removeItem(atPath: f)
                done.append(d.path)
            }
        }
        return ["ok": !done.isEmpty, "disabled": disabled, "dirs": done]
    }

    // MARK: - 执行

    private func run(_ script: String, timeout: Double, forceDir: String? = nil) throws -> [String: Any] {
        let candidates = forceDir.map { [dirState($0)] } ?? usableDirs()
        guard let dir = candidates.first(where: { $0.usable }) else {
            return ["completed": false, "error": "no_writable_dir",
                    "diagnosis": statusReport(),
                    "hint": "rootd 未安装或目录不可写；先让用户安装 newterm-autoroot deb"]
        }
        let base = dir.path
        let cmdPath = base + "/.cmd"
        let outPath = base + "/.out"
        let statusPath = base + "/.status"

        // 原子写入：先写临时文件再 rename（避免 daemon 读到半截脚本）
        let tmp = base + "/.cmd.tmp\(UInt32.random(in: 1000...9999))"
        do {
            try script.write(toFile: tmp, atomically: false, encoding: .utf8)
            if rename(tmp, cmdPath) != 0 {
                // 跨视图 rename 可能失败，退回原地写
                try? fm.removeItem(atPath: tmp)
                try script.write(toFile: cmdPath, atomically: true, encoding: .utf8)
            }
        } catch {
            return ["completed": false, "error": "write_failed", "dir": base,
                    "detail": "\(error)",
                    "hint": "App 写不进 \(base)；可试 /rootfs 别名或让用户 chmod 1777"]
        }

        let deadline = Date().addingTimeInterval(timeout)
        var status = ""
        while Date() < deadline {
            status = ((try? String(contentsOfFile: statusPath, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if status.hasPrefix("DONE") { break }
            if status == "DISABLED" {
                return ["completed": false, "error": "disabled", "dir": base,
                        "hint": "rootd 处于 disabled 状态：root command:enable 或 rm \(base)/disabled"]
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        if !status.hasPrefix("DONE") {
            let stillPending = fm.fileExists(atPath: cmdPath)
            return ["completed": false, "status": status, "dir": base,
                    "cmd_consumed": !stillPending,
                    "diagnosis": stillPending
                        ? "命令没被取走：App 写的 .cmd 与 rootd 看到的不是同一路径（沙箱/roothide 视图隔离），或 daemon 已死"
                        : "命令被取走了但没有 DONE 状态：daemon 可能在执行中超时（默认 \(Int(timeout))s）",
                    "hint": "试 root command:probe 看哪个目录真能用；或让用户在终端执行 selfcheck.sh"]
        }

        let out = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
        var code = -1
        if let r = status.range(of: "rc=") {
            code = Int(status[r.upperBound...].trimmingCharacters(in: .whitespaces)) ?? -1
        }
        return ["completed": true, "stdout": out, "exit_code": code,
                "status": status, "dir": base]
    }
}
