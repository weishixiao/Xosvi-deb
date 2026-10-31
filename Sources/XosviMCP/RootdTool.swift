import Foundation
import Darwin

/// v7.16.6：rootd 桥——给 AI 一条**真正可用的 root 通道**。
/// v7.16.8：真机上 App（mobile/沙箱视图）看不到 `/var/mobile/Library/Rootd`，
/// 导致 status 报 installed:false。改成：
///   · 多目录候选（含 App 一定能读写的 Documents 侧），逐个做**真实写入探针**而不是只查 isWritableFile
///   · daemon 存活按「任一目录的 rootd.pid」判断（pid 只在主目录）
///   · 探针失败时把 errno 原样报出来，别再用"视图不一致"这种猜测
///
/// 通道协议（rootd v1.3.2 同时服务三个目录）：
///   写 `<dir>/.cmd` → rootd 执行 → `<dir>/.out` / `<dir>/.status`（IDLE / RUNNING / DONE rc=N）
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
            "dirs": "各候选目录的可用性 + 写入探针错误码（status / probe）",
            "diagnosis": "失败时的现场诊断"
        ],
        verified: false, category: "shell",
        prerequisites: ["需要先安装 newterm-autoroot deb（≥1.3.2，含 rootd LaunchDaemon）；status 返回 daemon_alive:false 时让用户在终端跑 sh /var/mobile/.newterm-autoroot/selfcheck.sh"])

    /// 候选目录，**App 侧可写的排前面**。
    /// v7.16.8：Library 在真机上对 App 不可见（写入探针会报 ENOENT/EACCES），Documents 侧才是通的。
    static let candidateDirs = [
        "/var/mobile/Documents/Rootd",
        "/var/mobile/Library/Rootd",
        "/var/mobile/Documents/Workspace",
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
        let writeError: String?      // nil = 真写进去了
        let status: String

        var writable: Bool { writeError == nil }
    }

    /// 真实写入探针：能不能在这个目录里建文件。比 isWritableFile 可信——
    /// 后者在容器重定向/roothide 下会照着容器注册表撒谎。
    private func writeProbe(_ dir: String) -> String? {
        let name = ".probe-\(getpid())-\(Int(Date().timeIntervalSince1970))"
        let path = dir + "/" + name
        errno = 0
        let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        if fd >= 0 {
            close(fd)
            unlink(path)
            return nil
        }
        let code = errno
        return "errno=\(code) \(String(cString: strerror(code)))"
    }

    private func dirState(_ dir: String) -> DirState {
        let exists = fm.fileExists(atPath: dir) || FSStat.exists(dir)
        let werr = exists ? writeProbe(dir) : "目录不存在"
        let status = (try? String(contentsOfFile: dir + "/.status", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DirState(path: dir, exists: exists, writeError: werr, status: status)
    }

    /// daemon 存活：pid 文件只在主目录，任一候选目录里有且进程活着就算活着
    private func daemonPID() -> pid_t? {
        for d in Self.candidateDirs {
            guard let raw = try? String(contentsOfFile: d + "/rootd.pid", encoding: .utf8),
                  let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  pid > 0, kill(pid, 0) == 0 else { continue }
            return pid
        }
        return nil
    }

    private func usableDirs() -> [DirState] {
        Self.candidateDirs.map(dirState).filter { $0.exists && $0.writable }
    }

    // MARK: - 子命令

    private func statusReport() -> [String: Any] {
        let states = Self.candidateDirs.map(dirState)
        let pid = daemonPID()
        let dirs: [[String: Any]] = states.map {
            var m: [String: Any] = ["path": $0.path, "exists": $0.exists,
                                    "writable": $0.writable, "status": $0.status]
            if let e = $0.writeError { m["write_error"] = e }
            return m
        }
        var out: [String: Any] = [
            "installed": states.contains { $0.exists },
            "daemon_alive": pid != nil,
            "daemon_pid": pid.map { Int($0) } ?? 0,
            "dirs": dirs,
            "jb_kind": JBEnvironment.kind.rawValue,
            "jbroot": JBEnvironment.jbrootPath ?? "",
            "rootfs": JBEnvironment.rootfsPrefix.isEmpty ? "无" : JBEnvironment.rootfsPrefix
        ]
        if !states.contains(where: { $0.exists }) {
            out["hint"] = "rootd 未安装，或 App 完全看不到候选目录（看 dirs[].write_error）：安装 newterm-autoroot ≥1.3.2"
        } else if pid == nil {
            out["hint"] = "目录在但守护进程没跑：让用户执行 sh /var/mobile/.newterm-autoroot/selfcheck.sh 或 launchctl kickstart -k system/com.xosvi.rootd"
        } else if !states.contains(where: { $0.writable }) {
            out["hint"] = "daemon 活着但所有目录都写不进去：让用户 chmod 1777 对应目录（deb ≥1.3.2 会自动建 /var/mobile/Documents/Rootd）"
        }
        return out
    }

    private func probe() -> [String: Any] {
        var results: [[String: Any]] = []
        var working = false
        for dir in Self.candidateDirs {
            var r: [String: Any] = ["dir": dir]
            let st = dirState(dir)
            r["exists"] = st.exists
            if let e = st.writeError { r["write_error"] = e }
            guard st.writable else { results.append(r); continue }
            do {
                let res = try run("id -u", timeout: 8, forceDir: dir)
                r["uid"] = res["stdout"] ?? ""
                r["completed"] = res["completed"] ?? false
                if let s = res["stdout"] as? String, s.contains("0") { working = true }
            } catch {
                r["error"] = "\(error)"
            }
            results.append(r)
        }
        return ["working": working, "results": results,
                "hint": working ? "root 通道可用" : "没有目录能拿到 uid=0：看 results 里每个目录的 write_error / completed"]
    }

    private func setDisabled(_ disabled: Bool) -> [String: Any] {
        let dirs = usableDirs()
        guard !dirs.isEmpty else {
            return ["ok": false, "error": "找不到可写的 Rootd 目录（rootd 未安装？）", "diagnosis": statusReport()]
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
        let target: DirState?
        if let fd = forceDir {
            let st = dirState(fd)
            target = (st.exists && st.writable) ? st : nil
        } else {
            target = usableDirs().first
        }
        guard let dir = target, daemonPID() != nil else {
            return ["completed": false, "error": "no_writable_dir",
                    "diagnosis": statusReport(),
                    "hint": "rootd 未安装 / 未运行 / 候选目录都写不进去；先看 diagnosis.dirs[].write_error"]
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
                try? fm.removeItem(atPath: tmp)
                try script.write(toFile: cmdPath, atomically: true, encoding: .utf8)
            }
        } catch {
            return ["completed": false, "error": "write_failed", "dir": base,
                    "detail": "\(error)",
                    "diagnosis": statusReport()]
        }

        let deadline = Date().addingTimeInterval(timeout)
        var status = ""
        while Date() < deadline {
            status = ((try? String(contentsOfFile: statusPath, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if status.hasPrefix("DONE") { break }
            if status == "DISABLED" {
                return ["completed": false, "error": "disabled", "dir": base,
                        "hint": "rootd 处于 disabled 状态：root command:enable 或删掉 disabled 文件"]
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        if !status.hasPrefix("DONE") {
            let stillPending = fm.fileExists(atPath: cmdPath)
            return ["completed": false, "status": status, "dir": base,
                    "cmd_consumed": !stillPending,
                    "diagnosis": stillPending
                        ? "命令没被取走：daemon 没在看这个目录（deb 版本太旧？1.3.2 起才会轮询 Documents/Rootd）"
                        : "命令被取走了但没等到 DONE：可能在执行中超时（默认 \(Int(timeout))s）",
                    "hint": "root command:probe 看哪个目录通"]
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
