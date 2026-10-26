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
            + "Commands: install / devices / status / pair / scaffold / push / run / commands / skill / store. "
            + "Typical tweak loop: scaffold (generates rootless Theos project in workspace) → write Tweak.xm → push (to device) → run subcommand:tweak_cycle (gmake + dpkg + heartbeat + rollback). "
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
            "name": "For command:scaffold — project name (e.g. MyTweak)",
            "bundle_id": "For command:scaffold — target app bundle id",
            "executable": "For command:scaffold — target process name for Filter.plist (defaults to bundle id or SpringBoard)",
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

        case "scaffold":
            // 生成环节：在沙盒 workspace 生成 rootless Theos 工程（AI 随后改写 Tweak.xm）
            let name = (params["name"] as? String) ?? "MyTweak"
            let bid = (params["bundle_id"] as? String) ?? ""
            let exe = (params["executable"] as? String) ?? ""
            let made = try JBPlotSkill.scaffold(name: name, bundleId: bid, executable: exe)
            return ["ok": true, "project": name, "dir": made.dir.path,
                    "files": made.files,
                    "next": [
                        "1) 改写 Tweak.xm（钩子）",
                        "2) jb command:push project:\(name)  → 推到设备 /var/jb/tweak/\(name)",
                        "3) jb command:run subcommand:tweak_cycle project:/var/jb/tweak/\(name) reload:<进程> processes:<进程> rollbackOnCrash:true"
                    ]]

        case "push":
            // 把沙盒里的工程送到设备，返回设备端路径（tweak_cycle 的 project 参数用这个）
            guard let proj = params["project"] as? String, !proj.isEmpty else {
                throw MCPError.invalidParams("project required（workspace://projects 下的工程名）")
            }
            return try push(proj, device: device, timeout: timeout)

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

    // MARK: - 推工程到设备（生成 → 构建 的接线）

    /// 把 workspace/projects/<name> 推到设备。
    /// v7.14.3：本地原生通道——绕开上游 file_transfer：
    ///   file_transfer 本质上就是 host 读文件 →（塞进一帧）→ 设备 file_write；
    ///   二进制文件走 base64 会膨胀 33%，遇 protocol.MaxFrameBytes 直接 ErrFrameTooLarge。
    ///   这里直接在本地做 base64 + 手动分块（每块远小于 MaxFrameBytes），分块拼到 staging，
    ///   最后在设备侧 `cat a b c > 目标` 合回单文件，一次 shell_exec 完成，不需要宿主侧管道。
    private func push(_ name: String, device: String?, timeout: TimeInterval) throws -> [String: Any] {
        let dir = Workspace.root.appendingPathComponent("projects/\(name)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw MCPError.invalidParams("工程不存在: \(dir.path)。先用 jb command:scaffold name:\(name)")
        }
        let remoteRoot = (params_dev)("JB_REMOTE_TWEAK_ROOT") ?? "/var/jb/tweak"
        let remoteDir = "\(remoteRoot)/\(name)"

        // ① 设备侧建目录 + 清 staging
        let prep = JBPlot.run("shell_exec", device: device, params: [
            "command": "mkdir -p \(shq(remoteDir)) /tmp/jbp && rm -f /tmp/jbp/*"
        ], timeout: 60)
        guard prep.isOK else {
            throw MCPError.failed("设备侧准备目录失败: \(prep.brief)。先 jb command:devices 确认配对与越狱路径")
        }

        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw MCPError.failed("无法遍历工程目录")
        }
        var sent: [String] = []
        var failed: [String] = []
        var bytesTotal = 0

        for case let file as URL in walker {
            let isDir = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            let rel = String(file.path.dropFirst(dir.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rel.isEmpty else { continue }
            // 跳过构建产物，别把 .theos 传上去
            if rel.hasPrefix(".theos") || rel.hasPrefix("packages/") || rel.hasSuffix(".deb") { continue }
            guard let data = try? Data(contentsOf: file) else { failed.append("\(rel): 读不到"); continue }

            let dest = "\(remoteDir)/\(rel)"
            let tmpBase = "/tmp/jbp/\(rel.replacingOccurrences(of: "/", with: "_"))"

            // ② 关键：rel 里可能带子目录，先建父目录
            if rel.contains("/") {
                let parent = (dest as NSString).deletingLastPathComponent
                _ = JBPlot.run("shell_exec", device: device,
                               params: ["command": "mkdir -p \(shq(parent))"], timeout: 30)
            }

            let chunks = chunkBase64(data)
            // 块多时总时长会超出单次 timeout：按 30s/块 + 基础 60s 放大，上限 20 分钟
            let perFileTimeout = min(1200, max(timeout, 60 + Double(chunks.count) * 30))
            var chunkPaths: [String] = []
            var chunkFailed: String?
            for (i, b64) in chunks.enumerated() {
                let path = tmpBase + ".b\(i)"
                // data 走 rawParams：base64 里必有 '='，用 `--param k v` 双参数形式原样传
                let r = JBPlot.run("file_write", device: device,
                                   params: ["path": path, "encoding": "base64"],
                                   rawParams: ["data": b64, "mode": "420"],
                                   timeout: perFileTimeout)
                if r.isOK { chunkPaths.append(path) } else {
                    chunkFailed = "块\(i): \(r.brief)"; break
                }
            }
            if let e = chunkFailed { failed.append("\(rel): \(e)"); continue }

            // ③ 设备侧拼接成目标文件
            let join = JBPlot.run("shell_exec", device: device, params: [
                "command": "cat \(chunkPaths.map { shq($0) }.joined(separator: " ")) > \(shq(dest)) && rm -f \(shq(tmpBase)).b*"
            ], timeout: 60)
            if join.isOK { sent.append(rel); bytesTotal += data.count }
            else { failed.append("\(rel): 拼接失败 \(join.brief)") }
        }

        let ok = failed.isEmpty && !sent.isEmpty
        var out: [String: Any] = ["ok": ok, "project": name, "devicePath": remoteDir,
                                  "files": sent, "count": sent.count, "bytes": bytesTotal,
                                  "transport": "native file_write (chunked base64)"]
        if !failed.isEmpty { out["failed"] = failed }
        if !ok {
            out["hint"] = "推失败先确认：设备已配对（jb command:devices）、越狱路径可写（rootless 为 /var/jb）；"
                + "若 file_write 报权限，确认 jb-p1lot daemon 以 root 运行。"
        }
        return out
    }

    /// 本地分块：单个 base64 块控制在 512KB 以内（解码后 384KB），
    /// 远低于上游协议帧上限，避免做错任何一个大文件的传输。
    private func chunkBase64(_ data: Data, chunkBytes: Int = 384 * 1024) -> [String] {
        if data.isEmpty { return [""] }
        var out: [String] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkBytes, data.count)
            out.append(data.subdata(in: offset..<end).base64EncodedString())
            offset = end
        }
        return out
    }

    /// 单引号转义（与上游 stageTweakPackage 的 shellQuote 语义一致）
    private func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func params_dev(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: "jb." + key)
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
