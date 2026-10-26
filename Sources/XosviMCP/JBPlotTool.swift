import Foundation

// MARK: - v7.14.0：jb 工具（rootless 越狱设备直控，基于 jb-p1lot）
//
// 一个工具承载 jb-p1lot 的全部子命令（32 个设备命令 + 本地管理命令），
// 与项目里其它"大工具 + 子命令"风格一致（app / inject / github …）。
//
//   jb command:install            安装/更新宿主二进制
//   jb command:devices            发现已配对设备
//   jb command:status             桥接/越狱状态
//   jb command:pair               配对（ssh_host + ssh_port + ssh_user + ssh_password）
//   jb command:run, subcommand:…  转发上游任意子命令（shell_exec/tweak_cycle/ui_snapshot …）
//   jb command:commands           列出全部上游子命令与参数
//   jb command:skill              读取 jb-p1lot 技能路由指引（按需加载，省 context）

final class JBPlotTool: MCPTool {
    let definition = ToolDefinition(
        name: "jb",
        summary: "Control a PAIRED rootless-jailbroken device (Dopamine/TrollStore-era) through the jb-p1lot bridge: root shell, tweak build→install→verify→rollback cycles, UI snapshot/HID input, screenshots, app/package control, LLDB/Frida, logs/crashes, PCAP. "
            + "Use for: the user's OTHER jailbroken device, or root-level ops on this device that native Xosvi tools cannot do (real Theos gmake build + dpkg install + process heartbeat check). "
            + "Don't use for: this device's own file/app/injection work (use shell.exec / app / inject / control). "
            + "Always run command:devices first, and pass device:<udid> when more than one device is paired. "
            + "Commands: install / devices / status / pair / run / commands / skill / store. "
            + "For upstream subcommands use command:run + subcommand:<name> (e.g. command:run subcommand:tweak_cycle project:/var/jb/tweak/MyTweak), or pass subcommand directly as command:<name>. "
            + "Example: user says 'build my tweak on the jailbroken device' → jb command:devices → jb command:run subcommand:tweak_cycle project:<path> device:<udid>.",
        parameters: [
            "command": "Local action: install / update / devices / status / pair / run / commands / skill — OR any upstream subcommand name directly (shell_exec, tweak_build, tweak_deploy, tweak_cycle, ui_snapshot, ui_action, screen_capture, file_read, log_query, ...)",
            "subcommand": "Upstream subcommand when command:run",
            "device": "Paired UDID / bridge address (required when several devices are paired)",
            "params": "JSON object of upstream params, e.g. {\"command\":\"ps -ax | head\",\"timeoutMs\":20000}. Alternatively pass them as top-level keys.",
            "project": "Tweak project path for tweak_build / tweak_cycle",
            "ssh_host": "For command:pair — device SSH host (WiFi IP or USB)",
            "ssh_port": "For command:pair — SSH port (default 22)",
            "ssh_user": "For command:pair — SSH user (default root)",
            "ssh_password": "For command:pair — SSH password (provisioning only)",
            "version": "For command:install — release tag (default latest)",
            "timeout": "Seconds to wait (default 120, use 1800 for tweak_cycle / long builds)"
        ],
        returns: [
            "ok": "true when the bridge call succeeded",
            "subcommand": "upstream command that ran",
            "data": "upstream result payload (union: it can be a list, object, string or number)",
            "artifactPath": "path on the bridge host for large outputs (screenshots, packages, pcap)",
            "sessionId": "id of a long-running session (screen_stream / debug_session / frida_session)",
            "error": "upstream or local error message"
        ],
        verified: false, category: "system", requiresJailbreak: true,
        prerequisites: [
            "jb command:install — host binary must be installed once (Settings → jb-p1lot, or this command)",
            "jb command:pair — the target device's jb-p1lot daemon must be paired with this app"
        ])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let raw = params["command"] as? String, !raw.isEmpty else {
            throw MCPError.invalidParams("command required (install / devices / status / pair / run / commands / skill, or an upstream subcommand name). See jb command:commands")
        }
        let command = raw.trimmingCharacters(in: .whitespaces)
        AuditLog.shared.log("jb", detail: command)
        let timeout = (params["timeout"] as? NSNumber)?.doubleValue
            ?? (params["timeout"] as? Double)
            ?? JBPlot.defaultTimeout
        let device = params["device"] as? String

        switch command {
        case "install", "update":
            let version = params["version"] as? String
            let r = JBPlot.downloadBinary(version: version)
            return ["ok": r.ok, "message": r.message, "binary": JBPlot.binaryState,
                    "path": JBPlot.binaryURL.path]

        case "commands":
            return ["ok": true, "count": JBPlot.catalog.count,
                    "commands": JBPlot.catalog.map { c -> [String: Any] in
                        ["name": c.name, "summary": c.summary, "params": c.params, "destructive": c.destructive]
                    }]

        case "store":
            // Relaxin：把宿主程序拷到越狱可写区，供 ssh / NewTerm / 电脑侧直接调用
            let r = JBPlot.copyToJailbreakPath()
            return ["ok": r.ok, "message": r.message, "path": JBPlot.jailbreakPath]

        case "skill":
            return ["ok": true, "skill": JBPlotSkill.content()]

        case "devices", "device_list":
            return try forward("device_list", device: device, params: [:], project: nil, timeout: timeout)

        case "status", "device_status":
            return try forward("device_status", device: device, params: [:], project: nil, timeout: timeout)

        case "pair":
            return try pair(params: params)

        case "run":
            guard let sub = params["subcommand"] as? String, !sub.isEmpty else {
                throw MCPError.invalidParams("subcommand required for command:run")
            }
            return try forward(sub, device: device, params: upstreamParams(params), project: params["project"] as? String, timeout: timeout)

        default:
            // 直接当上游子命令用：jb command:shell_exec command_text:"..." ——被 command 占用，
            // 所以上游的 `command` 参数改用 params JSON 或 param_command 传。
            if JBPlot.spec(command) != nil {
                return try forward(command, device: device, params: upstreamParams(params), project: params["project"] as? String, timeout: timeout)
            }
            throw MCPError.invalidParams("未知子命令 \(command)。本地命令: install/update/devices/status/pair/run/commands/skill；上游命令见 jb command:commands")
        }
    }

    // MARK: - 参数整理

    /// 上游参数来源：params（JSON 对象 / JSON 字符串）优先，其次顶层键（排除本地保留键）
    private func upstreamParams(_ params: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let obj = params["params"] as? [String: Any] {
            out.merge(obj) { _, new in new }
        } else if let s = params["params"] as? String, let d = s.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            out.merge(obj) { _, new in new }
        }
        let reserved: Set<String> = ["command", "subcommand", "device", "params", "project",
                                     "ssh_host", "ssh_port", "ssh_user", "ssh_password", "version", "timeout"]
        for (k, v) in params where !reserved.contains(k) {
            if let s = JBPlot.paramString(v) { out[k] = s }
        }
        return out
    }

    // MARK: - 转发 + 结果整形

    private func forward(_ sub: String, device: String?, params: [String: Any],
                         project: String?, timeout: TimeInterval) throws -> [String: Any] {
        guard JBPlot.binaryState != "missing" else {
            throw MCPError.failed("jb-p1lot 宿主二进制未安装。先调用 jb command:install（或 设置 → jb-p1lot → 安装）。")
        }
        let r = JBPlot.run(sub, device: device, params: params, project: project, timeout: timeout)
        if !r.isOK && JBPlot.looksLikeSpawnBlocked(r.stderr, code: r.code) {
            throw MCPError.failed("jb \(sub)：\(JBPlot.spawnBlockedHint)")
        }
        if let j = r.json {
            var out = j
            if let err = j["error"] as? String {
                // 上游以 {"error": ...} 返回失败，包一层方便 AI 判断
                return ["ok": false, "subcommand": sub, "error": err, "stderr": String(r.stderr.prefix(2000))]
            }
            out["ok"] = r.isOK
            out["subcommand"] = sub
            if !r.stderr.isEmpty { out["stderr"] = String(r.stderr.prefix(2000)) }
            return out
        }
        let msg = r.brief
        if !r.isOK {
            throw MCPError.failed("\(sub) 失败: \(msg)。stderr: \(r.stderr.prefix(1500))")
        }
        return ["ok": true, "subcommand": sub, "output": String(r.stdout.prefix(8000))]
    }

    // MARK: - 配对

    private func pair(params: [String: Any]) throws -> [String: Any] {
        guard JBPlot.binaryState != "missing" else {
            throw MCPError.failed("先安装宿主二进制：jb command:install")
        }
        guard let host = params["ssh_host"] as? String, !host.isEmpty else {
            throw MCPError.invalidParams("ssh_host required（设备局域网 IP 或 USB SSH 地址）")
        }
        var args: [String] = ["setup", "--all",
                              "--ssh-host", host,
                              "--ssh-port", JBPlot.paramString(params["ssh_port"] ?? 22) ?? "22",
                              "--ssh-user", (params["ssh_user"] as? String) ?? "root"]
        if let pw = params["ssh_password"] as? String, !pw.isEmpty {
            args += ["--ssh-password", pw]
        }
        if let dev = params["device"] as? String, !dev.isEmpty {
            args += ["--device", dev]
        }
        let r = JBPlot.exec(args, timeout: 600)
        if let j = r.json {
            var out = j
            out["ok"] = r.isOK
            // 配对成功后刷新发现缓存
            _ = JBPlot.run("device_list", timeout: 30)
            return out
        }
        if !r.isOK {
            throw MCPError.failed("配对失败: \(r.brief)。stderr: \(r.stderr.prefix(1500))")
        }
        _ = JBPlot.run("device_list", timeout: 30)
        return ["ok": true, "output": String(r.stdout.prefix(8000))]
    }
}
