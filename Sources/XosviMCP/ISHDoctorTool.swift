import Foundation

// MARK: - v8（PR-C4）：iSH 运行时自检
//
// 检查项全部来自 ISH_RUNTIME_NOTES.md 的实测结论：
//   1 rootfs 可见 / 2 引擎已启动 / 3 apk 死锁 / 4 apk 源协议
//   5 DNS / 6 TCP / 7 HTTP 冒烟 / 8 HTTPS 挂死（已知现象）
//   9 桥接方向（iSH 建占位 → iOS 覆盖 → 回读）/ 10 spawn 限制
//
// 设计原则：
//   - 默认只读；auto_fix=true 才删锁/改源。
//   - HTTPS 挂死是**预期现象**，不算失败（passed=true 但 detail 标明）。
//   - 每个 FAIL 都带可执行的 fix 文案，AI 不用猜。

final class ISHDoctorTool: MCPTool {
    let definition = ToolDefinition(
        name: "ish.doctor",
        summary: "Diagnose the iSH (Alpine) runtime: rootfs/boot state, apk lock & sources, DNS/TCP/HTTP (and the known HTTPS hang), bridge visibility, spawn blocks. Use for: iSH 装不了包 / 看不到文件 / 网络超时 / 命令异常的排障. Don't use for: running normal iSH commands (use shell.exec) or db work (use db). Example: 'iSH 里 apk 报 Operation not permitted' → run ish.doctor.",
        parameters: [
            "auto_fix": "Bool，默认 false：自动清 apk 死锁、apk 源 https→http",
            "deep": "Bool，默认 false：追加 HTTP 冒烟与 HTTPS 挂死探测（timeout 3s）",
        ],
        returns: [
            "verdict": "ISH_OK / ISH_DEGRADED / ISH_BROKEN",
            "checks": "每项 {id, passed, detail, fix}",
            "fixes_applied": "auto_fix 实际执行的动作",
        ],
        verified: false, category: "diagnose",
        annotations: .destructiveLocal,   // auto_fix=true 时会删/改文件
        cache: ToolCachePolicy.none,
        paramSpecs: [
            .b("auto_fix", "自动修复 apk 死锁与 https 源", required: false),
            .b("deep", "追加 HTTP/HTTPS 网络探测", required: false),
        ],
        variants: [
            ToolVariant("run", requires: [], accepts: ["auto_fix", "deep"], note: "默认只读自检"),
        ],
        related: [
            RelatedTool(tool: "shell.exec", when: "需要直接跑 iSH 命令时"),
            RelatedTool(tool: "diagnose", command: "toolchain", when: "检查签名与 spawn 能力时"),
        ]
    )

    /// rootfs 宿主侧路径（ISH_RUNTIME_NOTES §1 实测值；运行时以 ISH.dataPath 为准）
    private static var rootfsDataPath: String { ISH.dataPath }

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let autoFix = (params["auto_fix"] as? Bool) ?? false
        let deep = (params["deep"] as? Bool) ?? false

        var checks: [[String: Any]] = []
        var fixes: [[String: Any]] = []

        // 1) rootfs 可见
        let rootfsOK = FileManager.default.fileExists(atPath: Self.rootfsDataPath)
        checks.append(["id": "rootfs", "passed": rootfsOK,
                       "detail": rootfsOK ? Self.rootfsDataPath : "rootfs 路径不存在",
                       "fix": rootfsOK ? "" : "确认 iSH 已初始化；必要时在 设置 → 环境 重建 rootfs"])

        // 2) 引擎已启动
        let booted = ISH.isBooted
        checks.append(["id": "booted", "passed": booted,
                       "detail": booted ? "iSH kernel 已启动" : "未启动（首次执行会自动启动）",
                       "fix": booted ? "" : "先跑一次 shell.exec runtime:alpine 触发启动；仍失败则重建 rootfs"])

        guard rootfsOK else { return Self.verdict(checks, fixes, deep: deep) }

        func exec(_ cmd: String, _ timeout: Double = 8) -> String {
            let r = ISHManager.exec(cmd, timeout: timeout)
            return r.output
        }

        // 3) apk 死锁
        let lockOut = exec("ls -l /lib/apk/db/lock 2>/dev/null || echo NO_LOCK")
        let hasLock = !lockOut.contains("NO_LOCK")
        var lockFixed = false
        if hasLock, autoFix {
            _ = exec("rm -f /lib/apk/db/lock")
            lockFixed = true
            fixes.append(["action": "rm /lib/apk/db/lock", "applied": true])
        }
        checks.append(["id": "apk_lock", "passed": !hasLock || lockFixed,
                       "detail": hasLock ? lockOut.trimmingCharacters(in: .whitespacesAndNewlines) : "无死锁",
                       "fix": hasLock && !lockFixed ? "apk 报 Operation not permitted 时执行 rm -f /lib/apk/db/lock（或 auto_fix=true）" : ""])

        // 4) apk 源协议
        let httpsSrcs = exec("grep -n '^https' /etc/apk/repositories 2>/dev/null || true")
        let hasHTTPS = !httpsSrcs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var srcFixed = false
        if hasHTTPS, autoFix {
            _ = exec("sed -i 's|^https|http|' /etc/apk/repositories")
            srcFixed = true
            fixes.append(["action": "apk 源 https→http", "applied": true])
        }
        checks.append(["id": "apk_sources_http", "passed": !hasHTTPS || srcFixed,
                       "detail": hasHTTPS ? httpsSrcs : "全部 http",
                       "fix": hasHTTPS && !srcFixed ? "iSH 内 HTTPS 握手会挂死：把 apk 源改成 http 后 apk update" : ""])

        // 5) DNS
        let dns = exec("nslookup mirrors.aliyun.com 2>/dev/null | head -4")
        let dnsOK = dns.range(of: #"\d+\.\d+\.\d+\.\d+"#, options: .regularExpression) != nil
        checks.append(["id": "dns", "passed": dnsOK, "detail": dns,
                       "fix": dnsOK ? "" : "检查 设置 → 环境 → 镜像 的 DNS；或换一个 http 源"])

        // 6) TCP
        let tcp = exec("nc -z 1.1.1.1 443 && echo TCP_OK || echo TCP_FAIL", 6)
        checks.append(["id": "tcp", "passed": tcp.contains("TCP_OK"), "detail": tcp,
                       "fix": tcp.contains("TCP_OK") ? "" : "检查宿主网络/DNS 配置"])

        // 7)(8) deep：HTTP 冒烟 + HTTPS 挂死
        if deep {
            let http = exec("wget -q -O /dev/null http://mirrors.aliyun.com/alpine/v3.21/main/x86_64/APKINDEX.tar.gz && echo HTTP_OK || echo HTTP_FAIL", 10)
            checks.append(["id": "http_smoke", "passed": http.contains("HTTP_OK"), "detail": http,
                           "fix": http.contains("HTTP_OK") ? "" : "确认 apk 源可达（http）"])

            let https = exec("timeout 3 wget -q -O /dev/null https://mirrors.aliyun.com || echo HTTPS_HANG_OR_FAIL", 6)
            let hang = https.contains("HTTPS_HANG_OR_FAIL")
            checks.append(["id": "https_probe", "passed": true,   // 已知现象，不算失败
                           "detail": hang ? "HTTPS 挂死（预期内，iSH 环境限制）" : "HTTPS 意外可用",
                           "fix": "所有 iSH 内源一律走 http://，不要用 https://"])
        }

        // 9) 桥接双向探针
        checks.append(bridgeProbe(exec))

        // 10) spawn 限制（iSH 内 fork/exec 受限，实测 ENOSYS 85）
        let spawn = exec("sh -c 'true' 2>&1; echo SPAWN_EXIT=$?", 5)
        checks.append(["id": "spawn", "passed": spawn.contains("SPAWN_EXIT=0"),
                       "detail": spawn,
                       "fix": spawn.contains("SPAWN_EXIT=0") ? "" : "iSH 内不能 fork/exec 外部二进制：改用进程内实现（cpython shim / 原生工具）"])

        return Self.verdict(checks, fixes, deep: deep)
    }

    // MARK: 桥接双向探针 —— 「iSH 建占位 → iOS 覆盖 → iSH 回读」

    private func bridgeProbe(_ exec: (String, Double) -> String) -> [String: Any] {
        let rel = "tmp/_bridge_probe.txt"
        let guestPath = "/" + rel
        let hostPath = Self.rootfsDataPath + "/" + rel

        _ = exec("echo PLACEHOLDER > \(guestPath)", 5)
        let stamp = "PROBE_IOS_\(Int(Date().timeIntervalSince1970))"
        try? stamp.write(toFile: hostPath, atomically: true, encoding: .utf8)
        let back = exec("cat \(guestPath) 2>/dev/null", 5).trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = back.contains(stamp)

        return [
            "id": "bridge_direction",
            "passed": ok,
            "detail": ok ? "iSH 建占位 → iOS 覆盖 → 回读一致（\(stamp)）"
                         : "回读不一致：back=\(back.prefix(60))",
            "fix": ok ? "" : "iOS 侧无中生有写文件 iSH 看不到（inode 缓存）；必须先在 iSH 侧建占位再覆盖",
            "host_path": hostPath,
        ]
    }

    // MARK: 结论汇总

    private static func verdict(_ checks: [[String: Any]], _ fixes: [[String: Any]],
                                deep: Bool) -> [String: Any] {
        let failed = checks.filter { ($0["passed"] as? Bool) == false }
        let verdict: String
        if failed.isEmpty { verdict = "ISH_OK" }
        else if failed.count <= 2 { verdict = "ISH_DEGRADED" }
        else { verdict = "ISH_BROKEN" }

        return [
            "ok": failed.isEmpty,
            "verdict": verdict,
            "checks": checks,
            "fixes_applied": fixes,
            "deep": deep,
            "next_step": failed.isEmpty
                ? "环境健康；iSH 内继续用 http 源即可（apk/knowledge/编译均在 Alpine 侧）"
                : "按 checks 里 fix 字段逐条处理；auto_fix=true 可自动修复 apk 锁与源协议",
        ]
    }
}
