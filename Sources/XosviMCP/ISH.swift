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
    static var rootfsInstalled: Bool {
        FileManager.default.fileExists(atPath: dataPath)
    }
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
        (try? String(contentsOfFile: dataPath + "/etc/alpine-release", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知"
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

    /// 首次启动或版本变化时解压内置 rootfs（ZIPFoundation，流式 + 路径越界防护）
    @discardableResult
    static func installRootfsIfNeeded(force: Bool = false) throws -> Bool {
        let saved = UserDefaults.standard.string(forKey: rootfsVersionKey)
        if !force, saved == bundledVersion, rootfsInstalled { return false }
        guard let zip = bundledZip else { throw InstallError.noBundle }

        let fm = FileManager.default
        // 已经在 boot 的进程无法换 rootfs（内核不卸载）
        if isBooted && force {
            throw InstallError.failed("内核已启动，无法更换 rootfs。请完全退出 App 后重开再试。")
        }
        try? fm.removeItem(at: installRoot)
        try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)

        guard let archive = Archive(url: zip, accessMode: .read) else {
            throw InstallError.failed("打不开 alpine-rootfs.zip")
        }
        let root = installRoot.path
        for entry in archive {
            let rel = entry.path
            // 路径越界防护（zip slip）
            if rel.hasPrefix("/") || rel.contains("..") {
                throw InstallError.failed("压缩包路径异常：\(rel)")
            }
            let dest = root + "/" + rel
            if entry.type == .directory {
                try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
                continue
            }
            try? fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            var data = Data()
            _ = try archive.extract(entry) { chunk in data.append(chunk) }
            try data.write(to: URL(fileURLWithPath: dest))
            // 保留可执行位
            if entry.type == .file, rel.hasPrefix("bin/") || rel.hasPrefix("sbin/")
                || rel.hasPrefix("usr/bin/") || rel.hasPrefix("usr/sbin/") || rel.hasPrefix("usr/local/bin/") {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
            }
        }
        UserDefaults.standard.set(bundledVersion, forKey: rootfsVersionKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ishInstalledAt")
        return true
    }

    /// 「修复」= 强制重装 rootfs
    static func repair() throws {
        _ = try installRootfsIfNeeded(force: true)
    }

    // MARK: 启动

    private static var bootLock = NSLock()

    /// 幂等 boot；返回 0 = 成功
    @discardableResult
    static func boot() -> Int32 {
        bootLock.lock()
        defer { bootLock.unlock() }
        if isBooted { return 0 }
        do {
            try installRootfsIfNeeded()
        } catch {
            Log.browser("rootfs 安装失败：\(error.localizedDescription)")
            return -2
        }
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)
        let rc = KelivoISHKernel.shared().boot(withRootPath: installRoot.path)
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

