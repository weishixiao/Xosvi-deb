import SwiftUI

// MARK: - v8.4：知识库设置页（FTS5 索引管理 + 试检索）
//
// 分层策略：知识**不会全局注入** system prompt（只放一行索引声明），
// 由 knowledge.search 工具按需检索后作为工具结果返回——省 token 且命中精准。

struct KnowledgeSettingsView: View {
    @State private var entryCount = 0
    @State private var builtAt = ""
    @State private var query = ""
    @State private var hits: [KnowledgeHit] = []
    @State private var searched = false

    var body: some View {
        List {
            Section(header: Text("内置知识")) {
                HStack { Text("条目数"); Spacer(); Text("\(entryCount)").foregroundColor(.secondary) }
                HStack { Text("索引构建时间"); Spacer(); Text(builtAt.isEmpty ? "未构建" : builtAt).foregroundColor(.secondary) }
                Button {
                    KnowledgeIndex.shared.rebuild(packs: KnowledgeLoader.loadAll())
                    refresh()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 18))
                        Text("重建索引")
                        Spacer()
                    }
                }
            }
            Section(header: Text("试检索"), footer: Text("模拟 knowledge.search 工具的检索行为（含环境加权）。")) {
                TextField("输入关键词，如：权限被拒绝 / inject / runtime", text: $query)
                    .autocorrectionDisabled()
                    .onSubmit { doSearch() }
                Button {
                    doSearch()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 18))
                        Text("检索")
                        Spacer()
                    }
                }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                if searched && hits.isEmpty {
                    Text("无匹配条目。可换更具体的词（错误原文、工具名）。")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(hits, id: \.id) { h in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(h.title).font(.system(size: 14, weight: .medium))
                        Text(String(h.body.prefix(120)))
                            .font(.caption).foregroundColor(.secondary).lineLimit(2)
                        if !h.appliesIf.isEmpty {
                            Text("applies_if: \(h.appliesIf.joined(separator: ", "))")
                                .font(.caption2).foregroundColor(DoubaoTheme.accent)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section(header: Text("说明")) {
                Text("知识不会全局注入上下文，由 knowledge.search 按需检索后作为工具结果返回。")
                    .font(.caption).foregroundColor(.secondary)
                Text("自定义条目放 Documents/Knowledge/custom/*.json（结构见内置包），导入后点「重建索引」。")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .deepseekList()
        .navigationTitle("知识库")
        .onAppear(perform: refresh)
    }

    private func doSearch() {
        hits = KnowledgeIndex.shared.search(query, context: KnowledgeLoader.deviceContext, limit: 3)
        searched = true
    }

    private func refresh() {
        entryCount = Int(KnowledgeIndex.shared.meta("entry_count") ?? "0") ?? 0
        if let ts = KnowledgeIndex.shared.meta("built_at"), let d = Double(ts) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            builtAt = f.string(from: Date(timeIntervalSince1970: d))
        } else {
            builtAt = ""
        }
    }
}
