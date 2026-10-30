// ToolBlackBox.swift — 工具调用黑匣子
//
// 解决「不知道调了哪个工具就直接闪退，且没有崩溃日志」：
// 每次 dispatch 真正执行前，把工具名 + 参数摘要写进 Workspace/.runtime/last-tool.json。
// 闪退时文件会停在 phase="start" —— 下次启动 `diagnose lasttool` 就能看到最后调的是谁。
// 正常结束会写成 phase="done"，所以残留 start 就是"这条调用没走完"。

import Foundation

enum ToolBlackBox {
    static var fileURL: URL {
        Workspace.root
            .appendingPathComponent(".runtime", isDirectory: true)
            .appendingPathComponent("last-tool.json")
    }

    /// 参数摘要：单值截断 120 字，整体截断 400 字
    static func preview(_ params: [String: Any]) -> String {
        var parts: [String] = []
        for (k, v) in params.sorted(by: { $0.key < $1.key }) {
            var s = "\(v)"
            if s.count > 120 { s = String(s.prefix(120)) + "…" }
            parts.append("\(k)=\(s)")
        }
        return String(parts.joined(separator: " ").prefix(400))
    }

    static func mark(tool: String, params: [String: Any], phase: String) {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "ts": formatter.string(from: now),
            "epoch": now.timeIntervalSince1970,
            "tool": tool,
            "phase": phase,
            "thread": Thread.isMainThread ? "main" : "bg",
            "params": preview(params),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }

    /// 读取最后一次记录（没有则 nil）
    static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// 是否"上次调用没走完"（= 可能就是在它上面闪退的）
    static func lastCrashedTool() -> [String: Any]? {
        guard let obj = read() else { return nil }
        let phase = (obj["phase"] as? String) ?? ""
        return phase == "start" ? obj : nil
    }
}
