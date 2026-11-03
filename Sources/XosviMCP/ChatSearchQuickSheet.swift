import SwiftUI

// MARK: - v9：聊天页「联网搜索」快速切换（移植 Kelivo search_settings_sheet）
//
// 搜索不是设置里的死配置——聊天时能临时换一家。
// 入口在输入框工具行（放大镜胶囊），半屏弹层里列当前所有服务商 + 跳设置。

struct ChatSearchQuickSheet: View {
    @ObservedObject private var cfg = SearchSettings.shared
    @Environment(\.presentationMode) private var presentationMode

    var onDone: () -> Void
    /// 跳到完整设置页（外层负责 push/sheet）
    var onOpenSettings: () -> Void = {}

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(Array(cfg.services.enumerated()), id: \.element.id) { i, s in
                        Button {
                            cfg.select(id: s.id)
                            onDone()
                            presentationMode.wrappedValue.dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.displayName).foregroundColor(.primary)
                                    HStack(spacing: 6) {
                                        if let ok = cfg.connection[s.id] {
                                            Text(ok ? "已连接" : "失败")
                                                .font(.system(size: 10.5, weight: .medium))
                                                .foregroundColor(ok ? .green : .orange)
                                        } else {
                                            Text("未测试")
                                                .font(.system(size: 10.5))
                                                .foregroundColor(.secondary)
                                        }
                                        if s.supportsReader {
                                            Text("可读全文")
                                                .font(.system(size: 10.5))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                                if i == cfg.selectedIndex {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(DoubaoTheme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                } header: {
                    Text("本次使用")
                } footer: {
                    Text("失败会自动回退到其它可用引擎；免费引擎（必应 / DuckDuckGo）无需 Key。")
                        .font(.caption2)
                }

                Section {
                    HStack {
                        Text("网页读取").foregroundColor(.primary)
                        Spacer()
                        Text(cfg.webFetchModeLabel)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("读取方式")
                }

                Section {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpenSettings() }
                    } label: {
                        Label("搜索设置", systemImage: "gearshape")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .deepseekList()
            .navigationTitle("联网搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheetDetentsMedium()
    }
}

extension View {
    /// 半屏（iOS16+；iOS15 忽略）
    @ViewBuilder
    func sheetDetentsMedium() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium, .large])
        } else {
            self
        }
    }
}
