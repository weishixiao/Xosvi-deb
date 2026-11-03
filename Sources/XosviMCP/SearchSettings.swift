import Foundation
import Combine

// MARK: - v9：搜索服务商实例 + 网页读取模式（移植 Kelivo search_services / search_settings）
//
// 与 v7.5.0 的差别：那时「一个服务商一份配置」，服务商由 enum 唯一标识，
// 没法同时存两套 Tavily（一主一备），也没有「网页读取方式」这个概念——
// 读网页时永远自动挑第一个有 Key 的 reader，用户无法干预。
//
// 这里按文档补上：
//   · SearchServiceOptions：可增删的服务商**实例**（多套并存，各有 id）
//   · webFetchModeValue: String?  —— nil=跟随 / "local" / "off" / 其它=服务商实例 id
//     （刻意不用 enum：跟随与「指定某服务商」要共存，且被指定的服务商可能被删）
//   · 跟随模式下服务商不支持 reader 时**优雅降级到本地抓取**，标签也如实显示
//
// 兼容：老版本按 enum 存的 Key 全部保留在 SearchProviderConfig 里，
// 首次读取时按「一个 kind 一个实例」升格成 services 列表（不删旧数据）。

struct SearchServiceOptions: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var kind: SearchProvider
    /// 多 Key 轮询（第一个是主 Key）
    var apiKeys: [String] = []
    /// SearXNG 实例地址
    var endpoint: String = ""
    var basicUser: String = ""
    var basicPassword: String = ""
    var enabled: Bool = true
    /// 用户自定义显示名（空则用 kind.displayName）
    var customName: String = ""

    var displayName: String { customName.isEmpty ? kind.displayName : customName }
    var primaryKey: String { apiKeys.first ?? "" }
    var hasKey: Bool { apiKeys.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// 这个实例是否真的可用（免费引擎永远可用；SearXNG 要地址；带 Key 的要 Key）
    var isUsable: Bool {
        if kind.needsEndpoint { return !endpoint.trimmingCharacters(in: .whitespaces).isEmpty }
        if kind.needsKey { return hasKey }
        return true
    }

    /// 是否支持读网页（跟 kind 能力 + 自身凭据都有关）
    var supportsReader: Bool {
        guard kind.supportsFetch else { return false }
        return hasKey
    }

    init(kind: SearchProvider, id: String = UUID().uuidString) {
        self.id = id
        self.kind = kind
    }

    // 手写 init(from:) 只为容错：老/残缺 JSON 不该让整个设置页崩掉
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        kind = (try? c.decode(SearchProvider.self, forKey: .kind)) ?? .bing
        apiKeys = (try? c.decode([String].self, forKey: .apiKeys)) ?? []
        endpoint = (try? c.decode(String.self, forKey: .endpoint)) ?? ""
        basicUser = (try? c.decode(String.self, forKey: .basicUser)) ?? ""
        basicPassword = (try? c.decode(String.self, forKey: .basicPassword)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        customName = (try? c.decode(String.self, forKey: .customName)) ?? ""
    }
}

/// 网页读取方式
enum WebFetchMode: String, Codable {
    case follow      // 跟随搜索服务商（不支持 reader 则本地抓取）
    case local       // 本地直连抓取
    case provider    // 指定服务商实例（值存在 webFetchModeValue 里）
    case off         // 关闭读取，只给 snippet

    static func parse(_ s: String?) -> WebFetchMode {
        guard let s, !s.isEmpty else { return .follow }
        if s == "local" { return .local }
        if s == "off" { return .off }
        return .provider
    }
}

final class SearchSettings: ObservableObject {
    static let shared = SearchSettings()

    /// 服务商实例列表（可增删、多套并存）
    @Published private(set) var services: [SearchServiceOptions] = []
    /// 当前选中的实例下标（越界自动夹到合法范围）
    @Published var selectedIndex: Int = 0
    /// 连接状态缓存：实例 id → true/false（nil = 未测试）
    @Published var connection: [String: Bool] = [:]
    /// 读取方式原始值：nil=跟随 / "local" / "off" / 其它=实例 id
    @Published var webFetchModeValue: String? = nil
    @Published var autoTestOnLaunch: Bool = false
    @Published var timeoutSeconds: Int = 30

    private var didLoad = false

    private enum Keys {
        static let services = "websearch.services.v9"
        static let selected = "websearch.selectedIndex.v9"
        static let fetchMode = "websearch.fetchMode.v9"
        static let autoTest = "websearch.autoTest.v9"
        static let timeout = "websearch.timeout.v9"
        static let connection = "websearch.connection.v9"
    }

    private init() { load() }

    // MARK: 加载 / 保存

    func load() {
        guard !didLoad else { return }
        didLoad = true
        let ud = UserDefaults.standard

        if let data = ud.data(forKey: Keys.services),
           let list = try? JSONDecoder().decode([SearchServiceOptions].self, from: data),
           !list.isEmpty {
            services = list
        } else {
            services = legacyMigration()
            persistServices()
        }
        selectedIndex = min(max(0, ud.integer(forKey: Keys.selected)), max(0, services.count - 1))
        webFetchModeValue = ud.string(forKey: Keys.fetchMode)
        autoTestOnLaunch = ud.bool(forKey: Keys.autoTest)
        let t = ud.integer(forKey: Keys.timeout)
        timeoutSeconds = t > 0 ? min(max(t, 5), 120) : 30
        if let data = ud.data(forKey: Keys.connection),
           let map = try? JSONDecoder().decode([String: Bool].self, from: data) {
            connection = map
        }
    }

    /// 老版本（按 enum 存 Key）→ 新结构：一个 kind 一个实例
    private func legacyMigration() -> [SearchServiceOptions] {
        var out: [SearchServiceOptions] = []
        let def = defaultProviderRaw
        for p in SearchProvider.allCases {
            let cfg = legacyConfig(for: p)
            // 只升格有配置的：免费引擎 + 用户填过 Key/地址的
            let hasContent = !cfg.apiKeys.isEmpty || !cfg.endpoint.isEmpty
            if !p.needsKey && !p.needsEndpoint && p != def && !hasContent { continue }
            if p.needsKey && !hasContent { continue }
            var s = SearchServiceOptions(kind: p)
            s.apiKeys = cfg.apiKeys
            s.endpoint = cfg.endpoint
            s.basicUser = cfg.basicUser
            s.basicPassword = cfg.basicPassword
            s.enabled = cfg.enabled
            out.append(s)
        }
        if out.isEmpty { out = [SearchServiceOptions(kind: .bing), SearchServiceOptions(kind: .duckduckgo)] }
        // 默认服务商排第一，保证迁移后行为不变
        if let i = out.firstIndex(where: { $0.kind == def }), i != 0 {
            let s = out.remove(at: i)
            out.insert(s, at: 0)
        }
        return out
    }

    func save() {
        persistServices()
        let ud = UserDefaults.standard
        ud.set(selectedIndex, forKey: Keys.selected)
        if let v = webFetchModeValue { ud.set(v, forKey: Keys.fetchMode) }
        else { ud.removeObject(forKey: Keys.fetchMode) }
        ud.set(autoTestOnLaunch, forKey: Keys.autoTest)
        ud.set(timeoutSeconds, forKey: Keys.timeout)
        if let data = try? JSONEncoder().encode(connection) { ud.set(data, forKey: Keys.connection) }
    }

    private func persistServices() {
        if let data = try? JSONEncoder().encode(services) {
            UserDefaults.standard.set(data, forKey: Keys.services)
        }
    }

    // MARK: 选中 / 增删改

    var selectedService: SearchServiceOptions? {
        if services.indices.contains(selectedIndex) { return services[selectedIndex] }
        return services.first
    }

    func select(id: String) {
        guard let i = services.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = i
        save()
    }

    func upsert(_ service: SearchServiceOptions) {
        if let i = services.firstIndex(where: { $0.id == service.id }) {
            services[i] = service
        } else {
            services.append(service)
            selectedIndex = services.count - 1
            // 文档要点 3：新增服务商若支持读页，自动设为读取源——
            // 否则用户加了 Tavily 却发现读取方式还是「本地」，会以为是 bug
            if service.supportsReader { webFetchModeValue = service.id }
        }
        save()
        objectWillChange.send()
    }

    @discardableResult
    func delete(id: String) -> Bool {
        guard services.count > 1 else { return false }   // 至少留一个
        guard let i = services.firstIndex(where: { $0.id == id }) else { return false }
        services.remove(at: i)
        if selectedIndex >= services.count { selectedIndex = services.count - 1 }
        else if selectedIndex > i { selectedIndex -= 1 }
        // 读取源被删 → 退回跟随，避免留下指向不存在实例的悬空值
        if webFetchModeValue == id { webFetchModeValue = nil }
        connection.removeValue(forKey: id)
        save()
        objectWillChange.send()
        return true
    }

    func setConnection(_ ok: Bool, for id: String) {
        connection[id] = ok
        if let data = try? JSONEncoder().encode(connection) {
            UserDefaults.standard.set(data, forKey: Keys.connection)
        }
    }

    // MARK: 读取方式解析

    var effectiveWebFetchMode: WebFetchMode { WebFetchMode.parse(webFetchModeValue) }

    /// 指定模式下真正生效的实例（不存在则 nil → 调用方降级本地）
    var designatedFetchService: SearchServiceOptions? {
        guard let v = webFetchModeValue, !v.isEmpty,
              v != "local", v != "off" else { return nil }
        return services.first { $0.id == v }
    }

    /// 跟随模式下真正读网页的实例（当前服务商不支持 reader → nil，走本地）
    var followTarget: SearchServiceOptions? {
        guard let s = selectedService else { return nil }
        return s.supportsReader ? s : nil
    }

    var webFetchModeLabel: String {
        switch effectiveWebFetchMode {
        case .follow:
            if let t = followTarget { return "跟随搜索 · \(t.displayName)" }
            return "跟随搜索 · 本地抓取"
        case .local:
            return "本地直连"
        case .off:
            return "关闭"
        case .provider:
            return designatedFetchService?.displayName ?? "已失效（降级本地）"
        }
    }

    /// 给 WebFetchService 用的解析结果：nil = 关闭读取
    /// (provider: 指定实例, allowLocalFallback: 该实例失败后是否还能本地抓)
    func resolveFetchPlan() -> (service: SearchServiceOptions?, allowLocalFallback: Bool)? {
        switch effectiveWebFetchMode {
        case .off:
            return nil
        case .local:
            return (nil, true)
        case .follow:
            return (followTarget, true)
        case .provider:
            if let s = designatedFetchService { return (s, true) }
            return (nil, true)   // 服务商被删 → 降级本地
        }
    }

    // MARK: 与老版本 API 的兼容层
    //
    // WebSearchService / WebFetchService / 工具层还按 SearchProvider 取配置。
    // 这里把「选中的实例」翻译成旧接口语义，避免全仓改动：
    //   · config(for:) 返回**选中实例**的配置；没有该 kind 的实例则返回旧存储
    //   · nextKey(for:) 在选中实例是同一 kind 时轮询它自己的 Key 列表

    private var roundRobin: [String: Int] = [:]

    /// 老版默认服务商（选中实例的 kind）
    var defaultProvider: SearchProvider {
        get { selectedService?.kind ?? .bing }
        set {
            if let i = services.firstIndex(where: { $0.kind == newValue }) {
                selectedIndex = i
            } else {
                let s = SearchServiceOptions(kind: newValue)
                services.append(s)
                selectedIndex = services.count - 1
            }
            save()
            objectWillChange.send()
        }
    }

    private var defaultProviderRaw: SearchProvider {
        let raw = UserDefaults.standard.string(forKey: "websearch.provider") ?? ""
        return SearchProvider(rawValue: raw) ?? .bing
    }

    /// 老存储（v7.5.0 的 websearch.cfg.<kind>）
    fileprivate func legacyConfig(for p: SearchProvider) -> SearchProviderConfig {
        guard let data = UserDefaults.standard.data(forKey: "websearch.cfg.\(p.rawValue)"),
              let cfg = try? JSONDecoder().decode(SearchProviderConfig.self, from: data) else {
            return SearchProviderConfig()
        }
        return cfg
    }

    func config(for p: SearchProvider) -> SearchProviderConfig {
        if let s = services.first(where: { $0.kind == p && $0.isUsable })
            ?? services.first(where: { $0.kind == p }) {
            var c = SearchProviderConfig()
            c.apiKeys = s.apiKeys
            c.endpoint = s.endpoint
            c.basicUser = s.basicUser
            c.basicPassword = s.basicPassword
            c.enabled = s.enabled
            return c
        }
        return legacyConfig(for: p)
    }

    /// 兼容旧调用：写回时落到「该 kind 的选中实例」，没有就新建
    func setConfig(_ cfg: SearchProviderConfig, for p: SearchProvider) {
        if let i = services.firstIndex(where: { $0.kind == p }) {
            services[i].apiKeys = cfg.apiKeys
            services[i].endpoint = cfg.endpoint
            services[i].basicUser = cfg.basicUser
            services[i].basicPassword = cfg.basicPassword
            services[i].enabled = cfg.enabled
        } else {
            var s = SearchServiceOptions(kind: p)
            s.apiKeys = cfg.apiKeys
            s.endpoint = cfg.endpoint
            s.basicUser = cfg.basicUser
            s.basicPassword = cfg.basicPassword
            s.enabled = cfg.enabled
            services.append(s)
        }
        persistServices()
        objectWillChange.send()
    }

    /// 轮询取下一个可用 Key（Kelivo 的多 Key 负载均衡）
    func nextKey(for p: SearchProvider) -> String {
        // v9：调用方显式指定了服务商实例（测连 / 工具 provider=）时，用该实例的 Key，
        // 不参与全局轮询——否则测 A 实例会打到 B 实例的 Key 上。
        if let ov = Self.threadOverride, ov.kind == p, ov.hasKey {
            return ov.primaryKey
        }
        let keys = config(for: p).apiKeys.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !keys.isEmpty else { return "" }
        let idx = (roundRobin[p.rawValue] ?? 0) % keys.count
        roundRobin[p.rawValue] = idx + 1
        return keys[idx]
    }

    // MARK: 线程级实例覆盖
    //
    // 并行多 query 会同时跑多个引擎，用全局变量会串味；threadDictionary 天然按线程隔离。

    private static let overrideKey = "xosvi.searchServiceOverride"

    static var threadOverride: SearchServiceOptions? {
        Thread.current.threadDictionary[overrideKey] as? SearchServiceOptions
    }

    static func withServiceOverride<T>(_ service: SearchServiceOptions?, _ body: () -> T) -> T {
        guard let service else { return body() }
        let dict = Thread.current.threadDictionary
        let previous = dict[overrideKey]
        dict[overrideKey] = service
        defer {
            if let previous { dict[overrideKey] = previous } else { dict.removeObject(forKey: overrideKey) }
        }
        return body()
    }

    /// 列出已配置好、可直接用的服务商（按实例顺序去重 kind）
    func usableProviders() -> [SearchProvider] {
        var out: [SearchProvider] = []
        for s in services where s.enabled && s.isUsable {
            if !out.contains(s.kind) { out.append(s.kind) }
        }
        if out.isEmpty {
            // 兜底：老存储里配置过但还没升格的
            for p in SearchProvider.allCases {
                let cfg = legacyConfig(for: p)
                if p.needsEndpoint { if !cfg.endpoint.isEmpty { out.append(p) } }
                else if p.needsKey { if !cfg.apiKeys.contains(where: { !$0.isEmpty }) { continue }; out.append(p) }
            }
        }
        return out
    }

    /// 结果条数（老键，保持兼容）
    var resultSize: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "websearch.size")
            return max(1, min(v == 0 ? 8 : v, 20))
        }
        set { UserDefaults.standard.set(newValue, forKey: "websearch.size") }
    }

    /// 搜索后自动读前 N 条正文（0 = 不读）
    var autoFetchTop: Int {
        get { UserDefaults.standard.integer(forKey: "websearch.autofetch") }
        set { UserDefaults.standard.set(newValue, forKey: "websearch.autofetch") }
    }
}

// MARK: - 老结构（仅用于兼容读取，写入走 SearchServiceOptions）

struct SearchProviderConfig: Codable, Equatable {
    var apiKeys: [String] = []       // 第一个是主 Key，其余轮询
    var endpoint: String = ""        // SearXNG 实例地址
    var basicUser: String = ""
    var basicPassword: String = ""
    var enabled: Bool = true

    var primaryKey: String { apiKeys.first ?? "" }
}
