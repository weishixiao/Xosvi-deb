import SwiftUI
import Foundation
import Combine

// MARK: - v7.6.3 旧模型层兼容垫片
//
// A 方案：旧 ModelStore / ModelConfig 的「存储与管理」职责已由 LiteLLMStore 接管。
// 这里保留同名类型（ModelConfig、ModelStore）作为 **兼容门面**，让 15 个调用文件
// 一行不用改即可编译；内部数据全部来自 LiteLLMStore 的 deployment。
//
// 后续可逐步把调用点切到 LiteLLMStore 原生 API，然后删掉本文件。

// MARK: ModelConfig ≈ ModelEntry 的视图

struct ModelConfig: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var provider: String
    var apiProtocol: String
    var baseURL: String
    var apiKey: String
    var model: String
    var authMethod: String
    var isDefault: Bool
    var temperature: Double
    var maxTokens: Int
    var contextTokens: Int
    var compatLevel: Int
    var group: String
    var paramAliases: [String: String]

    init(entry: ModelEntry) {
        // 稳定 id：直接用 deployment 的 id，保证 update 能写回
        self.id = entry.id
        self.name = entry.displayBadge
        self.provider = entry.provider
        self.apiProtocol = entry.apiProtocol
        self.baseURL = entry.baseURL
        self.apiKey = entry.apiKey
        self.model = entry.modelName
        self.authMethod = entry.authMethod
        self.isDefault = entry.isDefault
        self.temperature = entry.temperature
        self.maxTokens = entry.maxTokens
        self.contextTokens = entry.contextTokens
        self.compatLevel = entry.compatLevel
        self.group = entry.group
        self.paramAliases = entry.paramAliases
    }

    init(id: UUID = UUID(), name: String, provider: String, apiProtocol: String = "OpenAI Chat Completions",
         baseURL: String, apiKey: String, model: String, authMethod: String = "Bearer",
         isDefault: Bool = false, temperature: Double = 0.7, maxTokens: Int = 4096, compatLevel: Int = 0,
         contextTokens: Int = 32000, group: String = "default", paramAliases: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.provider = provider
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.authMethod = authMethod
        self.isDefault = isDefault
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.contextTokens = contextTokens
        self.compatLevel = compatLevel
        self.group = group
        self.paramAliases = paramAliases
    }

    /// 写回 LiteLLMStore
    func toEntry() -> ModelEntry {
        var e = ModelEntry(
            modelName: model,
            provider: provider,
            apiProtocol: apiProtocol,
            baseURL: baseURL,
            apiKey: apiKey,
            authMethod: authMethod,
            temperature: temperature,
            maxTokens: maxTokens,
            contextTokens: contextTokens,
            compatLevel: compatLevel,
            paramAliases: paramAliases,
            group: group,
            isDefault: isDefault
        )
        e.id = id
        return e
    }

    // 旧代码用到的派生属性
    var supportsVision: Bool {
        let m = model.lowercased()
        return m.contains("gpt-4o") || m.contains("claude-3") || m.contains("gemini")
            || m.contains("vision") || m.contains("vl-")
    }

    var isReasoningModel: Bool {
        let m = model.lowercased()
        return ["gpt-5.", "o1", "o3", "o4"].contains(where: { m.hasPrefix($0) }) || m.contains("reasoning")
    }

    var sendsTemperature: Bool { !isReasoningModel }

    var maxTokensKey: String { isReasoningModel ? "max_completion_tokens" : "max_tokens" }
}

extension ModelConfig {
    static let apiProtocols = ["OpenAI Chat Completions", "OpenAI Responses", "Anthropic Messages", "Custom Endpoint"]
    static let authMethods = ["Bearer", "x-api-key", "api-key", "Query key", "Body api_key", "None"]

    static var providerPresets: [(name: String, provider: String, protocol: String, baseURL: String, model: String, auth: String)] {
        LiteLLMProvider.all.map { ($0.name, $0.id, $0.defaultProtocol, $0.defaultBaseURL, $0.modelsHint.first ?? "", $0.defaultAuth) }
    }

    static func normalizeBaseURL(_ base: String) -> String {
        let t = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let u = URL(string: t) else { return base }
        if u.path.isEmpty || u.path == "/" { return t + "/v1" }
        return base
    }

    static func autoCorrectProtocol(model: String, provider: String, current: String) -> String {
        let m = model.lowercased()
        let p = provider.lowercased()
        if current == "Custom Endpoint" { return current }
        if p.contains("anthropic") || m.hasPrefix("claude") { return "Anthropic Messages" }
        if ["gpt-5.", "o1", "o3", "o4"].contains(where: { m.hasPrefix($0) }) { return "OpenAI Responses" }
        if p.contains("deepseek") || m.contains("deepseek") { return "OpenAI Chat Completions" }
        return current
    }
}

// MARK: ModelStore ≈ LiteLLMStore 的门面

final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    private let backend = LiteLLMStore.shared
    private var cancellable: AnyCancellable?

    init() {
        // v7.6.3：configs 是从 LiteLLMStore 投影出来的计算属性，自身 objectWillChange
        // 不会触发（SwiftUI 对计算属性没有 KVO）。这里把 SwiftUI 的刷新绑定到后端：
        // 后端 entries 一变，先让旧的观察者重新求值再转发通知。
        cancellable = backend.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// 旧代码直接读写 configs —— 每次读都从 LiteLLMStore 投影出来
    var configs: [ModelConfig] {
        get { backend.entries.map { ModelConfig(entry: $0) } }
        set {
            backend.entries = newValue.map { $0.toEntry() }
        }
    }

    var lastUsedConfigId: String? {
        get { UserDefaults.standard.string(forKey: "litellm.last_used_id") }
        set { UserDefaults.standard.set(newValue, forKey: "litellm.last_used_id") }
    }

    func markUsed(_ id: String) { lastUsedConfigId = id }

    func load() { backend.migrateFromLegacyIfNeeded() }
    func save() { backend.save() }

    var defaultConfig: ModelConfig? {
        backend.defaultEntry.map { ModelConfig(entry: $0) }
    }

    func add(_ config: ModelConfig) {
        var e = config.toEntry()
        if backend.entries.isEmpty { e.isDefault = true }
        backend.upsert(e)
    }

    func update(_ config: ModelConfig) {
        backend.upsert(config.toEntry())
    }

    func importFromDeepLink(_ config: ModelConfig) -> Bool {
        if backend.entries.contains(where: { $0.baseURL == config.baseURL && $0.modelName == config.model }) {
            return false
        }
        add(config)
        return true
    }

    func delete(at offsets: IndexSet) {
        let list = backend.entries
        for i in offsets.sorted(by: >) where i < list.count {
            backend.remove(list[i])
        }
    }

    // 熔断器：沿用旧实现（CircuitBreaker 仍在 Models.swift 里定义）
    private(set) var breakers: [UUID: CircuitBreaker] = [:]
    private let breakerLock = NSLock()

    func breaker(for id: UUID) -> CircuitBreaker {
        breakerLock.lock()
        defer { breakerLock.unlock() }
        if let b = breakers[id] { return b }
        let b = CircuitBreaker(name: backend.entries.first { $0.id == id }?.modelName ?? "model")
        breakers[id] = b
        return b
    }

    // 导入导出
    func exportJSON() -> String {
        var items: [Any] = []
        for c in configs {
            if let d = try? JSONEncoder().encode(c),
               let obj = try? JSONSerialization.jsonObject(with: d) {
                items.append(obj)
            }
        }
        let payload: [String: Any] = ["version": 2, "configs": items]
        guard let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    func importJSON(_ text: String) -> (ok: Int, failed: Int) {
        guard let data = text.data(using: .utf8) else { return (0, 0) }
        var arr: [[String: Any]] = []
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = obj["configs"] as? [[String: Any]] {
            arr = list
        } else if let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            arr = list
        }
        var ok = 0, failed = 0
        for item in arr {
            if let d = try? JSONSerialization.data(withJSONObject: item),
               let c = try? JSONDecoder().decode(ModelConfig.self, from: d) {
                add(c); ok += 1
            } else {
                failed += 1
            }
        }
        return (ok, failed)
    }
}
