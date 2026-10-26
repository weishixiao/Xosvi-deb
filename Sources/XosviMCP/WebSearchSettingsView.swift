import SwiftUI

// MARK: - v7.5.0 联网搜索设置（移植 Kelivo 的搜索服务配置）
//
// 一个服务商一张卡片：选默认服务商、填 API Key（可多个轮询）、SearXNG 填实例地址、
// 底部是「搜索后自动读前 N 条正文」和一次实测。

struct WebSearchSettingsView: View {
    @ObservedObject private var settings = ObservableSettings.shared
    @State private var testing = false
    @State private var testResult = ""
    @State private var testQuery = "TrollStore 最新版本"

    var body: some View {
        List {
            Section {
                Picker("默认服务商", selection: Binding(
                    get: { SearchSettings.shared.defaultProvider },
                    set: { SearchSettings.shared.defaultProvider = $0 }
                )) {
                    ForEach(SearchProvider.allCases) { p in
                        Text(p.displayName + (SearchSettings.shared.usableProviders().contains(p) ? "" : "（未配置）"))
                            .tag(p)
                    }
                }
                Stepper("结果条数：\(SearchSettings.shared.resultSize)",
                        value: Binding(get: { SearchSettings.shared.resultSize },
                                       set: { SearchSettings.shared.resultSize = $0 }),
                        in: 1...20)
                Stepper("搜索后自动读前 \(SearchSettings.shared.autoFetchTop) 条正文",
                        value: Binding(get: { SearchSettings.shared.autoFetchTop },
                                       set: { SearchSettings.shared.autoFetchTop = $0 }),
                        in: 0...10)
            } header: {
                Text("通用")
            } footer: {
                Text("自动读正文会让结果里直接带上页面内容（最多 10 条、每条 6000 字），模型不用再调用一次。")
                    .font(.caption2)
            }

            Section {
                ForEach(SearchProvider.allCases) { p in
                    NavigationLink {
                        ProviderDetailView(provider: p)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: iconFor(p))
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.displayName)
                                    .font(.system(size: 15))
                                Text(statusText(p))
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if SearchSettings.shared.usableProviders().contains(p) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("服务商")
            } footer: {
                Text("必应 / DuckDuckGo 无需配置即可用。带 Key 的服务商通常更稳、能直接给答案摘要；Tavily / Jina / 秘塔 / Firecrawl 还支持读取网页全文（JS 渲染页也能读）。")
                    .font(.caption2)
            }

            Section {
                HStack {
                    TextField("测试搜索词", text: $testQuery)
                        .textFieldStyle(.plain)
                    Button(testing ? "测试中…" : "测试") { runTest() }
                        .disabled(testing || testQuery.isEmpty)
                }
                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("实测")
            }
        }
        .navigationTitle("联网搜索")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func iconFor(_ p: SearchProvider) -> String {
        p.needsKey ? "key" : "globe"
    }

    private func statusText(_ p: SearchProvider) -> String {
        let cfg = SearchSettings.shared.config(for: p)
        if p.needsEndpoint {
            return cfg.endpoint.isEmpty ? "未配置实例地址" : cfg.endpoint
        }
        if p.needsKey {
            let n = cfg.apiKeys.filter { !$0.isEmpty }.count
            return n == 0 ? "未配置 API Key" : "已配置 \(n) 个 Key"
        }
        return "免费 · 无需配置"
    }

    private func runTest() {
        testing = true
        let q = testQuery
        DispatchQueue.global(qos: .userInitiated).async {
            let r = WebSearchService.search(query: q, provider: nil, limit: 5)
            DispatchQueue.main.async {
                testing = false
                if let err = r.error, r.hits.isEmpty {
                    testResult = "✗ \(r.provider)：\(err)"
                } else {
                    testResult = "✓ \(r.provider)：\(r.hits.count) 条" +
                        (r.answer.map { "，带答案摘要" } ?? "") + "\n" +
                        r.hits.prefix(3).map { "· \($0.title)" }.joined(separator: "\n")
                }
            }
        }
    }
}

/// 让 @ObservedObject 能观察到 SearchSettings 的变化
final class ObservableSettings: ObservableObject {
    static let shared = ObservableSettings()
    @Published var tick = 0
}

// MARK: - 单个服务商详情

struct ProviderDetailView: View {
    let provider: SearchProvider
    @State private var keys: [String] = []
    @State private var endpoint = ""
    @State private var user = ""
    @State private var password = ""
    @State private var saved = false

    var body: some View {
        List {
            Section {
                Text(provider.hint)
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary)
            }

            if provider.needsKey {
                Section {
                    ForEach(keys.indices, id: \.self) { i in
                        HStack {
                            TextField(i == 0 ? "主 API Key" : "备用 Key \(i)", text: $keys[i])
                                .textFieldStyle(.plain)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            if i > 0 {
                                Button {
                                    keys.remove(at: i)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                    Button {
                        keys.append("")
                    } label: {
                        Label("再加一个 Key（轮询使用）", systemImage: "plus")
                    }
                } header: {
                    Text("API Key")
                } footer: {
                    Text("多个 Key 会按请求轮换，分摊额度。")
                        .font(.caption2)
                }
            }

            if provider.needsEndpoint {
                Section {
                    TextField("https://searx.be", text: $endpoint)
                        .textFieldStyle(.plain)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("实例地址")
                } footer: {
                    Text("需要在实例的 settings.yml 里开启 json 格式输出。")
                        .font(.caption2)
                }
                Section {
                    TextField("用户名（可选）", text: $user)
                        .textFieldStyle(.plain)
                        .autocapitalization(.none)
                    TextField("密码（可选）", text: $password)
                        .textFieldStyle(.plain)
                } header: {
                    Text("基础认证")
                }
            }

            Section {
                Button("保存") { save() }
                if saved {
                    Text("已保存").font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        let cfg = SearchSettings.shared.config(for: provider)
        keys = cfg.apiKeys.isEmpty ? [""] : cfg.apiKeys
        endpoint = cfg.endpoint
        user = cfg.basicUser
        password = cfg.basicPassword
    }

    private func save() {
        var cfg = SearchSettings.shared.config(for: provider)
        cfg.apiKeys = keys.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        cfg.endpoint = endpoint.trimmingCharacters(in: .whitespaces)
        cfg.basicUser = user
        cfg.basicPassword = password
        SearchSettings.shared.setConfig(cfg, for: provider)
        ObservableSettings.shared.tick += 1
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
    }
}
