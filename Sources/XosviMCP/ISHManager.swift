import Foundation
// v7.3.0：iSH/Alpine 运行时已整体移除（arm64 真机上反复段错误闪退）。
// 这里保留一个**空壳** ISHEngine：所有调用一律返回"不可用"，不再链接 CISH / 不再解压 rootfs。
// 好处：其它工具（db/file/package/tool.install/shell 等）的调用点无需大改，也不会再有引擎崩溃。
// 原文实现保留在 git 历史（v7.2.1 之前），需要时可用 git show 取回。

enum ISHEngine {
    // MARK: - 状态（恒定：未启用）

    static var autoBindEnabled = false
    static var isBooted: Bool { false }
    static var requiresRelaunch: Bool { false }
    static var cwd: String { FileManager.default.currentDirectoryPath }

    static func interruptCurrent() {}
    static func resetCwd() {}
    static func resetRuntimeState() {}

    struct BindResult {
        var ok: Bool
        var mountPath: String?
        var hostPath: String?
        var error: String?
    }

    static func resetRootfs() -> (ok: Bool, message: String, rootfsExists: Bool) {
        (false, Self.removedMessage, false)
    }

    static func rootfsInfo() -> [String: Any] {
        ["removed": true, "message": Self.removedMessage]
    }

    static func bindAppContainer(bundleId: String, readOnly: Bool = true) -> BindResult {
        BindResult(ok: false, mountPath: nil, hostPath: nil, error: Self.removedMessage)
    }

    /// 命令执行：不再有任何运行时（签名保持与原实现一致，含 TimeInterval）
    static func exec(_ command: String, timeout: TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool) {
        (Self.removedMessage, 127, false)
    }

    /// apk 安装：包管理器随引擎一起移除
    static func apkAdd(_ packages: [String], timeout: Double, onLine: ((String) -> Void)? = nil)
        -> (output: String, exitCode: Int32, timedOut: Bool) {
        (Self.removedMessage, 127, false)
    }

    static func installDiagnose(_ output: String, timedOut: Bool, exitCode: Int32) -> String {
        Self.removedMessage
    }

    /// 路径改写：没有 guest 了，原样返回
    static func autoBind(_ command: String) -> String { command }

    static let removedMessage = """
    Alpine/iSH 运行时已从本版本移除（它在 arm64 真机上会段错误闪退）。
    可用的原生替代：ls / cat / stat / find / du / grep / sed / wc / plutil / sqlite3 /
    strings / nm / hexdump / objdump / python3（内置原生 ARM64）/ bsdtar（tar/zip/gzip）。
    apk add / git clone 这类依赖包管理器或 fork() 的操作已无可用路径。
    """
}
