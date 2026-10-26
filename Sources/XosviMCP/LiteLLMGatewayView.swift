import SwiftUI

// MARK: - v7.6.3 LiteLLM 风格模型网关入口
//
// 页面结构对齐 litellm Proxy 的 Admin UI：
//   概览      —— 路由策略 / 重试 / 冷却 / fallback 概览
//   模型组    —— 按 modelName 聚合，下面挂多条 deployment（可多条同名做负载均衡）
//   虚拟密钥  —— vk-litellm-xxx 列表，只在本地生成/展示
//   请求日志  —— 最近调用记录（模型 / 状态 / 耗时 / 估算费用）
//
// 与旧 ModelsView 的差别：旧版把每条配置平铺，新版按 litellm 的
// 「模型组 → deployments」两层组织，并引入路由策略与虚拟密钥概念。

struct LiteLLMGatewayView: View {
    @ObservedObject private var store = LiteLLMStore.shared

    @State private var showAddProvider = false
    @State private var editingEntry: ModelEntry?
    @State private var showAddKey = false
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        List {
            overviewSection
            routingSection
            modelGroupsSection
            virtualKeysSection
            logsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("模型网关")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showAddProvider = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .sheet(isPresented: $showAddProvider) {
            LiteLLMProviderPicker { provider in
                showAddProvider = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    editingEntry = store.newEntry(for: provider)
                }
            }
        }
        .sheet(item: $editingEntry) { entry in
            LiteLLMEntryEditor(entry: entry) { saved in
                store.upsert(saved)
                editingEntry = nil
            } onCancel: {
                editingEntry = nil
            }
        }
        .sheet(isPresented: $showAddKey) {
            LiteLLMNewKeySheet { alias, scope in
                store.addVirtualKey(alias: alias, scope: scope)
                showAddKey = false
            } onCancel: { showAddKey = false }
        }
    }

    // MARK: 概览

    private var overviewSection: some View {
        Section {
            HStack(spacing: 12) {
                statBlock(value: "\(store.groups.count)", label: "模型组", icon: "square.stack.3d.up.fill", color: .blue)
                statBlock(value: "\(store.entries.count)", label: "Deployment", icon: "server.rack", color: .green)
                statBlock(value: "\(store.keys.count)", label: "虚拟密钥", icon: "key.fill", color: .orange)
            }
            .padding(.vertical, 6)

            if let def = store.defaultEntry {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前默认")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(def.litellmModelString)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                    }
                    Spacer()
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                }
            } else {
                Text("尚未配置任何模型。点右上角 ＋ 选择供应商开始。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("概览")
        }
    }

    private func statBlock(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 路由

    private var routingSection: some View {
        Section {
            Picker("路由策略", selection: Binding(
                get: { store.settings.routingStrategy },
                set: { store.settings.routingStrategy = $0; store.save() }
            )) {
                ForEach(RoutingStrategy.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }

            Stepper("失败重试 \(store.settings.numRetries) 次", value: Binding(
                get: { store.settings.numRetries },
                set: { store.settings.numRetries = $0; store.save() }
            ), in: 0...5)

            Stepper("熔断冷却 \(store.settings.cooldownSeconds) 秒", value: Binding(
                get: { store.settings.cooldownSeconds },
                set: { store.settings.cooldownSeconds = $0; store.save() }
            ), in: 10...300, step: 10)

            Toggle("启用 Fallback 降级", isOn: Binding(
                get: { store.settings.fallbacksEnabled },
                set: { store.settings.fallbacksEnabled = $0; store.save() }
            ))

            Toggle("虚拟密钥模式", isOn: Binding(
                get: { store.settings.virtualKeysEnabled },
                set: { store.settings.virtualKeysEnabled = $0; store.save() }
            ))

            Toggle("费用估算", isOn: Binding(
                get: { store.settings.costTracking },
                set: { store.settings.costTracking = $0; store.save() }
            ))
        } header: {
            Text("路由与策略")
        } footer: {
            Text("对齐 LiteLLM Router：同名模型的多条 deployment 按所选策略分摊流量；主模型失败时按 Fallback 链切换。")
                .font(.caption2)
        }
    }

    // MARK: 模型组

    private var modelGroupsSection: some View {
        Section {
            if store.groups.isEmpty {
                Text("还没有模型组")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(store.groups, id: \.self) { groupName in
                let items = store.entries.filter { $0.modelName == groupName }
                let expanded = expandedGroups.contains(groupName)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if expanded { expandedGroups.remove(groupName) }
                        else { expandedGroups.insert(groupName) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(groupName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text("\(items.count) 条 deployment")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if items.contains(where: { $0.isDefault }) {
                            Text("默认")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.blue))
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())

                if expanded {
                    ForEach(items) { entry in
                        entryRow(entry)
                    }
                }
            }
        } header: {
            Text("模型组")
        } footer: {
            Text("一个模型组 = 一个逻辑模型；组内多条 deployment 用于负载均衡与容灾。")
                .font(.caption2)
        }
    }

    private func entryRow(_ entry: ModelEntry) -> some View {
        Button(action: { editingEntry = entry }) {
            HStack(spacing: 10) {
                Circle()
                    .fill((LiteLLMProvider.find(entry.provider)?.color ?? .gray).opacity(0.18))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Text(String(entry.displayBadge.prefix(1)))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(LiteLLMProvider.find(entry.provider)?.color ?? .gray)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(entry.displayBadge)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                        if entry.isDefault {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                        }
                    }
                    Text("\(entry.apiKey.isEmpty ? "无 key" : entry.maskedKey) · w\(entry.weight) · p\(entry.priority)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .buttonStyle(PlainButtonStyle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.remove(entry)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: 虚拟密钥

    private var virtualKeysSection: some View {
        Section {
            if store.keys.isEmpty {
                Text("还没有虚拟密钥")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(store.keys) { key in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(key.alias)
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text("\(key.requestCount) 次")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text(key.token)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Button {
                            UIPasteboard.general.string = key.token
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.vertical, 2)
            }

            Button(action: { showAddKey = true }) {
                Label("新建虚拟密钥", systemImage: "plus.circle")
            }
        } header: {
            Text("虚拟密钥")
        } footer: {
            Text("对齐 LiteLLM Proxy：真实 API Key 只存在本机，对外用 vk 标识调用来源，便于按用途回收。")
                .font(.caption2)
        }
    }

    // MARK: 请求日志

    private var logsSection: some View {
        Section {
            if store.logs.isEmpty {
                Text("暂无请求记录")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(store.logs.prefix(20)) { log in
                HStack(spacing: 8) {
                    Circle()
                        .fill(log.ok ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(log.modelString)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        Text(Self.timeFormatter.string(from: log.date))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1fs", log.duration))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        if store.settings.costTracking {
                            Text(String(format: "$%.5f", log.cost))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                    }
                }
            }
        } header: {
            Text("最近请求")
        } footer: {
            if !store.logs.isEmpty {
                Text("仅保留本机最近 \(store.settings.logRetention) 条，不上传。")
                    .font(.caption2)
            }
        }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 供应商选择

struct LiteLLMProviderPicker: View {
    var onPick: (LiteLLMProvider) -> Void
    @Environment(\.presentationMode) private var presentationMode
    @State private var search = ""

    private var filtered: [LiteLLMProvider] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return LiteLLMProvider.all }
        return LiteLLMProvider.all.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationView {
            List(filtered) { p in
                Button {
                    onPick(p)
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(p.color.opacity(0.18))
                            .frame(width: 34, height: 34)
                            .overlay(
                                Text(String(p.name.prefix(1)))
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(p.color)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                            Text(p.id)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .listStyle(.plain)
            .navigationTitle("选择供应商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 新建虚拟密钥

struct LiteLLMNewKeySheet: View {
    @State private var alias = ""
    @State private var scope = ""
    var onDone: (String, String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建虚拟密钥")
                .font(.system(size: 17, weight: .semibold))
            TextField("用途（如：手机端）", text: $alias)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            TextField("限定模型组（留空=全部）", text: $scope)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            HStack(spacing: 12) {
                Button("取消") { onCancel() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
                Button("生成") { onDone(alias.isEmpty ? "未命名" : alias, scope) }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundColor(.white)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
            }
            .font(.system(size: 15, weight: .medium))
            .buttonStyle(PlainButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}
