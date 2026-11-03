// EnvVarsView.swift — 设置 → 环境变量（v6.6.19）
// v8.4：一比一重构——对齐模型管理页设计语言：
//   · 按前缀分组（GIT_* / HTTP_* / 其它）——与模型页按 group 分组同构
//   · 行样式复用 ModelRow 模式：左键名（等宽）+ 副行脱敏值 + 眼睛切换 + 行尾菜单
//   · 统一 deepseekList 风格 + rowAction 组件 + 工具栏导出入口
//   · 脱敏规则与 GitNative.mask 一致思路：前 4 + 后 4 可见，中间点号

import SwiftUI

struct EnvVarsView: View {
    @ObservedObject private var store = EnvVarsStore.shared
    @State private var editingKey: String?
    @State private var editValue = ""
    @State private var showingAdd = false
    @State private var revealed: Set<String> = []
    @State private var errorMsg: String?
    @State private var toast: String?

    // MARK: 分组（按前缀：GIT_* / HTTP_* / 其它）

    private func groupKey(_ k: String) -> String {
        if k.hasPrefix("GIT_") { return "Git 凭证（GIT_*）" }
        if k.hasPrefix("HTTP") || k.hasPrefix("HTTPS") || k.hasPrefix("ALL_PROXY") || k.hasPrefix("NO_PROXY") { return "代理（HTTP_*）" }
        return "其它"
    }
    private var groupedKeys: [String] {
        var seen: [String] = []
        for k in store.sortedKeys where !seen.contains(groupKey(k)) { seen.append(groupKey(k)) }
        return seen
    }
    private func keys(in g: String) -> [String] {
        store.sortedKeys.filter { groupKey($0) == g }
    }

    /// 脱敏：ghp_••••••1234（前4+后4，中间打点）；短值全打点
    private func masked(_ v: String) -> String {
        guard v.count > 10 else { return String(repeating: "•", count: 8) }
        return String(v.prefix(4)) + "••••••" + String(v.suffix(4))
    }

    var body: some View {
        List {
            if store.sortedKeys.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal").font(.system(size: 36)).foregroundColor(.secondary)
                        Text("还没有环境变量").font(.footnote).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 32)
                }
            } else {
                ForEach(groupedKeys, id: \.self) { g in
                    Section(header: Text(g)) {
                        ForEach(keys(in: g), id: \.self) { key in
                            envRow(key)
                                .contentShape(Rectangle())
                                .onTapGesture { editValue = store.vars[key] ?? ""; editingKey = key }
                        }
                        .onDelete { idx in
                            for i in idx { store.remove(keys(in: g)[i]) }
                        }
                    }
                }
            }

            Section {
                Button {
                    showingAdd = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle").font(.system(size: 18))
                        Text("新增变量")
                        Spacer()
                    }
                }
            }

            Section(header: Text("说明")) {
                Text("变量会注入到 shell 与 Git 工具。密钥类建议用 GITHUB_TOKEN 命名，git 工具会自动取用，不会出现在对话里。")
                    .font(.caption).foregroundColor(.secondary)
                Text("这些变量会注入：所有子进程（python3/r2/bsdtar…）与进程内 Python。已运行的解释器需重新 eval 才生效。")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .deepseekList()
        .navigationTitle("环境变量")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { exportClipboard() } label: { Label("导出到剪贴板", systemImage: "square.and.arrow.up") }
                    Button { showingAdd = true } label: { Label("新增变量", systemImage: "plus") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            EnvAddSheet(store: store)
        }
        .sheet(item: Binding(
            get: { editingKey.map { IdentifiedEnvKey(id: $0) } },
            set: { if $0 == nil { editingKey = nil } }
        )) { item in
            EnvEditSheet(key: item.id, initialValue: editValue) { newValue in
                store.set(newValue, for: item.id)
            }
        }
        .alert(isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
            Alert(title: Text(L10n.t("ui_100")), message: Text(toast ?? ""), dismissButton: .default(Text(L10n.t("ui_44"))))
        }
    }

    // MARK: 单行（ModelRow 同构）

    private func envRow(_ key: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(key)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(revealed.contains(key) ? (store.vars[key] ?? "") : masked(store.vars[key] ?? ""))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
            } label: {
                Image(systemName: revealed.contains(key) ? "eye.slash" : "eye")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(.vertical, 3)
    }

    /// 导出键值对到剪贴板（值明文——导出即知情，与设置页行为一致）
    private func exportClipboard() {
        let lines = store.sortedKeys.map { "\($0)=\(store.vars[$0] ?? "")" }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        toast = "已复制 \(lines.count) 个变量到剪贴板"
        AuditLog.shared.log("env.export", detail: "\(lines.count) vars")
    }
}

private struct IdentifiedEnvKey: Identifiable {
    let id: String
}

// MARK: 新增弹窗

private struct EnvAddSheet: View {
    @ObservedObject var store: EnvVarsStore
    @Environment(\.presentationMode) var presentationMode
    @State private var key = ""
    @State private var value = ""
    @State private var errorMsg: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("变量名"), footer: Text("名称只能是字母/数字/下划线，且不以数字开头（大小写敏感）。")) {
                    TextField("名称，如 GITHUB_TOKEN", text: $key)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                }
                Section(header: Text("值")) {
                    TextField("值", text: $value)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                }
                if let e = errorMsg {
                    Section {
                        Text(e).font(.caption).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("新增环境变量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            errorMsg = "名称不合法：只能是字母、数字、下划线，且不能以数字开头"
            return
        }
        store.set(value, for: k)
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: 编辑弹窗

private struct EnvEditSheet: View {
    let key: String
    let initialValue: String
    let onSave: (String) -> Void
    @Environment(\.presentationMode) var presentationMode
    @State private var value: String

    init(key: String, initialValue: String, onSave: @escaping (String) -> Void) {
        self.key = key
        self.initialValue = initialValue
        self.onSave = onSave
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(key).font(.system(.caption, design: .monospaced))) {
                    TextField("值", text: $value)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle("编辑变量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        onSave(value)
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}
