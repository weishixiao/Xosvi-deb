import SwiftUI
import UIKit

/// v6.6.9：「Hax 电脑」——Alpine Linux 沙盒管理面板（移植自 OpenMinis RootfsManagement + FileBrowser）。
///
/// 提供三块能力：
///   1. 环境状态：rootfs 是否就绪、占用空间、引擎开关
///   2. 文件浏览：直接浏览 Alpine 的 /root /home /tmp /etc（fakefs 落盘在 Documents/alpine-rootfs/data）
///   3. 快捷操作：打开终端、重置 rootfs
struct HaxComputerView: View {
    @State private var rootfsInstalled = false
    @State private var rootfsSize: Int64 = 0
    @State private var engineEnabled = UserDefaults.standard.bool(forKey: "alpineEngineEnabled")
    @State private var toast: String?
    @State private var showResetConfirm = false
    @State private var showTerminal = false
    @State private var showPackages = false
    @State private var packagesText = ""
    // v6.6.14：镜像源 / DNS（与 Rootfs 管理页共享逻辑）
    @State private var apkMirror = "USTC"
    @State private var pipMirror = "Alibaba"
    @State private var npmMirror = "npmmirror"
    @State private var dnsMode = "自动"
    @State private var currentDNS = "—"

    private static var rootfsPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("alpine-rootfs").path
    }
    private static var dataPath: String { rootfsPath + "/data" }

    var body: some View {
        List {
            // MARK: 状态
            Section {
                HStack(spacing: 12) {
                    Image(systemName: rootfsInstalled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundColor(rootfsInstalled ? .green : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rootfsInstalled ? "Alpine Linux 已就绪" : "尚未安装 rootfs")
                            .font(.subheadline.weight(.semibold))
                        Text(rootfsInstalled
                             ? "首次打开终端会自动解压并启动内核"
                             : "首次打开终端时会从内置 alpine-rootfs.zip 解压")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)

                if rootfsInstalled && rootfsSize > 0 {
                    HStack {
                        Text("占用空间")
                        Spacer()
                        Text(Self.humanSize(rootfsSize)).foregroundColor(.secondary)
                    }
                }
                Toggle(isOn: $engineEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alpine/iSH 引擎")
                        Text("关闭时终端不可用（arm64 上引擎偶发段错误）")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .onChange(of: engineEnabled) { on in
                    UserDefaults.standard.set(on, forKey: "alpineEngineEnabled")
                    if !on { toast = "引擎已关闭，终端将不可用" }
                }
            } header: {
                Text("环境")
            }

            // MARK: 引擎控制
            Section {
                HStack {
                    Text("内核状态")
                    Spacer()
                    Text(ISHEngine.isBooted ? "已 boot" : "未启动")
                        .foregroundColor(.secondary)
                }
                Button {
                    guard engineEnabled else { toast = "请先开启 Alpine/iSH 引擎"; return }
                    toast = "正在预热内核…"
                    DispatchQueue.global(qos: .userInitiated).async {
                        let err = ISHEngine.ensureBooted()
                        DispatchQueue.main.async {
                            toast = err == nil ? "内核已就绪" : "启动失败：\(err ?? "")"
                        }
                    }
                } label: {
                    Label("预热内核（首次约 5-10 秒）", systemImage: "bolt.fill")
                }
                .disabled(!engineEnabled)

                Button {
                    guard engineEnabled else { toast = "请先开启 Alpine/iSH 引擎"; return }
                    toast = "读取已安装软件包…"
                    DispatchQueue.global(qos: .userInitiated).async {
                        let r = ISHEngine.exec("apk info 2>/dev/null | head -40; echo '---'; pip3 list 2>/dev/null | head -20", timeout: 40)
                        DispatchQueue.main.async {
                            packagesText = r.output.isEmpty ? "（读取失败）" : r.output
                            showPackages = true
                            toast = nil
                        }
                    }
                } label: {
                    Label("查看已安装软件包", systemImage: "list.bullet")
                }
                .disabled(!engineEnabled)
            } header: {
                Text("引擎")
            }

            // MARK: 快捷入口
            Section {
                Button {
                    if !engineEnabled {
                        toast = "请先开启 Alpine/iSH 引擎"
                        return
                    }
                    showTerminal = true
                } label: {
                    Label("打开终端", systemImage: "apple.terminal")
                }

                NavigationLink {
                    AlpineFileBrowserView(rootPath: "/", viaAlpine: true)
                } label: {
                    Label("浏览 Alpine 文件", systemImage: "folder")
                }

                NavigationLink {
                    AlpineFileBrowserView(rootPath: FileManager.default
                        .urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Workspace").path)
                } label: {
                    Label("浏览 iOS 工作区", systemImage: "internaldrive")
                }
            } header: {
                Text("文件")
            }

            // MARK: 镜像源（v6.6.14：从 Rootfs 管理合并过来；v6.9.13 起 Rootfs 页已删除，这里是唯一入口）
            Section {
                Menu {
                    ForEach(["USTC", "Aliyun", "Tsinghua", "Official"], id: \.self) { m in
                        Button(m) { applyMirror("apk", m) }
                    }
                } label: {
                    HStack {
                        Label("Alpine APK", systemImage: "shippingbox.fill").foregroundColor(.primary)
                        Spacer()
                        Text(apkMirror).foregroundColor(.secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                    }
                }
                Menu {
                    ForEach(["Alibaba", "Tsinghua", "USTC", "Official"], id: \.self) { m in
                        Button(m) { applyMirror("pip", m) }
                    }
                } label: {
                    HStack {
                        Label("Python pip", systemImage: "cube.fill").foregroundColor(.primary)
                        Spacer()
                        Text(pipMirror).foregroundColor(.secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                    }
                }
                Menu {
                    ForEach(["npmmirror", "Official"], id: \.self) { m in
                        Button(m) { applyMirror("npm", m) }
                    }
                } label: {
                    HStack {
                        Label("Node.js npm", systemImage: "shippingbox.circle.fill").foregroundColor(.primary)
                        Spacer()
                        Text(npmMirror).foregroundColor(.secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("镜像源")
            } footer: {
                Text("写入 Alpine 的 /etc/apk/repositories、/etc/pip.conf、/root/.npmrc，立即生效。")
                    .font(.caption2)
            }

            // MARK: 容器网络
            Section {
                Menu {
                    Button("自动（223.5.5.5 / 119.29.29.29 / 8.8.8.8）") { applyDNS("自动") }
                    Button("仅国内（223.5.5.5 / 119.29.29.29）") { applyDNS("国内") }
                    Button("仅 Google（8.8.8.8 / 8.8.4.4）") { applyDNS("Google") }
                } label: {
                    HStack {
                        Text("DNS 模式")
                        Spacer()
                        Text(dnsMode).foregroundColor(.secondary)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundColor(.secondary)
                    }
                }
                HStack {
                    Text("当前生效")
                    Spacer()
                    Text(currentDNS).font(.caption).foregroundColor(.secondary)
                }
            } header: {
                Text("容器网络")
            } footer: {
                Text("写 Alpine 的 /etc/resolv.conf。用代理/VPN 时建议保持「自动」。")
                    .font(.caption2)
            }

            // MARK: 危险操作
            Section {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("重置 Linux 环境", systemImage: "arrow.counterclockwise.circle")
                }
                .disabled(!rootfsInstalled)
            } header: {
                Text("维护")
            } footer: {
                Text("重置会删除 Alpine 内安装的所有软件包和用户文件（iOS 工作区不受影响）。重置后请重启 App 让内核重新安装。")
                    .font(.caption2)
            }
        }
        .navigationTitle("Hax 电脑")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .sheet(isPresented: $showTerminal) {
            CompatNav { ISHTerminalView(showCloseButton: true, autoCdRoot: true) }
        }
        .sheet(isPresented: $showPackages) {
            CompatNav {
                ScrollView {
                    Text(packagesText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .navigationTitle("已安装软件包")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .alert("重置 Linux 环境？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) { performReset() }
        } message: {
            Text("将删除 \(Self.rootfsPath) 下的全部内容。此操作不可撤销。")
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.black.opacity(0.78), in: Capsule())
                    .foregroundColor(.white)
                    .padding(.bottom, 28)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { toast = nil }
                    }
            }
        }
    }

    private func refresh() {
        let fm = FileManager.default
        rootfsInstalled = fm.fileExists(atPath: Self.dataPath)
        rootfsSize = Self.directorySize(Self.rootfsPath)
        engineEnabled = UserDefaults.standard.bool(forKey: "alpineEngineEnabled")
        if rootfsInstalled && engineEnabled {
            DispatchQueue.global(qos: .utility).async {
                let dns = RootfsConfig.currentDNSSummary()
                DispatchQueue.main.async { currentDNS = dns }
            }
        }
    }

    // MARK: - 镜像 / DNS（v6.6.14）

    private func applyMirror(_ kind: String, _ name: String) {
        guard RootfsConfig.installed || engineEnabled else {
            toast = "请先开启引擎并安装 rootfs（打开一次终端）"
            return
        }
        let cmd: String
        switch kind {
        case "apk": cmd = RootfsConfig.apkMirrorCommand(name)
        case "pip": cmd = RootfsConfig.pipMirrorCommand(name)
        default:    cmd = RootfsConfig.npmMirrorCommand(name)
        }
        toast = "正在切换…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = ISHEngine.exec(cmd, timeout: 40)
            DispatchQueue.main.async {
                if r.exitCode == 0 {
                    switch kind {
                    case "apk": apkMirror = name
                    case "pip": pipMirror = name
                    default:    npmMirror = name
                    }
                    toast = "已切换：\(name)"
                } else {
                    toast = "失败（退出码 \(r.exitCode)）：\(r.output.prefix(60))"
                }
            }
        }
    }

    private func applyDNS(_ mode: String) {
        guard RootfsConfig.installed || engineEnabled else {
            toast = "请先开启引擎并安装 rootfs"
            return
        }
        toast = "正在设置 DNS…"
        let cmd = RootfsConfig.dnsCommand(mode)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = ISHEngine.exec(cmd, timeout: 30)
            DispatchQueue.main.async {
                if r.exitCode == 0 {
                    dnsMode = mode
                    currentDNS = RootfsConfig.currentDNSSummary()
                    toast = "DNS 已切换：\(mode)"
                } else {
                    toast = "DNS 设置失败（退出码 \(r.exitCode)）"
                }
            }
        }
    }

    private func performReset() {
        do {
            if FileManager.default.fileExists(atPath: Self.rootfsPath) {
                try FileManager.default.removeItem(atPath: Self.rootfsPath)
            }
            toast = "已重置，请重启 App 重新安装环境"
            refresh()
        } catch {
            toast = "重置失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 工具

    private static func directorySize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        guard let en = FileManager.default.enumerator(at: url,
                                                     includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            if let size = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    static func humanSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - Alpine 文件浏览器

/// 简易文件浏览器（浏览 fakefs 落盘目录 / iOS 工作区）。
/// 只读 + 预览 + 删除，不提供写操作（写操作交给终端或 AI 工具）。
struct AlpineFileBrowserView: View {
    let rootPath: String
    /// v6.6.13：通过 guest 列目录。
    /// iSH 的 fakefs **不是**标准目录结构——内容在 data/ 的哈希文件 + meta.db 里，
    /// iOS 侧 FileManager 看不到 Alpine 的真实目录树（浏览 /root 永远是空目录）。
    /// 打开此开关后用 `ls` 在 guest 内列举。
    var viaAlpine: Bool = false

    @State private var currentPath: String
    @State private var items: [Item] = []
    @State private var errorText: String?

    struct Item: Identifiable {
        let url: URL
        let isDir: Bool
        let size: Int64?
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    init(rootPath: String, viaAlpine: Bool = false) {
        self.rootPath = rootPath
        self.viaAlpine = viaAlpine
        _currentPath = State(initialValue: rootPath)
    }

    var body: some View {
        List {
            if let err = errorText {
                Section {
                    Text(err).font(.footnote).foregroundColor(.red)
                }
            }
            if items.isEmpty && errorText == nil {
                Section {
                    Text("（空目录）").foregroundColor(.secondary).font(.footnote)
                }
            } else {
                Section {
                    ForEach(items) { item in
                        if item.isDir {
                            NavigationLink {
                                AlpineFileBrowserView(rootPath: item.url.path, viaAlpine: viaAlpine)
                            } label: {
                                row(item)
                            }
                        } else {
                            row(item)
                        }
                    }
                }
            }
        }
        .navigationTitle((currentPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isDir ? "folder.fill" : "doc.text")
                .foregroundColor(item.isDir ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline).lineLimit(1)
                if let s = item.size {
                    Text(HaxComputerView.humanSize(s))
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    /// v6.6.13：在 guest 内列举目录（fakefs 唯一正确方式）
    private func loadViaAlpine() {
        let quoted = currentPath.replacingOccurrences(of: "'", with: "'\\''")
        // 输出格式：d|0|name  或  f|<bytes>|name
        let cmd = "cd '\(quoted)' 2>/dev/null; for f in * .[!.]*; do [ -e \"$f\" ] || continue; if [ -d \"$f\" ]; then echo \"d|0|$f\"; else echo \"f|$(wc -c < \"$f\" 2>/dev/null || echo 0)|$f\"; fi; done"
        let r = ISHEngine.exec(cmd, timeout: 30)
        if r.exitCode != 0 && r.output.isEmpty {
            items = []
            errorText = "读取失败（引擎未就绪）：\(r.output.prefix(120))"
            return
        }
        var out: [Item] = []
        for line in r.output.components(separatedBy: .newlines) {
            let line2 = line.trimmingCharacters(in: .whitespaces)
            guard !line2.isEmpty else { continue }
            let parts = line2.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            let isDir = parts[0] == "d"
            let size = Int64(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            let name = parts[2]
            if name == "." || name == ".." || name.isEmpty { continue }
            let full = currentPath.hasSuffix("/") ? currentPath + name : currentPath + "/" + name
            out.append(Item(url: URL(fileURLWithPath: full), isDir: isDir, size: isDir ? nil : size))
        }
        items = out.sorted {
            if $0.isDir != $1.isDir { return $0.isDir && !$1.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        errorText = items.isEmpty ? "（目录为空或引擎未启动）" : nil
    }

    private func load() {
        if viaAlpine { loadViaAlpine(); return }
        do {
            let list = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: currentPath),
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            var out: [Item] = []
            for u in list {
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                out.append(Item(url: u, isDir: v?.isDirectory ?? false,
                                size: v?.fileSize.map { Int64($0) }))
            }
            items = out.sorted {
                if $0.isDir != $1.isDir { return $0.isDir && !$1.isDir }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            errorText = nil
        } catch {
            items = []
            errorText = "读取失败：\(error.localizedDescription)"
        }
    }
}
