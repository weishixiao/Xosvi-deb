import Foundation

// MARK: - v4.1.0/v4.2.0 按需选择性绑定 App 数据容器
/// 把指定 App 的数据容器绑进 Alpine（/ios_data_<app>），让 Alpine python3/sqlite3/strings
/// 直接读写该 App 的 Documents / Library（内购票据、购买状态等）。
/// 与整棵 /var/mobile 绑定不同：只绑目标 App 容器路径、绝不绑自身容器(rootfs)，
/// 因此无自引用 → 无内核污染 → 不崩溃。
///
/// v4.2.0 双模式：
/// - bind_app（只读）：分析用。AI 可读 App 数据容器，但物理上写不进去 → 永不可能写坏目标 App。
/// - bind_app_write（可写+备份）：就地修改用。绑定前先把该 App 的 Documents+Library 备份到
///   工作区 backups/，可写后可改数据（改状态/数值），改坏了可从备份还原。

/// 只读模式：分析 App 数据容器（安全，写不进去）
final class BindAppTool: MCPTool {
    let definition = ToolDefinition(
        name: "bind_app",
        summary: "只读绑定指定 App 数据容器进 Alpine → /ios_data_<app>。参数 bundle_id。让 python3/sqlite3/strings 只读该 App Documents/Library(内购票据/购买状态/导出文件); 读得到写不进去, 永不写坏目标 App。要就地改数据用 bind_app_write(可写+先备份); 读 App Bundle 用 /ios_containers。",
        parameters: [
            "bundle_id": "App bundle ID (required)"
        ], verified: true, category: "filesystem")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        // v7.3.0：Alpine 已移除，"把容器挂载进 Linux"没有意义了。
        // 直接给出 iOS 真实路径，AI 用原生工具（ReadTool / sqlite3 / python3）照样能读。
        guard let container = BindAppTool.containerPath(for: bundleId) else {
            throw MCPError.failed("bind_app: 找不到 \(bundleId) 的数据容器（App 未安装或不可见）")
        }
        return [
            "ok": true,
            "bundle_id": bundleId,
            "mode": "native_read_only",
            "host_path": container,
            "hint": "Alpine 已移除，不再有挂载点。这是该 App 数据容器的 iOS 真实路径，用原生工具直接读即可（如 \(container)/Documents、\(container)/Library/Preferences）。",
        ]
    }
}

extension BindAppTool {
    /// v7.3.0：查 App 数据容器路径（原由 Alpine 挂载层提供，现在直接问容器元数据）
    static func containerPath(for bundleId: String) -> String? {
        let fm = FileManager.default
        let roots = [
            "/var/mobile/Containers/Data/Application",
            "/private/var/mobile/Containers/Data/Application"
        ]
        for root in roots {
            guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for d in dirs {
                let meta = root + "/" + d + "/.com.apple.mobile_container_manager.metadata.plist"
                guard let data = fm.contents(atPath: meta),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let bid = plist["MCMMetadataIdentifier"] as? String, bid == bundleId else { continue }
                return root + "/" + d
            }
        }
        return nil
    }

    /// v7.3.0：把容器里的 Documents + Library 备份到工作区 backups/，返回备份目录
    static func backupContainer(_ container: String, app: String) -> String? {
        let fm = FileManager.default
        let ws = Workspace.root.path + "/backups/\(app)-\(Int(Date().timeIntervalSince1970))"
        try? fm.createDirectory(atPath: ws, withIntermediateDirectories: true)
        var copied = false
        for sub in ["Documents", "Library/Preferences"] {
            let src = container + "/" + sub
            guard fm.fileExists(atPath: src) else { continue }
            let dst = ws + "/" + sub
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if (try? fm.copyItem(atPath: src, toPath: dst)) != nil { copied = true }
        }
        return copied ? ws : nil
    }
}

/// 可写模式：就地修改 App 数据容器（绑定前强制备份到工作区）
final class BindAppWriteTool: MCPTool {
    let definition = ToolDefinition(
        name: "bind_app_write",
        summary: "可写按需绑定指定 App 的数据容器进 Alpine → /ios_data_<app>，用于【就地修改】该 App 的数据(改内购状态/数值/设置/票据)。绑定前先把该 App 的 Documents+Library 自动备份到工作区 backups/，改坏了可从备份还原。风险：写坏该 App 数据容器→该 App 可能无法启动(仅影响目标App, 不影响AI环境)。绝【不】绑自身容器与整棵 /var/mobile(自引用崩溃源)。分析只读用 bind_app。Example: bind_app_write bundle_id:com.appstudio.Jinx → /ios_data_com_appstudio_jinx + backup 路径。",
        parameters: [
            "bundle_id": "App bundle ID (required)"
        ], verified: true, category: "filesystem")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        // v7.3.0：Alpine 已移除；可写模式改为"先备份再直接写 iOS 路径"
        guard let container = BindAppTool.containerPath(for: bundleId) else {
            throw MCPError.failed("bind_app_write: 找不到 \(bundleId) 的数据容器")
        }
        // 先备份（原来由引擎的 bindAppContainer 负责，现在在原生侧做）
        let backup = BindAppTool.backupContainer(container, app: bundleId)
        return [
            "ok": true,
            "bundle_id": bundleId,
            "mode": "native_read_write",
            "host_path": container,
            "backup_path": backup ?? "",
            "warning": "可写：改坏该 App 数据容器 → 该 App 可能无法启动(不影响 AI 环境)。改动前务必确认已备份(见 backup_path)，改坏了从备份还原。",
        ]
    }
}
