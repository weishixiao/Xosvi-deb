import SwiftUI

// MARK: - v7.6.3 LiteLLM 数据存储 + 路由选择
//
// LiteLLMStore 持有：
//   entries   —— 全部 deployment
//   settings  —— 路由策略 / 重试 / 冷却 / fallback
//   keys      —— 虚拟密钥
//   logs      —— 最近请求（本机环形缓冲）
//
// ChatView / OpenAIClient 通过 `nextEntry(for:)` 取一条 deployment，
// 由路由策略决定选哪条（对齐 litellm Router 的 routing_strategy）。

struct RequestLogEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = Date()
    var modelString: String
    var entryId: UUID?
    var ok: Bool
    var duration: Double
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var cost: Double = 0
}

final class LiteLLMStore: ObservableObject {
    static let shared = LiteLLMStore()

    @Published var entries: [ModelEntry] = [] {
        didSet { scheduleSave() }
    }
    @Published var settings = LiteLLMConfig() {
        didSet { scheduleSave() }
    }
    @Published var keys: [VirtualKey] = [] {
        didSet { scheduleSave() }
    }
    @Published var logs: [RequestLogEntry] = []

    // 运行态（不持久化）
    private var inflight: [UUID: Int] = [:]
    private var latencyEMA: [UUID: Double] = [:]

    private let entriesKey = "litellm.entries.v1"
    private let settingsKey = "litellm.settings.v1"
    private let keysKey = "litellm.keys.v1"
    private var saving = false

    private init() { load() }

    // MARK: 派生数据

    /// 全部模型组名（保持出现顺序，默认组排最前）
    var groups: [String] {
        var seen: [String] = []
        for e in entries where !seen.contains(e.modelName) {
            seen.append(e.modelName)
        }
        // 默认所在的组提到最前
        if let dg = defaultEntry?.modelName, let i = seen.firstIndex(of: dg) {
            seen.remove(at: i)
            seen.insert(dg, at: 0)
        }
        return seen
    }

    var defaultEntry: ModelEntry? {
        entries.first { $0.isDefault } ?? entries.first
    }

    func entries(in group: String) -> [ModelEntry] {
        entries.filter { $0.modelName == group }
    }

    // MARK: 增删改

    func newEntry(for provider: LiteLLMProvider) -> ModelEntry {
        ModelEntry(
            modelName: provider.modelsHint.first ?? "new-model",
            provider: provider.id,
            apiProtocol: provider.defaultProtocol,
            baseURL: provider.defaultBaseURL,
            apiKey: "",
            authMethod: provider.defaultAuth,
            isDefault: entries.isEmpty
        )
    }

    func upsert(_ entry: ModelEntry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        if entry.isDefault {
            for i in entries.indices where entries[i].id != entry.id {
                entries[i].isDefault = false
            }
        }
    }

    func remove(_ entry: ModelEntry) {
        entries.removeAll { $0.id == entry.id }
        if let d = defaultEntry, d.id == entry.id { /* 已自动回退 */ }
    }

    func markDefault(_ entry: ModelEntry) {
        for i in entries.indices {
            entries[i].isDefault = (entries[i].id == entry.id)
        }
    }

    // MARK: 虚拟密钥

    func addVirtualKey(alias: String, scope: String) {
        keys.append(VirtualKey.generate(alias: alias, scope: scope))
    }

    func removeKey(_ key: VirtualKey) {
        keys.removeAll { $0.id == key.id }
    }

    // MARK: 路由

    /// 按策略选一条 deployment。group 为空时用默认组。
    func nextEntry(for group: String? = nil) -> ModelEntry? {
        let pool = group.map { entries(in: $0) } ?? (defaultEntry.map { entries(in: $0.modelName) } ?? [])
        guard !pool.isEmpty else { return defaultEntry }

        switch settings.routingStrategy {
        case .simpleShuffle:
            // 按 weight 加权随机
            let total = max(1, pool.reduce(0) { $0 + max(1, $1.weight) })
            var pick = Int.random(in: 0..<total)
            for e in pool {
                pick -= max(1, e.weight)
                if pick < 0 { return e }
            }
            return pool.last

        case .leastBusy:
            return pool.min { (inflight[$0.id] ?? 0) < (inflight[$1.id] ?? 0) }

        case .usageBased:
            // 用延迟 EMA 近似用量均衡（无服务端计数器时的本机近似）
            return pool.min { (latencyEMA[$0.id] ?? 0) < (latencyEMA[$1.id] ?? 0) }

        case .latencyBased:
            return pool.min { (latencyEMA[$0.id] ?? Double.greatestFiniteMagnitude)
                           < (latencyEMA[$1.id] ?? Double.greatestFiniteMagnitude) }

        case .priority:
            return pool.min { $0.priority < $1.priority }
        }
    }

    func markRequestStart(_ entry: ModelEntry) {
        inflight[entry.id, default: 0] += 1
    }

    func markRequestEnd(_ entry: ModelEntry, ok: Bool, duration: Double) {
        inflight[entry.id] = max(0, (inflight[entry.id] ?? 1) - 1)
        let prev = latencyEMA[entry.id] ?? duration
        latencyEMA[entry.id] = prev * 0.7 + duration * 0.3
        if !ok {
            // 失败拉高延迟估值，让延迟类策略自然避开它
            latencyEMA[entry.id] = (latencyEMA[entry.id] ?? duration) + 30
        }
    }

    func appendLog(_ log: RequestLogEntry) {
        logs.insert(log, at: 0)
        if logs.count > max(20, settings.logRetention) {
            logs = Array(logs.prefix(settings.logRetention))
        }
    }

    // MARK: 持久化

    private func scheduleSave() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.saving = false
            self.save()
        }
    }

    func save() {
        let ud = UserDefaults.standard
        if let d = try? JSONEncoder().encode(entries) { ud.set(d, forKey: entriesKey) }
        if let d = try? JSONEncoder().encode(settings) { ud.set(d, forKey: settingsKey) }
        if let d = try? JSONEncoder().encode(keys) { ud.set(d, forKey: keysKey) }
    }

    private func load() {
        let ud = UserDefaults.standard
        if let d = ud.data(forKey: entriesKey),
           let v = try? JSONDecoder().decode([ModelEntry].self, from: d) {
            entries = v
        }
        if let d = ud.data(forKey: settingsKey),
           let v = try? JSONDecoder().decode(LiteLLMConfig.self, from: d) {
            settings = v
        }
        if let d = ud.data(forKey: keysKey),
           let v = try? JSONDecoder().decode([VirtualKey].self, from: d) {
            keys = v
        }
    }

    // MARK: 从旧 ModelStore 迁移一次

    /// 旧版 `xosvi.model_configs` 的字段大致对应，这里做一次性迁移，
    /// 迁移后写标记位，不会重复迁移。
    func migrateFromLegacyIfNeeded() {
        let flag = "litellm.migrated.from.legacy"
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: flag) else { return }
        defer { ud.set(true, forKey: flag) }
        guard entries.isEmpty else { return }
        guard let data = ud.data(forKey: "xosvi.model_configs"),
              let legacy = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !legacy.isEmpty else { return }

        var migrated: [ModelEntry] = []
        for (idx, raw) in legacy.enumerated() {
            let name = raw["model"] as? String ?? "model-\(idx + 1)"
            let provider = (raw["provider"] as? String ?? "custom_openai")
            migrated.append(ModelEntry(
                modelName: name,
                provider: provider,
                apiProtocol: raw["apiProtocol"] as? String ?? "OpenAI Chat Completions",
                baseURL: raw["baseURL"] as? String ?? "",
                apiKey: raw["apiKey"] as? String ?? "",
                authMethod: raw["authMethod"] as? String ?? "Bearer",
                temperature: raw["temperature"] as? Double ?? 0.7,
                maxTokens: raw["maxTokens"] as? Int ?? 4096,
                contextTokens: raw["contextTokens"] as? Int ?? 32000,
                compatLevel: raw["compatLevel"] as? Int ?? 0,
                isDefault: raw["isDefault"] as? Bool ?? (idx == 0)
            ))
        }
        entries = migrated
        save()
    }
}
