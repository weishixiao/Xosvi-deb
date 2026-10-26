import Foundation
import UIKit

// MARK: - v7.10.0 Ghost 技能（移植 ghost-in-the-droid 的 skills 思路）
//
// Ghost 的核心洞察：**技能不用模型**。
// 已知流程编译成「元素定义 + 动作序列」，回放时零 LLM 调用、几秒跑完；
// 只有未知任务才交给模型现想。
//
// 本项目没有 ADB / Appium，驱动换成已有的 ControlAgent（注入 dylib，读无障碍树 + 合成点按），
// 能力上比 WDA 更直接：不需要 Mac、不需要 Xcode 签名。
//
// 一个技能长这样（存成 JSON，字段比 Ghost 的 YAML 少但一一对应）：
//   {
//     "name": "小红书点赞第一篇",
//     "bundleId": "com.xingin.discover",
//     "elements": [ {"id":"first_note","label":"第一篇笔记"} ],
//     "steps": [
//        {"action":"launch"},
//        {"action":"wait","seconds":2},
//        {"action":"tap","target":"first_note"},
//        {"action":"back"}
//     ]
//   }

// MARK: - 模型

struct SkillElement: Codable, Hashable {
    var id: String
    /// 可见文字（优先按它找）
    var label: String?
    /// 无障碍标识（如果 App 提供，比文字稳）
    var accessibilityId: String?
    /// 相对坐标兜底（0~1，屏幕比例）
    var nx: Double?
    var ny: Double?
}

enum SkillAction: String, Codable, CaseIterable {
    case launch          // 启动 bundleId 对应的 App
    case tap             // 按元素点按（优先 tap_text）
    case tapXY           // 按绝对坐标点按
    case type            // 往输入框输入文字
    case swipe           // 滑动
    case key             // home / back / enter
    case wait            // 等待
    case screenshot      // 截一张图存工作区
    case assertText      // 断言屏幕上出现某段文字（找不到就失败）

    var displayName: String {
        switch self {
        case .launch: return "启动"
        case .tap: return "点按元素"
        case .tapXY: return "点按坐标"
        case .type: return "输入"
        case .swipe: return "滑动"
        case .key: return "按键"
        case .wait: return "等待"
        case .screenshot: return "截图"
        case .assertText: return "校验文字"
        }
    }
}

struct SkillStep: Codable, Identifiable {
    var id: UUID = UUID()
    var action: SkillAction
    var target: String?          // 元素 id（tap）
    var text: String?            // type / assertText 用
    var key: String?             // key 用
    var seconds: Double?         // wait 用
    var x: Double?
    var y: Double?
    var x2: Double?
    var y2: Double?
    /// 失败是否中断（默认中断）
    var optional: Bool = false
}

struct GhostSkill: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var bundleId: String?
    var elements: [SkillElement] = []
    var steps: [SkillStep] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var runs: Int = 0
    var lastResult: String?

    func element(_ id: String) -> SkillElement? { elements.first { $0.id == id } }
}

// MARK: - 存储

final class GhostSkillStore {
    static let shared = GhostSkillStore()

    private var dir: String {
        let p = Workspace.root.appendingPathComponent("ghost-skills", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func list() -> [GhostSkill] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [GhostSkill] = []
        for n in names where n.hasSuffix(".json") {
            let p = dir + "/" + n
            if let d = FileManager.default.contents(atPath: p),
               let s = try? JSONDecoder().decode(GhostSkill.self, from: d) {
                out.append(s)
            }
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ skill: GhostSkill) {
        var s = skill
        s.updatedAt = Date()
        if let d = try? JSONEncoder().encode(s) {
            try? d.write(to: URL(fileURLWithPath: dir + "/\(s.id.uuidString).json"))
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(atPath: dir + "/\(id.uuidString).json")
    }
}

// MARK: - 回放引擎（确定性，零 LLM）

enum GhostRunner {

    struct StepResult {
        var index: Int
        var action: String
        var ok: Bool
        var detail: String
        var ms: Int
    }

    /// 执行技能。progress 会在每步结束时回调（用于会话里显示进度）
    static func run(_ skill: GhostSkill,
                    stopOnError: Bool = true,
                    progress: ((StepResult) -> Void)? = nil) -> (ok: Bool, steps: [StepResult], error: String?) {
        var results: [StepResult] = []

        // 需要控制目标 App 时先确认 ControlAgent 在线
        if skill.steps.contains(where: { $0.action != .wait && $0.action != .screenshot }) {
            if let err = ensureControlReady(bundleId: skill.bundleId) {
                return (false, [], err)
            }
        }

        for (i, step) in skill.steps.enumerated() {
            let t0 = CFAbsoluteTimeGetCurrent()
            var ok = true
            var detail = ""

            do {
                switch step.action {
                case .launch:
                    detail = try launchApp(skill.bundleId)
                case .tap:
                    guard let tid = step.target, let el = skill.element(tid) else {
                        throw SkillError.message("步骤 \(i + 1)：找不到元素定义 \(step.target ?? "nil")")
                    }
                    detail = try tapElement(el)
                case .tapXY:
                    guard let x = step.x, let y = step.y else {
                        throw SkillError.message("步骤 \(i + 1)：tapXY 缺坐标")
                    }
                    _ = try control(["command": "tap", "x": Int(x), "y": Int(y)])
                    detail = "tap (\(Int(x)), \(Int(y)))"
                case .type:
                    let text = step.text ?? ""
                    _ = try control(["command": "type", "text": text])
                    detail = "输入 \(text.prefix(20))"
                case .swipe:
                    _ = try control(["command": "swipe",
                                     "x1": Int(step.x ?? 0), "y1": Int(step.y ?? 0),
                                     "x2": Int(step.x2 ?? 0), "y2": Int(step.y2 ?? 0)])
                    detail = "swipe"
                case .key:
                    _ = try control(["command": "key", "key": step.key ?? "back"])
                    detail = "key \(step.key ?? "back")"
                case .wait:
                    let s = step.seconds ?? 1
                    Thread.sleep(forTimeInterval: min(max(s, 0.1), 30))
                    detail = "等待 \(s)s"
                case .screenshot:
                    let r = try control(["command": "screenshot"])
                    detail = (r["path"] as? String) ?? "已截图"
                case .assertText:
                    let want = step.text ?? ""
                    let tree = try control(["command": "ui_tree"])
                    let flat = flatten(tree)
                    if flat.contains(where: { $0.localizedCaseInsensitiveContains(want) }) {
                        detail = "找到「\(want)」"
                    } else {
                        throw SkillError.message("步骤 \(i + 1)：屏幕上没有「\(want)」")
                    }
                }
            } catch {
                ok = false
                detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }

            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            let r = StepResult(index: i + 1, action: step.action.displayName, ok: ok, detail: detail, ms: ms)
            results.append(r)
            progress?(r)

            if !ok && !step.optional && stopOnError {
                return (false, results, detail)
            }
        }
        return (true, results, nil)
    }

    // MARK: 控制层

    enum SkillError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let m) = self { return m }
            return nil
        }
    }

    private static func control(_ params: [String: Any]) throws -> [String: Any] {
        try ToolRegistry.shared.dispatch(name: "control", params: params)
    }

    private static func ensureControlReady(bundleId: String?) -> String? {
        // 已连接就直接用
        if let st = try? control(["command": "status"]),
           (st["connected"] as? Bool) == true || (st["ok"] as? Bool) == true {
            return nil
        }
        guard let bid = bundleId, !bid.isEmpty else {
            return "ControlAgent 未连接，且技能没写 bundleId——无法自动注入。先 control inject 再跑。"
        }
        do {
            _ = try control(["command": "inject", "bundle_id": bid])
            Thread.sleep(forTimeInterval: 1.2)
            if let st = try? control(["command": "status"]),
               (st["connected"] as? Bool) == true || (st["ok"] as? Bool) == true {
                return nil
            }
            return "注入 \(bid) 后仍连不上 ControlAgent，确认目标 App 已启动。"
        } catch {
            return "注入失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    private static func launchApp(_ bundleId: String?) throws -> String {
        guard let bid = bundleId, !bid.isEmpty else { throw SkillError.message("技能没写 bundleId") }
        let r = try ToolRegistry.shared.dispatch(name: "app", params: ["command": "launch", "bundle_id": bid])
        if let e = r["error"] as? String { throw SkillError.message(e) }
        Thread.sleep(forTimeInterval: 1.5)
        return "已启动 \(bid)"
    }

    private static func tapElement(_ el: SkillElement) throws -> String {
        // 1) 无障碍标识优先
        if let aid = el.accessibilityId, !aid.isEmpty {
            if let r = try? control(["command": "tap_text", "text": aid, "partial": true]),
               r["error"] == nil { return "tap(无障碍) \(aid)" }
        }
        // 2) 可见文字
        if let label = el.label, !label.isEmpty {
            if let r = try? control(["command": "tap_text", "text": label, "partial": true]),
               r["error"] == nil { return "tap「\(label)」" }
        }
        // 3) 相对坐标兜底
        if let nx = el.nx, let ny = el.ny {
            let screen = UIScreen.main.bounds
            _ = try control(["command": "tap", "x": Int(nx * screen.width), "y": Int(ny * screen.height)])
            return "tap 坐标(\(Int(nx * 100))%,\(Int(ny * 100))%)"
        }
        throw SkillError.message("元素 \(el.id) 没有任何可用定位方式")
    }

    // MARK: 树工具

    static func flatten(_ tree: [String: Any]) -> [String] {
        var out: [String] = []
        func walk(_ node: [String: Any]) {
            for k in ["text", "label", "accessibilityLabel", "value"] {
                if let s = node[k] as? String, !s.isEmpty { out.append(s) }
            }
            if let kids = node["children"] as? [[String: Any]] { kids.forEach(walk) }
        }
        for key in ["nodes", "elements", "tree"] {
            if let arr = tree[key] as? [[String: Any]] { arr.forEach(walk) }
        }
        if out.isEmpty, let single = tree["root"] as? [String: Any] { walk(single) }
        return out
    }

    /// 可点元素（带中心坐标），用于生成元素定义 / 自动探索
    struct Tappable { var label: String; var cx: Double; var cy: Double; var w: Double; var h: Double; var type: String }

    static func tappables(_ tree: [String: Any]) -> [Tappable] {
        var out: [Tappable] = []
        let screen = UIScreen.main.bounds

        func walk(_ node: [String: Any]) {
            let label = (node["text"] as? String)
                ?? (node["label"] as? String)
                ?? (node["accessibilityLabel"] as? String)
                ?? ""
            let type = (node["type"] as? String) ?? (node["class"] as? String) ?? ""
            let hittable = (node["isHittable"] as? Bool) ?? true
            let visible = (node["isVisible"] as? Bool) ?? true

            if !label.isEmpty, hittable, visible,
               let f = node["frame"] as? [String: Any],
               let x = f["x"] as? Double, let y = f["y"] as? Double,
               let w = f["width"] as? Double, let h = f["height"] as? Double,
               w >= 20, h >= 20 {
                out.append(Tappable(label: label,
                                    cx: (x + w / 2) / screen.width,
                                    cy: (y + h / 2) / screen.height,
                                    w: w, h: h, type: type))
            }
            if let kids = node["children"] as? [[String: Any]] { kids.forEach(walk) }
        }
        for key in ["nodes", "elements", "tree"] {
            if let arr = tree[key] as? [[String: Any]] { arr.forEach(walk) }
        }
        if out.isEmpty, let single = tree["root"] as? [String: Any] { walk(single) }
        // 去重（同文字只留第一个）
        var seen = Set<String>()
        return out.filter { seen.insert($0.label).inserted }
    }

    /// 屏幕签名：用可见文字集合的哈希，判断"是不是同一个界面"
    static func screenSignature(_ tree: [String: Any]) -> String {
        let labels = flatten(tree).sorted()
        let joined = labels.joined(separator: "|")
        var h: UInt64 = 1469598103934665603
        for b in joined.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }
}
