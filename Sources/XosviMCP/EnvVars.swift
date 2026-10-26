// EnvVars.swift — 用户自定义环境变量（v6.6.19）
//
// 用途：给工具链注入 API key、代理、路径等。存 UserDefaults（与 GitHub token 同策略，
// 沙盒里的 Keychain 在 TrollStore/越狱环境下不可靠）。
//
// 注入点：
//   - 所有 posix_spawn 子进程（BuildRunner）
//   - 进程内 Python（py 工具，os.environ 可见）
//   - MCP 工具 env.list / env.set / env.unset 供 AI 读写

import Foundation
import Combine

final class EnvVarsStore: ObservableObject {
    static let shared = EnvVarsStore()
    static let storageKey = "xosvi.env.vars"

    /// 键排序后的快照，UI 直接用
    @Published private(set) var vars: [String: String] = [:]

    private init() { reload() }

    func reload() {
        vars = EnvVars.current()
    }

    func set(_ value: String, for key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, k.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { return }
        vars[k] = value
        persist()
    }

    func remove(_ key: String) {
        vars.removeValue(forKey: key)
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(vars) {
            UserDefaults.standard.set(d, forKey: Self.storageKey)
        }
        AuditLog.shared.log("env.update", detail: "\(vars.count) vars")
    }

    var sortedKeys: [String] { vars.keys.sorted() }
}

/// 工具线程安全读取（同 GHConfig：直接读 UserDefaults，不依赖 UI 层）
enum EnvVars {
    static func current() -> [String: String] {
        guard let d = UserDefaults.standard.data(forKey: EnvVarsStore.storageKey),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }

    /// 用户变量作为默认值，显式传入的 env 覆盖同名键
    static func merged(into base: [String: String]) -> [String: String] {
        var out = current()
        for (k, v) in base { out[k] = v }
        return out
    }

    /// 给 Python 用：把 user vars 与原环境合并写成 JSON
    static func pythonEnvJSON() -> String {
        var m = current()
        for key in ["PATH", "HOME", "LANG", "TMPDIR"] {
            if m[key] == nil, let v = ProcessInfo.processInfo.environment[key] { m[key] = v }
        }
        guard let d = try? JSONSerialization.data(withJSONObject: m, options: []),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}

/// 让 AI 能直接读写环境变量（用户也可以只在设置里改）
final class EnvTool: MCPTool {
    let definition = ToolDefinition(
        name: "env",
        summary: "Manage user environment variables (injected into spawned processes and in-process Python). Commands: list / set / unset. Use for: add API keys or proxy settings the agent needs, inspect configured vars. Don't use for: reading system env (values are returned only for user-defined vars). Example: env command:set key:HTTP_PROXY value:http://127.0.0.1:8080",
        parameters: [
            "command": "list / set / unset",
            "key": "variable name (for set/unset)",
            "value": "variable value (for set)"
        ],
        verified: true, category: "config", prerequisites: ["改动立即生效，已运行的 Python 解释器需要新开一次 eval 才看到"])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = (params["command"] as? String)?.lowercased(), !command.isEmpty else {
            throw MCPError.invalidParams("env: missing command (list / set / unset)")
        }
        let store = EnvVarsStore.shared
        switch command {
        case "list":
            let vars = EnvVars.current()
            return ["count": vars.count,
                    "vars": vars.map { ["key": $0.key, "value": $0.value] }.sorted { ($0["key"] ?? "") < ($1["key"] ?? "") },
                    "note": "值会注入所有子进程与进程内 Python"]
        case "set":
            guard let key = params["key"] as? String, let value = params["value"] as? String else {
                throw MCPError.invalidParams("env set: key 和 value 都必填")
            }
            store.set(value, for: key)
            return ["ok": true, "key": key, "count": EnvVars.current().count]
        case "unset":
            guard let key = params["key"] as? String else {
                throw MCPError.invalidParams("env unset: key 必填")
            }
            store.remove(key)
            return ["ok": true, "key": key, "count": EnvVars.current().count]
        default:
            throw MCPError.invalidParams("env: unknown command '\(command)' (list / set / unset)")
        }
    }
}
