// ControlTreeKit.swift — 界面树的小工具（从原 GhostSkill 里保留下来）
//
// 「技能回放」已整体移除；ControlConsoleView 仍需要把 UI 树拍平成可点元素、
// 以及算屏幕签名（判断界面有没有变），所以把这两个纯函数留在这里。

import UIKit

struct Tappable {
    var label: String
    var cx: Double
    var cy: Double
    var w: Double
    var h: Double
    var type: String
}

enum ControlTreeKit {

    /// UI 树 → 可点元素（归一化坐标，0~1）
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
                let frame = node["frame"] as? [String: Any],
                let x = frame["x"] as? Double, let y = frame["y"] as? Double,
                let w = frame["width"] as? Double, let h = frame["height"] as? Double,
                w >= 20, h >= 20
            {
                out.append(
                    Tappable(
                        label: label,
                        cx: (x + w / 2) / screen.width,
                        cy: (y + h / 2) / screen.height,
                        w: w, h: h, type: type
                    ))
            }
            if let kids = node["children"] as? [[String: Any]] { kids.forEach(walk) }
        }
        for key in ["nodes", "elements", "tree"] {
            if let arr = tree[key] as? [[String: Any]] { arr.forEach(walk) }
        }
        return out
    }

    /// 把所有可见文案拍平（判断界面是否变化用）
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

    /// 界面指纹（FNV-1a）
    static func screenSignature(_ tree: [String: Any]) -> String {
        let labels = flatten(tree).sorted()
        let joined = labels.joined(separator: "|")
        var h: UInt64 = 14_695_981_039_346_656_037
        for b in joined.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        return String(h, radix: 16)
    }
}

/// 兼容旧调用点（ControlConsoleView 里写的是 GhostRunner.tappables）
enum GhostRunner {
    static func tappables(_ tree: [String: Any]) -> [Tappable] {
        ControlTreeKit.tappables(tree)
    }
    static func screenSignature(_ tree: [String: Any]) -> String {
        ControlTreeKit.screenSignature(tree)
    }
}
