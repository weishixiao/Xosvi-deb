import Foundation

/// v7.16.11：卸载即清空数据。
///
/// 背景（真机复现）：TrollStore 覆盖安装 / 重装 tipa 时，iOS **保留** 沙盒 Documents 与
/// UserDefaults，于是「卸载 → 重装」后旧会话、旧 Key、旧工作区全都还在。
/// 用户要的是「卸载即删除所有数据」。
///
/// 做法：在沙盒里放一个「安装标记」，并把它和一组指纹一起记进 Keychain。
///   · Keychain 在 App 被删除后**仍然保留**（这是系统行为，正好当外部见证人）。
///   · App 启动时：沙盒标记存在 + Keychain 指纹匹配 → 正常升级，什么都不做。
///   · 沙盒标记不存在（被卸载清掉了）→ 判定为「全新安装」，清空所有残留数据。
///
/// 只清「本 App 自己的」数据，不碰系统其它 App。
enum FreshInstallReset {

    /// 沙盒内的标记文件（随 App 删除一起消失）
    private static var markerURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(".install-marker")
    }

    /// Keychain 里的见证记录（App 删除后仍保留）
    private static let keychainWitnessKey = "install_witness_v1"

    /// App 启动时调用，尽量靠前（在任何 Store 单例读 UserDefaults 之前）。
    @discardableResult
    static func runIfNeeded() -> Bool {
        let fm = FileManager.default
        let markerExists = fm.fileExists(atPath: markerURL.path)
        let witness = KeychainStore.shared.string(forKey: keychainWitnessKey)

        if markerExists && witness != nil {
            // 正常升级：标记与见证都在
            return false
        }

        if !markerExists && witness == nil {
            // 真正的第一次安装（从来没装过）：不用清，直接写标记
            writeMarker()
            return false
        }

        if !markerExists && witness != nil {
            // 卸载后重装 —— 需要清空
            wipeAllData()
            writeMarker()
            return true
        }

        // marker 在但 witness 没了（Keychain 被清/换了签名证书）：保守处理，
        // 只补写见证，不删用户数据，避免误伤。
        writeMarker()
        return false
    }

    // MARK: - 内部

    private static func writeMarker() {
        let fm = FileManager.default
        let info = """
        created=\(Int(Date().timeIntervalSince1970))
        bundle=\(Bundle.main.bundleIdentifier ?? "?")
        version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        """
        try? info.write(to: markerURL, atomically: true, encoding: .utf8)
        _ = KeychainStore.shared.set(info, forKey: keychainWitnessKey)
        // 标记文件本身不需要备份，也不要被 iCloud 同步
        var u = markerURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
        _ = fm  // 保持引用，避免编译器警告
    }

    /// 清空本 App 的全部数据。调用方已确认是「卸载后重装」。
    private static func wipeAllData() {
        let fm = FileManager.default

        // 1. UserDefaults（会话、模型配置、开关、引导标记……）
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        UserDefaults.standard.synchronize()

        // 2. 沙盒目录：Documents / Library / Application Support / Caches
        let dirs: [FileManager.SearchPathDirectory] = [
            .documentDirectory, .applicationSupportDirectory,
            .libraryDirectory, .cachesDirectory
        ]
        for d in dirs {
            guard let url = fm.urls(for: d, in: .userDomainMask).first else { continue }
            // Documents 里如果放了用户自己导入的文件，也一并清掉——
            // 「卸载即删除所有数据」就是这个语义，用户点了卸载就是要干净。
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                try? fm.removeItem(at: item)
            }
        }

        // 3. Keychain（API Key / token）
        KeychainStore.shared.clearAll()
    }
}
