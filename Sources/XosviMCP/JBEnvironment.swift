import Foundation
import Darwin

/// v6.6.10：越狱环境检测与路径解析。
///
/// Xosvi 原本按 TrollStore（免越狱）设计，提权走 persona spawn（posix_spawnattr_set_persona_np）。
/// 但在**越狱设备**上这条路径有三处不适配：
///   1. rootHide/Relaxin 会拦截 persona spawn → 返回 85 (ENOSYS)，与"未授权"无关
///   2. 越狱环境不需要 persona —— 越狱的 amfid 已绕过签名校验，setuid 位直接生效
///   3. rootHide 把 /var/jb 重定向，未注入 libroot 的进程看不到越狱路径
///
/// 本文件提供统一的环境判定，供 runAsRoot / diagnoseRootChain / Node 等选择正确提权路径。
enum JBEnvironment {

    enum Kind: String {
        case none       = "none"        // 未越狱（纯 TrollStore）
        case rootless   = "rootless"    // 标准 rootless 越狱（Dopamine 1.x / palera1n rootless）
        case rootHide   = "rootHide"    // rootHide / Relaxin（隐藏式，路径重定向）
    }

    // MARK: - 缓存（进程生命周期内不变）

    private static let _kind: Kind = detectKind()
    private static let _rootPrefix: String = detectRootPrefix()

    static var kind: Kind { _kind }
    static var isJailbroken: Bool { _kind != .none }
    /// 越狱根前缀：越狱环境返回 "/var/jb"，否则返回 ""
    static var rootPrefix: String { _rootPrefix }

    /// 是否为 rootHide/Relaxin 类型（persona spawn 必然失败）
    static var isRootHide: Bool { _kind == .rootHide }

    // MARK: - 检测

    private static func detectKind() -> Kind {
        let fm = FileManager.default

        // ① 已加载的 dylib 是最可靠信号（rootHide 会向被授权进程注入 libroot/libjbclient）
        if loadedImageContains("libroot.dylib") { return .rootHide }
        if loadedImageContains("libjbclient") { return .rootless }
        if loadedImageContains("libsubstrate") || loadedImageContains("ElleKit") { return .rootless }

        // ② 文件系统路径
        if fm.fileExists(atPath: "/var/jb/.installed_roothide")
            || fm.fileExists(atPath: "/var/jb/usr/lib/libroot.dylib") {
            return .rootHide
        }
        if fm.fileExists(atPath: "/var/jb/usr/lib/libjbclient.dylib")
            || fm.fileExists(atPath: "/var/jb/basebin/jbctl")
            || fm.fileExists(atPath: "/var/jb/Applications/Sileo.app") {
            return .rootless
        }
        // ③ 通用 rootless 标志
        if fm.fileExists(atPath: "/var/jb") || fm.fileExists(atPath: "/private/preboot/jb") {
            return .rootless
        }
        return .none
    }

    private static func detectRootPrefix() -> String {
        switch _kind {
        case .none: return ""
        case .rootless, .rootHide: return "/var/jb"
        }
    }

    /// v6.6.10：不依赖 _dyld_image_count / _dyld_get_image_name（需要 import MachO，
    /// 且在本项目 iOS 15 目标下符号可见性不稳定），改用 dlsym 探测越狱库导出的符号。
    /// - rootHide 的 libroot 导出 rootfs_get_path / jbclient_* 系列
    /// - 标准 rootless 的 libjbclient 导出 jbclient_rootfs_jb
    /// - ElleKit / Substrate 导出 MSHookFunction / MSGetImageByName
    private static func loadedImageContains(_ needle: String) -> Bool {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        let probes: [String]
        if needle.contains("root") {
            probes = ["rootfs_get_path", "jbclient_rootfs_jb", "jbclient_jbrand"]
        } else if needle.contains("jbclient") {
            probes = ["jbclient_rootfs_jb", "jbclient_jbrand"]
        } else {
            probes = ["MSHookFunction", "MSGetImageByName"]
        }
        // String 变量不能直接传给 dlsym（需要 UnsafePointer<CChar>）
        for sym in probes {
            let found = sym.withCString { dlsym(handle, $0) }
            if found != nil { return true }
        }
        return false
    }

    // MARK: - 越狱 root 工具探测

    /// 判断某个越狱工具是否存在（自动加 /var/jb 前缀）
    static func jbToolExists(_ relative: String) -> Bool {
        guard isJailbroken else { return false }
        return FileManager.default.fileExists(atPath: rootPrefix + relative)
    }

    /// 越狱环境的提权入口（按优先级）。
    ///
    /// 越狱设备上这些二进制通常已是 root:wheel + setuid，普通 App 直接 posix_spawn
    /// 即可获得 uid=0 —— 完全不需要 persona spawn。
    /// 返回 nil 表示没有可用的越狱提权工具（此时只能靠自身 helper 的 setuid 位）。
    static func rootLaunchPath() -> String? {
        guard isJailbroken else { return nil }
        // v6.6.13：扩大探测范围——不同越狱管理器放的位置差异很大
        let candidates = [
            "/usr/bin/sudo",                  // Dopamine / palera1n
            "/usr/libexec/sudo",
            "/bin/sudo",
            "/usr/bin/su",
            "/bin/su",
            "/usr/bin/doas",
            "/basebin/jbctl",                 // rootHide
            "/usr/libexec/jbctl",
            "/basebin/launchctl",
            "/usr/bin/launchctl",
            "/usr/libexec/sudo/sudo",
            "/usr/bin/sudoedit",
        ]
        for rel in candidates {
            let p = rootPrefix + rel
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// v6.6.13：越狱工具链完整性快照——诊断用。
    /// 用于区分"越狱激活但工具链不全"和"越狱没真正激活"。
    static func toolchainSnapshot() -> [String: Any] {
        let fm = FileManager.default
        let probes: [(String, String)] = [
            ("jb_root",            "/var/jb"),
            ("sileo",              "/var/jb/Applications/Sileo.app"),
            ("zebra",              "/var/jb/Applications/Zebra.app"),
            ("newterm",            "/var/jb/Applications/NewTerm.app"),
            ("openssh_sshd",       "/var/jb/usr/sbin/sshd"),
            ("dropbear",           "/var/jb/usr/sbin/dropbear"),
            ("apt",                "/var/jb/usr/bin/apt"),
            ("dpkg",               "/var/jb/usr/bin/dpkg"),
            ("filza",              "/var/jb/Applications/Filza.app"),
        ]
        var found: [String: Bool] = [:]
        for (name, path) in probes { found[name] = fm.fileExists(atPath: path) }
        return ["probes": found, "root_prefix": rootPrefix]
    }

    /// v6.6.13：helper 属主诊断——setuid 只对 **root 属主** 的文件生效。
    /// 若 helper 属主是 33(_www)/501(mobile)，即使 chmod u+s 也不会提权到 root。
    static func helperOwnerReport(_ binDir: String) -> [String: Any] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: binDir) else {
            return ["error": "无法读取 \(binDir)"]
        }
        var rootOwned = 0, mobileOwned = 0, otherOwned = 0, setuidCount = 0, total = 0
        var samples: [String] = []
        for n in names where !n.hasPrefix(".") {
            let p = binDir + "/" + n
            guard let attrs = try? fm.attributesOfItem(atPath: p) else { continue }
            total += 1
            let uid = (attrs[.ownerAccountID] as? Int) ?? -1
            let mode = (attrs[.posixPermissions] as? Int) ?? 0
            if (mode & 0o4000) != 0 { setuidCount += 1 }
            switch uid {
            case 0:   rootOwned += 1
            case 501: mobileOwned += 1
            default:
                otherOwned += 1
                if samples.count < 5 { samples.append("\(n): uid=\(uid) mode=\(String(mode, radix: 8))") }
            }
        }
        return [
            "total": total,
            "root_owned": rootOwned,
            "mobile_owned": mobileOwned,
            "other_owned": otherOwned,
            "setuid": setuidCount,
            "samples": samples,
            "verdict": rootOwned == 0
                ? "没有一个是 root 属主 —— setuid 无法提权，必须 chown root:wheel 先"
                : "有 root 属主文件，补齐 setuid 即可提权"
        ]
    }

    /// 越狱环境下 helper 是否具备 root 能力
    /// - 越狱的 amfid 已绕过签名校验，判定只看 setuid 位 + owner
    static func helperIsPrivileged(_ path: String) -> (ok: Bool, reason: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return (false, "文件不存在")
        }
        let mode = (attrs[.posixPermissions] as? Int) ?? 0
        let uid = (attrs[.ownerAccountID] as? Int) ?? -1
        let hasSetuid = (mode & 0o4000) != 0
        let rootOwned = (uid == 0)
        if isJailbroken {
            if hasSetuid && rootOwned { return (true, "越狱环境：setuid + root 属主，可直接提权") }
            if hasSetuid { return (true, "setuid 已置但属主非 root（uid=\(uid)），可能仍可提权") }
            return (false, "缺 setuid 位（越狱环境需 chown root:wheel + chmod u+s）")
        }
        // 非越狱：TrollStore 的 TSRootBinaries 会给 setuid，但实际提权靠 persona
        return (hasSetuid, hasSetuid ? "setuid 已置" : "无 setuid（TrollStore 未应用 TSRootBinaries）")
    }

    /// 给用户的可复制修复命令（在越狱终端 NewTerm/Filza 里以 root 执行）
    static func privilegeFixCommand(appPath: String) -> String {
        let bin = appPath.hasSuffix("/") ? appPath + "bin" : appPath + "/bin"
        return """
        chown -R root:wheel "\(bin)"
        chmod 755 "\(bin)"/*
        chmod u+s "\(bin)"/*
        """
    }
}
