import SwiftUI
import UIKit

// MARK: - v7.5.0 工作区设置（移植 Kelivo 的 workspace）
//
// 本项目没有 Linux 沙盒（iSH 已移除），所以工作区是纯原生的：
// 绑定一个目录，模型就能在其中执行命令、读写文件、查找内容。

struct WorkspaceSettingsView: View {
    @ObservedObject private var store = WSStore()
    @State private var showPicker = false
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "folder")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前工作区")
                            .font(.system(size: 15))
                        Text(store.root)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                Button {
                    showPicker = true
                } label: {
                    Label("选择文件夹", systemImage: "folder.badge.plus")
                }
                if store.boundRoot != nil {
                    Button(role: .destructive) {
                        WorkspaceStore.shared.bind(nil)
                        store.refresh()
                        toast = "已恢复默认工作区"
                    } label: {
                        Label("恢复默认（App 工作区）", systemImage: "arrow.uturn.backward")
                    }
                }
            } header: {
                Text("绑定目录")
            } footer: {
                Text("模型只能在这个目录里读写文件。默认是 App 沙盒内的 Workspace 文件夹。")
                    .font(.caption2)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { WorkspaceStore.shared.enabled },
                    set: { WorkspaceStore.shared.enabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用工作区工具")
                        Text("关闭后模型看不到 workspace 工具")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Toggle(isOn: Binding(
                    get: { WorkspaceStore.shared.fullAccess },
                    set: { WorkspaceStore.shared.fullAccess = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("完全访问")
                        Text("允许读写工作区之外的路径、执行任意命令")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("权限")
            } footer: {
                Text("默认只允许工作区内操作。开启完全访问后模型能读写整个 App 沙盒，风险自负。")
                    .font(.caption2)
            }

            Section {
                ForEach(Self.toolRows, id: \.0) { row in
                    HStack(spacing: 10) {
                        Image(systemName: row.2)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.0).font(.system(size: 14))
                            Text(row.1).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            } header: {
                Text("可用工具")
            } footer: {
                Text("与 Kelivo 的 workspace 对齐。没有 Linux 沙盒——命令走 App 内置的原生工具链（busybox / python3 / bsdtar 等）。")
                    .font(.caption2)
            }
        }
        .navigationTitle("工作区")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            DocumentFolderPicker { url in
                WorkspaceStore.shared.bind(url.path)
                store.refresh()
                toast = "已绑定：\(url.lastPathComponent)"
            }
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .foregroundColor(.white)
                    .padding(.bottom, 24)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            withAnimation { toast = nil }
                        }
                    }
            }
        }
    }

    static let toolRows: [(String, String, String)] = [
        ("shell", "执行命令（内置原生工具链）", "terminal"),
        ("read_file", "读文件，带行号", "doc.text"),
        ("write_file", "写文件，自动建目录", "square.and.pencil"),
        ("edit_file", "精确替换一段内容（必须唯一命中）", "pencil.line"),
        ("list_dir", "列目录", "list.bullet"),
        ("glob", "按通配符找文件（**/*.swift）", "magnifyingglass"),
        ("grep", "按正则搜内容", "text.magnifyingglass"),
        ("view_image", "把图片返回给模型看", "photo"),
    ]
}

/// 观察 WorkspaceStore 的小包装（WorkspaceStore 不是 ObservableObject）
final class WSStore: ObservableObject {
    @Published var root: String = WorkspaceStore.shared.root
    @Published var boundRoot: String? = WorkspaceStore.shared.boundRoot
    func refresh() {
        root = WorkspaceStore.shared.root
        boundRoot = WorkspaceStore.shared.boundRoot
    }
}

/// 目录选择器（UIDocumentPicker 选文件夹）
struct DocumentFolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    @Environment(\.presentationMode) private var presentation

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentFolderPicker
        init(_ parent: DocumentFolderPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let u = urls.first else { return }
            _ = u.startAccessingSecurityScopedResource()
            // 复制书签以便后续访问（App 重启后仍可用）
            if let data = try? u.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(data, forKey: "workspace.bookmark")
            }
            parent.onPick(u)
        }
    }
}
