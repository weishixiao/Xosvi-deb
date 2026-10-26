import Foundation
import ISHBridge
import ZIPFoundation
import UIKit

// MARK: - v7.6.0 Linux 沙盒（移植自 Kelivo 的 iSH 集成）
//
// 本项目原来的 iSH 是早期构建，在 arm64 上反复段错误，上一轮被整体删掉。
// 这一版把 Kelivo 的沙盒移植过来——它的桥接层带崩溃保护（KelivoISHCrashGuards），
// 在真机上能正常跑 Alpine 3.21.3。
//
// 组成：
//   · Sandbox/build_ish.sh         → 编译 libish.a / libish_emu.a / libfakefs.a
//   · Sandbox/prepare_alpine_rootfs.sh → 生成 alpine-rootfs.zip
//   · Sources/ISHBridge/           → ObjC 桥接（kernel / executor / filesystem / mounts）
//   · 本文件                        → Swift 门面：装 rootfs、boot、执行命令、挂载
//
// 运行时布局：Application Support/ish-rootfs/{data, ...}，版本变化会自动重装。

enum ISH {

    static let rootfsVersionKey = "ishRootfsVersion"
    /// 与 Sandbox/resources/VERSION 对应；改 rootfs 内容时同步 bump
    static let bundledVersion = "alpine-3.21.3-r5"

    // MARK: 路径

    static var installRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ish-rootfs", isDirectory: true)
    }
    static var dataPath: String { installRoot.appendingPathComponent("data").path }

    static var bundledZip: URL? {
        Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip")
    }

    // MARK: 状态

    static var isBooted: Bool { KelivoISHKernel.shared().isBooted }
    static var rootfsInstalled: Bool { isRootfsValid() }
    /// rootfs 占了多少空间
    static var rootfsSize: Int64 {
        guard rootfsInstalled else { return 0 }
        var total: Int64 = 0
        let fm = FileManager.default
        if let en = fm.enumerator(at: URL(fileURLWithPath: dataPath),
                                  includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en {
                let s = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(s)
            }
        }
        return total
    }
    static var runtimeVersion: String {
        let p = dataPath + "/etc/alpine-release"
        if let s = try? String(contentsOfFile: p, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        // 兜底：读安装时写的 VERSION 资源
        if let v = try? String(contentsOf: installRoot.appendingPathComponent(".version"), encoding: .utf8) {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return "未知"
    }

    // MARK: 安装 rootfs

    enum InstallError: LocalizedError {
        case noBundle
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noBundle: return "安装包里没有 alpine-rootfs.zip"
            case .failed(let m): return m
            }
        }
    }

    /// 首次启动或版本变化时解压内置 rootfs。
    ///
    /// v7.12.0（对齐 Kelivo RootfsInstaller，修 boot rc=-22）：
    ///   · zip 里的路径带 `alpine-rootfs/` 前缀，必须 strip 掉——否则 meta.db 和 data/
    ///     会被多套一层目录，内核 mount_root 找不到 meta.db → EINVAL(-22)
    ///   · 先解压到 staging，**校验 meta.db + data/bin/sh 都是常规文件**才提交，
    ///     避免半成品目录留在正式位置（下次启动会误判"已安装"）
    @discardableResult
    static func installRootfsIfNeeded(force: Bool = false) throws -> Bool {
        let saved = UserDefaults.standard.string(forKey: rootfsVersionKey)
        if !force, saved == bundledVersion, isRootfsValid() { return false }
        guard let zip = bundledZip else { throw InstallError.noBundle }

        let fm = FileManager.default
        if isBooted {
            // 内核已启动无法换 rootfs（fakefs 不卸载）
            throw InstallError.failed("内核已启动，无法更换 rootfs。请完全退出 App 后重开再试。")
        }

        let parent = installRoot.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("ish-rootfs.staging-\(UUID().uuidString)")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        guard let archive = Archive(url: zip, accessMode: .read) else {
            throw InstallError.failed("打不开 alpine-rootfs.zip")
        }

        let destBase = staging.standardizedFileURL.path
        var written = 0
        var failed = 0
        // Kelivo 的 WorkspaceZipArchive 是先把条目读进内存再解压；
        // ZIPFoundation 的迭代器共享底层句柄，必须在循环外先快照，不能边迭代边 extract。
        let entries = Array(archive)
        for entry in entries {
            var rel = entry.path
            // 关键：剥掉打包前缀
            for prefix in ["alpine-rootfs/", "ish-rootfs/"] where rel.hasPrefix(prefix) {
                rel = String(rel.dropFirst(prefix.count))
            }
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            if rel.isEmpty { continue }
            if rel.contains("..") { continue }          // 越界条目直接跳过

            let destURL = staging.appendingPathComponent(rel).standardizedFileURL
            guard destURL.path == destBase || destURL.path.hasPrefix(destBase + "/") else { continue }

            if entry.type == .directory {
                try? fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                continue
            }
            let parentDir = destURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            var data = Data()
            do {
                _ = try archive.extract(entry) { data.append($0) }
            } catch {
                failed += 1
                continue
            }
            if (try? data.write(to: destURL)) != nil { written += 1 } else { failed += 1 }
            // 可执行位（fakefs 主要靠 meta.db，但补上更稳）
            if rel.hasPrefix("bin/") || rel.hasPrefix("sbin/") || rel.hasPrefix("usr/bin/")
                || rel.hasPrefix("usr/sbin/") || rel.hasPrefix("usr/local/bin/") {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)
            }
        }

        // 校验：meta.db 与 data/bin/sh 必须是常规文件
        func isRegular(_ path: String) -> Bool {
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        let metaOK = isRegular(staging.appendingPathComponent("meta.db").path)
        let shOK = isRegular(staging.appendingPathComponent("data/bin/sh").path)
        guard metaOK, shOK else {
            let listing = (try? fm.contentsOfDirectory(atPath: staging.path).prefix(8).joined(separator: ", ")) ?? "?"
            try? fm.removeItem(at: staging)
            throw InstallError.failed("rootfs 解压不完整：条目 \(entries.count)，写入 \(written)，失败 \(failed)；meta.db=\(metaOK)·data/bin/sh=\(shOK)；顶层：\(listing)")
        }

        // 提交：换掉旧目录
        try? fm.removeItem(at: installRoot)
        do {
            try fm.moveItem(at: staging, to: installRoot)
        } catch {
            try? fm.removeItem(at: staging)
            throw InstallError.failed("无法写入 rootfs 目录：\(error.localizedDescription)")
        }

        UserDefaults.standard.set(bundledVersion, forKey: rootfsVersionKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ishInstalledAt")
        return true
    }

    /// rootfs 是否完整可用（不只看目录存在）
    static func isRootfsValid() -> Bool {
        let fm = FileManager.default
        for probe in ["meta.db", "data/bin/sh"] {
            let path = installRoot.appendingPathComponent(probe).path
            let regular = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            if !regular { return false }
        }
        return fm.fileExists(atPath: installRoot.path)
    }

    /// 「修复」= 强制重装 rootfs
    static func repair() throws {
        _ = try installRootfsIfNeeded(force: true)
    }

    // MARK: 启动

    private static var bootLock = NSLock()
    /// 最近一次 boot/安装的错误（UI 直接显示，不再只给一个 rc 数字）
    nonisolated(unsafe) static var lastError: String?

    /// 幂等 boot；返回 0 = 成功
    @discardableResult
    static func boot() -> Int32 {
        bootLock.lock()
        defer { bootLock.unlock() }
        lastError = nil
        if isBooted { return 0 }
        do {
            try installRootfsIfNeeded()
        } catch {
            lastError = "rootfs 安装失败：\(error.localizedDescription)"
            Log.browser(lastError ?? "")
            return -2
        }
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)
        let rc = KelivoISHKernel.shared().boot(withRootPath: installRoot.path)
        if rc != 0 {
            lastError = "内核启动返回 rc=\(rc)（rootfs: meta.db=\(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("meta.db").path)), data=\(FileManager.default.fileExists(atPath: dataPath))）"
        }
        Log.browser("ISH boot rc=\(rc)")
        return rc
    }

    // MARK: 执行命令

    struct RunResult {
        var output: String
        var exitCode: Int32
        var timedOut: Bool
    }

    /// 同步执行（内部用信号量等回调；调用方应在后台线程）
    static func run(_ command: String,
                    timeout: Double = 30,
                    cwd: String? = "/root",
                    env: [String: String]? = nil) -> RunResult {
        if boot() != 0 {
            return RunResult(output: "沙盒启动失败（rootfs 未就绪或内核出错）", exitCode: -2, timedOut: false)
        }
        var out = Data()
        let sem = DispatchSemaphore(value: 0)
        var result: RunResult?

        _ = KelivoISHExecutor.startCommand(
            command,
            runId: UUID().uuidString,
            binds: [],
            cwd: cwd,
            env: env,
            timeoutMs: Int(timeout * 1000),
            keepStdinOpen: false,
            started: {},
            chunk: { _, _, data in
                out.append(data)
            },
            done: { dict in
                let code = (dict["exitCode"] as? NSNumber)?.int32Value ?? -1
                let timedOut = (dict["timedOut"] as? NSNumber)?.boolValue ?? false
                result = RunResult(output: String(data: out, encoding: .utf8) ?? "",
                                   exitCode: code, timedOut: timedOut)
                sem.signal()
            })

        if sem.wait(timeout: .now() + timeout + 10) == .timedOut {
            return RunResult(output: String(data: out, encoding: .utf8) ?? "", exitCode: -1, timedOut: true)
        }
        return result ?? RunResult(output: String(data: out, encoding: .utf8) ?? "", exitCode: -1, timedOut: false)
    }

    // MARK: 挂载外部文件夹

    /// 把 iOS 上的目录挂到 guest 的 /mounts/<name>
    @discardableResult
    static func mountExternal(hostPath: String, name: String, readOnly: Bool = false) -> Int32 {
        if boot() != 0 { return -2 }
        let guest = "/mounts/\(name)"
        // 先建目录（在真实 fs 上）
        _ = run("mkdir -p '\(guest)'", timeout: 10)
        return KelivoISHKernel.shared().bindMountPath(guest, toHostPath: hostPath, readOnly: readOnly)
    }

    static func unmountExternal(name: String) -> Int32 {
        KelivoISHKernel.shared().bindUnmountPath("/mounts/\(name)")
    }

    // MARK: 镜像源（见 EnvironmentCore.swift 的 MirrorCatalog）

    // MARK: 文件系统浏览

    struct Entry {
        var name: String
        var isDir: Bool
        var size: Int64
    }

    /// 列 guest 里的目录（借 `ls` 输出，避免跨内核直接读 fakefs）
    static func listGuest(_ path: String) -> [Entry] {
        let r = run("ls -la --time-style=+ '\(path)' 2>/dev/null", timeout: 15)
        var out: [Entry] = []
        for line in r.output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 8, let first = parts.first, first.count >= 10 else { continue }
            let isDir = first.hasPrefix("d")
            let name = parts[7...].joined(separator: " ")
            if name == "." || name == ".." { continue }
            let size = Int64(parts[4]) ?? 0
            out.append(Entry(name: name, isDir: isDir, size: size))
        }
        return out.sorted { $0.isDir && !$1.isDir }
    }

    static func readGuestFile(_ path: String, maxBytes: Int = 200_000) -> String? {
        let r = run("cat '\(path)' 2>/dev/null | head -c \(maxBytes)", timeout: 20)
        return r.output.isEmpty ? nil : r.output
    }
}

// MARK: - v7.14.4：Log 命名空间
// ISH 桥接里用的是 Log.browser(...)，但全仓没有定义（CI 报 cannot find 'Log' in scope）。
// 这里补一个最小实现：同时写审计日志（设置 → 日志可见）和系统日志（log_query 可抓）。
enum Log {
    static func browser(_ message: String) {
        AuditLog.shared.log("ish", detail: message)
        NSLog("[ISH] %@", message)
    }
}
