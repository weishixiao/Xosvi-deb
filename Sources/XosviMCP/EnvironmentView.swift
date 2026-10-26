import SwiftUI
import UIKit

// MARK: - v7.6.0 环境（移植 Kelivo 的 Environment 页）
//
// 三个部分，和 Kelivo 的截图一一对应：
//   · 环境预设：Python / Node.js / Git / SSH / 网络工具 / 压缩工具，可检测与一键安装
//   · 环境：Alpine 版本、大小、架构、状态；浏览文件系统；挂载外部文件夹
//   · 镜像：APK / pip / npm 源 + 测速
//   底部还有「修复」（重新解压 rootfs）

struct EnvironmentView: View {
    @State private var deps: [EnvDependency: Bool?] = [:]   // nil=检测中 / true / false
    @State private var checking = false
    @State private var installing: EnvDependency?
    @State private var booted = false
    @State private var rootfsVersion = ""
    @State private var rootfsSize: Int64 = 0
    @State private var mirrorNote = ""
    @State private var speedRows: [(String, Double)] = []
    @State private var speedTesting = false
    @State private var showMountPicker = false
    @State private var mounts: [(name: String, path: String)] = []
    @State private var toast: String?

    private let apkMirrorKey = "ish.mirror.apk"
    private let pipMirrorKey = "ish.mirror.pip"
    private let npmMirrorKey = "ish.mirror.npm"

    var body: some View {
        List {
            // ── 环境预设 ─────────────────────────────
            Section {
                ForEach(EnvDependency.allCases) { dep in
                    Button {
                        install(dep)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: dep.icon)
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dep.title).font(.system(size: 15))
                                Text(dep.subtitle)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            statusLabel(dep)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Button {
                    checkAll(force: true)
                } label: {
                    Label(checking ? "检测中…" : "刷新工具状态", systemImage: "arrow.clockwise")
                }
                .disabled(checking || installing != nil)
            } header: {
                Text("环境预设")
            } footer: {
                Text("安装到共享沙盒，所有工作区均可使用。点一下即安装（apk add）。")
                    .font(.caption2)
            }

            // ── 环境 ────────────────────────────────
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "cube.box")
                        .font(.system(size: 16)).foregroundColor(.primary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alpine \(rootfsVersion.isEmpty ? "—" : rootfsVersion) (iSH)")
                            .font(.system(size: 15))
                        Text(booted ? "就绪" : "未启动")
                            .font(.system(size: 11.5)).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                row("状态", booted ? "运行中" : (ISH.rootfsInstalled ? "已安装" : "未安装"))
                row("大小", ISH.rootfsSize > 0 ? String(format: "%.2f MB", Double(rootfsSize) / 1048576) : "—")
                row("架构", "arm64 · \(rootfsVersion.isEmpty ? "—" : rootfsVersion)")
                Button {
                    bootNow()
                } label: {
                    Label(booted ? "已启动" : "启动沙盒", systemImage: "play")
                }
                .disabled(booted)
            } header: {
                Text("环境")
            }

            // ── 浏览 ────────────────────────────────
            Section {
                NavigationLink {
                    GuestFilesystemView(path: "/")
                } label: {
                    Label("浏览文件系统", systemImage: "externaldrive")
                }
                Button {
                    showMountPicker = true
                } label: {
                    Label("挂载外部文件夹", systemImage: "folder.badge.plus")
                }
                ForEach(mounts, id: \.path) { m in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundColor(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.name).font(.system(size: 14))
                            Text(m.path).font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("/mounts/\(m.name)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("浏览")
            } footer: {
                Text("挂载后可访问目录会出现在沙盒的 /mounts/<name>，模型与终端都能读写。")
                    .font(.caption2)
            }

            // ── 镜像 ────────────────────────────────
            Section {
                Button {
                    runSpeedTest()
                } label: {
                    Label(speedTesting ? "测速中…" : "检测快速镜像", systemImage: "speedometer")
                }
                .disabled(speedTesting || installing != nil)

                Picker("APK", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: apkMirrorKey) ?? "官方" },
                    set: { v in
                        UserDefaults.standard.set(v, forKey: apkMirrorKey)
                        applyMirror()
                    }
                )) {
                    ForEach(ISH.Mirror.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("pip", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: pipMirrorKey) ?? "官方" },
                    set: { v in
                        UserDefaults.standard.set(v, forKey: pipMirrorKey)
                        applyMirror()
                    }
                )) {
                    ForEach(ISH.Mirror.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("npm", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: npmMirrorKey) ?? "官方" },
                    set: { v in
                        UserDefaults.standard.set(v, forKey: npmMirrorKey)
                        applyMirror()
                    }
                )) {
                    ForEach(ISH.Mirror.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }

                ForEach(speedRows, id: \.0) { row in
                    HStack {
                        Text(row.0).font(.system(size: 14))
                        Spacer()
                        Text(String(format: "%.1fs", row.1))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("镜像")
            } footer: {
                if !mirrorNote.isEmpty {
                    Text(mirrorNote).font(.caption2)
                } else {
                    Text("改源会写入沙盒的 /etc/apk/repositories、/etc/pip.conf、/root/.npmrc。")
                        .font(.caption2)
                }
            }

            // ── 操作 ────────────────────────────────
            Section {
                Button(role: .destructive) {
                    repairRootfs()
                } label: {
                    Label("修复", systemImage: "wrench.and.screwdriver")
                }
            } header: {
                Text("操作")
            } footer: {
                Text("重新校验并修补文件：会重新解压 Alpine rootfs（已装的包会丢失）。需完全退出 App 后重开生效。")
                    .font(.caption2)
            }
        }
        .navigationTitle("环境")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .sheet(isPresented: $showMountPicker) {
            DocumentFolderPicker { url in
                let name = url.lastPathComponent
                    .replacingOccurrences(of: " ", with: "_")
                    .lowercased()
                let rc = ISH.mountExternal(hostPath: url.path, name: name)
                if rc == 0 {
                    mounts.append((name, url.path))
                    saveMounts()
                    toast = "已挂载到 /mounts/\(name)"
                } else {
                    toast = "挂载失败 rc=\(rc)"
                }
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            withAnimation { toast = nil }
                        }
                    }
            }
        }
    }

    // MARK: 行

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.primary)
            Spacer()
            Text(value).foregroundColor(.secondary).font(.system(size: 13))
        }
    }

    @ViewBuilder
    private func statusLabel(_ dep: EnvDependency) -> some View {
        if installing == dep {
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.7)
                Text("安装中").font(.system(size: 12)).foregroundColor(.secondary)
            }
        } else if let ok = deps[dep] {
            if ok == true {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
            } else {
                Text("未安装").font(.system(size: 12)).foregroundColor(.secondary)
            }
        } else {
            Text("—").font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    // MARK: 动作

    private func refresh() {
        booted = ISH.isBooted
        rootfsVersion = ISH.runtimeVersion
        rootfsSize = ISH.rootfsSize
        loadMounts()
        checkAll(force: false)
    }

    private func bootNow() {
        toast = "正在启动…"
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = ISH.boot()
            DispatchQueue.main.async {
                booted = ISH.isBooted
                rootfsVersion = ISH.runtimeVersion
                rootfsSize = ISH.rootfsSize
                toast = rc == 0 ? "沙盒已就绪" : "启动失败 rc=\(rc)"
                checkAll(force: true)
            }
        }
    }

    private func checkAll(force: Bool) {
        guard !checking else { return }
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            // 一次性把 6 个都探一遍，少起几次 shell
            let cmd = EnvDependency.allCases
                .map { "printf '%@=' \($0.rawValue); \($0.probe) >/dev/null 2>&1 && echo ok || echo missing" }
                .joined(separator: "; ")
            let out = ISH.run(cmd, timeout: 40).output
            var result: [EnvDependency: Bool] = [:]
            for line in out.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: "=")
                guard parts.count == 2, let d = EnvDependency(rawValue: parts[0]) else { continue }
                result[d] = parts[1].trimmingCharacters(in: .whitespaces) == "ok"
            }
            DispatchQueue.main.async {
                deps = result
                checking = false
                booted = ISH.isBooted
            }
        }
        _ = force
    }

    private func install(_ dep: EnvDependency) {
        guard installing == nil else { return }
        installing = dep
        DispatchQueue.global(qos: .userInitiated).async {
            let r = ISHEngine.apkAdd(dep.packages.components(separatedBy: " "), timeout: 240)
            DispatchQueue.main.async {
                installing = nil
                if r.exitCode == 0 {
                    deps[dep] = true
                    toast = "\(dep.title) 已安装"
                } else {
                    deps[dep] = false
                    toast = ISHEngine.installDiagnose(r.output, timedOut: r.timedOut, exitCode: r.exitCode)
                }
            }
        }
    }

    private func applyMirror() {
        let apk = UserDefaults.standard.string(forKey: apkMirrorKey) ?? "官方"
        let pip = UserDefaults.standard.string(forKey: pipMirrorKey) ?? "官方"
        let npm = UserDefaults.standard.string(forKey: npmMirrorKey) ?? "官方"
        mirrorNote = "正在写入源配置…"
        DispatchQueue.global(qos: .userInitiated).async {
            if let m = ISH.Mirror(rawValue: apk) { ISH.applyMirror(m) }
            // pip / npm 单独覆盖
            var cmd = ""
            if let m = ISH.Mirror(rawValue: pip) {
                cmd += "mkdir -p /etc/pip; printf '[global]\\nindex-url = \(m.pipHost ?? "")\\n' > /etc/pip.conf; "
            }
            if let m = ISH.Mirror(rawValue: npm) {
                cmd += "printf 'registry=\(m.npmRegistry)\\n' > /root/.npmrc; "
            }
            _ = ISH.run(cmd, timeout: 60)
            DispatchQueue.main.async {
                mirrorNote = "已应用：APK \(apk) · pip \(pip) · npm \(npm)"
            }
        }
    }

    private func runSpeedTest() {
        speedTesting = true
        speedRows = []
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = ISH.speedTest().map { ($0.0.rawValue, $0.1) }
            DispatchQueue.main.async {
                speedRows = rows
                speedTesting = false
                if let best = rows.first { mirrorNote = "最快：\(best.0)（\(String(format: "%.1fs", best.1))）" }
            }
        }
    }

    private func repairRootfs() {
        toast = "正在重装 rootfs…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ISH.repair()
                DispatchQueue.main.async {
                    toast = "已重装，请完全退出 App 后重开"
                    rootfsSize = ISH.rootfsSize
                }
            } catch {
                DispatchQueue.main.async { toast = error.localizedDescription }
            }
        }
    }

    // MARK: 挂载记录

    private func saveMounts() {
        let arr = mounts.map { ["name": $0.name, "path": $0.path] }
        UserDefaults.standard.set(arr, forKey: "ish.mounts")
    }

    private func loadMounts() {
        guard let arr = UserDefaults.standard.array(forKey: "ish.mounts") as? [[String: String]] else { return }
        mounts = arr.compactMap { d in
            guard let n = d["name"], let p = d["path"] else { return nil }
            return (n, p)
        }
    }
}

// MARK: - guest 文件系统浏览

struct GuestFilesystemView: View {
    let path: String
    @State private var entries: [ISH.Entry] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if entries.isEmpty {
                Text("空目录").foregroundColor(.secondary)
            }
            ForEach(entries, id: \.name) { e in
                if e.isDir {
                    NavigationLink {
                        GuestFilesystemView(path: join(path, e.name))
                    } label: {
                        entryRow(e)
                    }
                } else {
                    Button {
                        // 文件：预览文本
                    } label: {
                        entryRow(e)
                    }
                }
            }
        }
        .navigationTitle(path == "/" ? "沙盒根目录" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let list = ISH.listGuest(path)
                DispatchQueue.main.async {
                    entries = list
                    loading = false
                }
            }
        }
    }

    private func entryRow(_ e: ISH.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: e.isDir ? "folder" : "doc")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 22)
            Text(e.name).font(.system(size: 14)).lineLimit(1)
            Spacer()
            if !e.isDir {
                Text(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }
}
