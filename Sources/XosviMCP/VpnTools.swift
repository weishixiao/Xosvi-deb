// VpnTool：MITM 抓包 VPN/代理控制工具（v3.3.0）
// 子命令：status / start / stop / cert / local_start / local_stop / logs

import Foundation
import CFNetwork
import MitmCore

final class VpnTool: MCPTool {
    let definition = ToolDefinition(
        name: "vpn.capture",
        summary: "MITM packet capture (system-level HTTPS plaintext of ANY app, 含protobuf/自定义socket; 覆盖面>network.capture). Commands: status / start / stop / cert / cert_status / serve_profile / verify / local_start / local_stop / logs. start=VPN模式(失败自动降级本地代理并返回 mode:fallen_back); local_start=本地代理(手动设WiFi代理127.0.0.1:18180); 首用先 cert → serve_profile 安装 → 开启 Full Trust → verify 确认 TRUSTED. 局限: QUIC/HTTP3不解密; TLS-pinned失败.",
        parameters: [
            "command": "status / start / stop / cert / cert_status / serve_profile / verify / local_start / local_stop / logs",
            "lines": "For logs: 尾读行数（默认 80）"
        ],
        verified: false, category: "network", prerequisites: [
            "VPN 无需注入信任，直接 command:start 即可抓包（trust inject 已移除，避免误触黑屏）",
            "run cert first: generates Workspace/certs/XosviCA.mobileconfig — user must install it in Settings and enable Full Trust (Settings→General→About→Certificate Trust Settings)",
            "start = VPN mode (NEVPNManager + VpnTunnel appex). If appex not installed/loadable, fall back to local_start + WiFi manual proxy",
            "after start, user uses the target app normally; logs appear in Workspace/network_capture/mitm/",
            "0 logs expected if app uses QUIC only (rare on cellular/proxy setups)"
        ], annotations: .systemControl, cache: ToolCachePolicy.none)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let command = (params["command"] as? String) ?? "status"
        let vm = VpnManager.shared

        switch command {
        case "status":
            var status = "unknown"
            let raw = vm.vpnStatus.rawValue
            // NEVPNStatus: invalid=0, disconnecting=1, connecting=2, connected=3, reasserting=4, disconnecting=5
            switch raw {
            case 0: status = "invalid(not configured)"
            case 1: status = "disconnecting"
            case 2: status = "connecting"
            case 3: status = "connected"
            case 4: status = "reasserting"
            case 5: status = "disconnected"
            default: status = "raw\(raw)"
            }
            let mitmLogs = (try? FileManager.default.contentsOfDirectory(atPath: vm.mitmLogDir)) ?? []
            let currentMode: String
            if raw == 3 { currentMode = "vpn" }
            else if vm.localProxyRunning { currentMode = "proxy" }
            else { currentMode = "off" }
            // v8（PR-C3）：system proxy 与 VPN 互斥检测
            let systemProxy = Self.systemProxyConfigured()
            var warnings: [String] = []
            if currentMode == "vpn" && systemProxy {
                warnings.append("proxy_conflict: 系统 WiFi 代理与 VPN 同时开启，可能互相干扰；建议只保留一种")
            }
            return [
                "mode": currentMode,
                "vpn_status": status,
                "vpn_configured": vm.vpnConfigured,
                "local_proxy_running": vm.localProxyRunning,
                "proxy_port": Int(vm.proxyPort),
                "system_proxy_configured": systemProxy,
                "ca_installed_candidate": vm.caExists,
                "cert_state": vm.caExists ? "CA_READY" : "NO_CA",
                "mitm_log_files": mitmLogs.count,
                "mitm_log_dir": vm.mitmLogDir,
                "warnings": warnings,
                "hint": "first time: cert → serve_profile → 安装并开启 Full Trust → verify 确认 TRUSTED → start"
            ]

        case "start":
            // v3.6.19g: 修复——原实现立即 return，note 永远是初始 "VPN connecting"；
            // startVpn 的 completion 是异步回调(注入+等批准+confirmConnected 共约3s+)，
            // 启动失败的真实结果(系统未批准/隧道没起来)在回调里晚于 return 才设置，被吞掉，
            // AI/用户通过 MCP 永远看不到真实成败。改用 semaphore 阻塞等待异步结果(最多12s)
            // 后返回真实状态。
            var note = "VPN connecting (wait for system prompt)"
            var started = true
            let sem = DispatchSemaphore(value: 0)
            vm.startVpn { err in
                if let e = err {
                    note = "start failed: \(e)"
                    started = false
                } else {
                    note = "VPN started & connected"
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 12)
            if !started {
                // v8（PR-C3）：VPN 起不来 → 自动降级本地代理，并明示 mode/degraded_reason
                let ok = vm.startLocalProxy()
                let reason = Self.classifyDegraded(note)
                return [
                    "command": "start",
                    "started": ok,
                    "mode": ok ? "fallen_back" : "off",
                    "degraded_reason": reason,
                    "note": "VPN 启动失败已降级为本地代理：\(note)",
                    "next_step": ok
                        ? "在 WiFi 设置里把 HTTP 代理设为 127.0.0.1:\(Int(vm.proxyPort))，或修复 VPN（见 degraded_reason）后重试 start"
                        : "本地代理也未启动：先检查端口占用（18180），或跑 vpn.capture command:verify 看证书状态"
                ]
            }
            return ["command": "start", "started": true, "mode": "vpn", "note": note,
                    "cert_reminder": "install+trust CA first if not done (vpn.capture command:cert)"]

        case "stop":
            vm.stopVpn()
            vm.stopLocalProxy()
            return ["command": "stop", "stopped": true]

        case "cert":
            guard let path = vm.generateMobileConfig() else {
                return ["command": "cert", "error": "mobileconfig generation failed", "hint": "check Workspace/certs/ca.pem exists"]
            }
            return ["command": "cert", "mobileconfig": path,
                    "steps": ["open the file with Files app to install profile",
                              "then Settings → General → About → Certificate Trust Settings → enable Full Trust for Xosvi MITM CA",
                              "then run vpn.capture command:start (or local_start)"]]

        case "cert_status":
            // 4 态：NO_CA / CA_READY（有文件但代理没跑）/ PROXY_DOWN / TRUSTED 由 verify 判定
            if !vm.caExists {
                return ["command": "cert_status", "cert_state": "NO_CA",
                        "next_step": "先 vpn.capture command:cert 生成 CA，再 serve_profile 安装"]
            }
            if !MitmProxy.shared.isRunning {
                return ["command": "cert_status", "cert_state": "PROXY_DOWN",
                        "next_step": "先 vpn.capture command:start（或 local_start），再 verify"]
            }
            return ["command": "cert_status", "cert_state": "CA_READY",
                    "next_step": "运行 vpn.capture command:verify 做功能探测确认 TRUSTED"]

        case "serve_profile":
            guard let path = vm.generateMobileConfig() else {
                return ["command": "serve_profile", "error": "mobileconfig generation failed",
                        "hint": "check Workspace/certs/ca.pem exists（先 command:cert）"]
            }
            let dir = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let ok = LocalHttpServer.shared.start(rootDir: dir)
            let url = ok ? LocalHttpServer.shared.serverURL + "/" + name : nil
            return ["command": "serve_profile", "url": url ?? "",
                    "steps": ["Safari 打开该 URL → 允许下载描述文件",
                              "设置 → 已下载描述文件 → 安装",
                              "设置 → 通用 → 关于本机 → 证书信任设置 → 打开 Xosvi MITM CA 的完全信任",
                              "回到这里执行 vpn.capture command:verify"],
                    "note": url == nil ? "本地 HTTP 服务未启动，可直接用 Files 打开 mobileconfig 路径：\(path)" : "用 Safari 打开上面的 URL 触发安装"]

        case "verify":
            let (state, detail) = Self.probeCertTrust()
            return ["command": "verify", "cert_state": state, "detail": detail,
                    "next_step": state == "TRUSTED"
                        ? "证书信任生效，可以正常抓包"
                        : (state == "PROXY_DOWN"
                            ? "先启动代理：vpn.capture command:start"
                            : "安装并信任 CA：command:cert → command:serve_profile → 设置里开启完全信任")]

        case "local_start":
            let ok = vm.startLocalProxy()
            return ["command": "local_start", "started": ok, "port": Int(vm.proxyPort),
                    "user_action": "set WiFi HTTP proxy to 127.0.0.1:18180 (Settings→WiFi→your network→Configure Proxy→Manual)",
                    "note": "apps honoring system proxy will be captured"]

        case "local_stop":
            vm.stopLocalProxy()
            return ["command": "local_stop", "stopped": true]

        case "logs":
            let dir = vm.mitmLogDir
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted().reversed()
            let recent = Array(files.prefix(20))
            let tailN = (params["lines"] as? Int) ?? 80
            var tail = ""
            if let newest = recent.first {
                let p = dir + "/" + newest
                if let content = try? String(contentsOfFile: p, encoding: .utf8) {
                    tail = content.components(separatedBy: "\n").suffix(tailN).joined(separator: "\n")
                }
            }
            let classified = Self.classifyAppexLog(tail)
            var out: [String: Any] = ["command": "logs", "log_dir": dir, "recent_files": recent,
                                      "total": (try? FileManager.default.contentsOfDirectory(atPath: dir))?.count ?? 0,
                                      "appex_tail": tail]
            if let c = classified { out["classified_failure"] = c }
            return out

        default:
            return ["error": "unknown command '\(command)'. Use status / start / stop / cert / cert_status / serve_profile / verify / local_start / local_stop / logs"]
        }
    }

    // MARK: - v8（PR-C3）：证书功能探测 / 降级分类 / 系统代理检测

    /// 经本地代理 GET https://example.com：
    /// - 有 HTTP 响应 → TRUSTED（拦截链路可用）
    /// - TLS 失败      → NOT_TRUSTED（描述文件未装/未信任）
    /// - 代理没跑       → PROXY_DOWN
    static func probeCertTrust() -> (state: String, detail: String) {
        guard MitmProxy.shared.isRunning else {
            return ("PROXY_DOWN", "本地代理未运行：先 vpn.capture command:start（或 local_start）")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        let p = Int(MitmProxy.shared.port)
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: p,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": p,
        ]
        let sem = DispatchSemaphore(value: 0)
        var state = "UNKNOWN"
        var detail = "探测超时（10s）"
        let task = URLSession(configuration: cfg).dataTask(with: URL(string: "https://example.com")!) { _, resp, err in
            defer { sem.signal() }
            if let http = resp as? HTTPURLResponse {
                state = "TRUSTED"
                detail = "代理拦截生效，HTTP \(http.statusCode)"
            } else if let e = err {
                let ns = e as NSError
                state = "NOT_TRUSTED"
                detail = "TLS 失败（\(ns.code)）：描述文件未安装或未在「证书信任设置」里信任"
            }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 10)
        return (state, detail)
    }

    /// v8（PR-C3）：Appex 日志常见失败分类
    static func classifyAppexLog(_ text: String) -> [String: Any]? {
        let t = text.lowercased()
        if t.contains("utun") && (t.contains("not ready") || t.contains("failed")) {
            return ["code": "utun_not_ready", "hint": "utun fd 未就绪：确认 VPN 描述文件已安装且 appex 有 NetworkExtension 权限"]
        }
        if t.contains("yaml") || t.contains("config") {
            return ["code": "config_error", "hint": "hev 配置解析失败：检查 Resources 里的 yaml 是否随包带齐"]
        }
        if t.contains("necp") || t.contains("trust") {
            return ["code": "trust_cache_missing", "hint": "NECP 不认可 appex 签名；需 kfd trust 注入或越狱 trust cache"]
        }
        if t.contains("address already in use") {
            return ["code": "port_in_use", "hint": "端口被占用：换端口或先停旧实例"]
        }
        if t.contains("error") || t.contains("failed") {
            return ["code": "appex_error", "hint": "读取 appex_tail 原文定位；常见为签名/权限/内核退出"]
        }
        return nil
    }

    static func classifyDegraded(_ note: String) -> String {
        let n = note.lowercased()
        if n.contains("denied") || n.contains("user") { return "user_denied" }
        if n.contains("trust") || n.contains("signature") || n.contains("necp") { return "trust_cache_missing" }
        if n.contains("proxy") && n.contains("conflict") { return "proxy_conflict" }
        if n.contains("exit") || n.contains("core") { return "core_exited" }
        return "vpn_start_failed"
    }

    /// 系统 WiFi 代理是否配置（读 CFNetwork 持久化配置，只读不写）
    static func systemProxyConfigured() -> Bool {
        guard let dict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return false
        }
        return (dict[kCFNetworkProxiesHTTPEnable as String] as? Int ?? 0) == 1
            || (dict["HTTPSEnable"] as? Int ?? 0) == 1
    }
}
