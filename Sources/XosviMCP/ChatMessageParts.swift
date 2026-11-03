import Foundation

// MARK: - v9：旧字段 → MessagePart 迁移
//
// 顺序规则（对齐模型实际产出）：思考 → 工具（按 toolCalls 数组序）→ 正文。
// 幂等：已有 parts 时直接返回，不重复迁移。

extension ChatMessage {
    /// 把旧的 content / toolCalls / thinking 三字段迁移成有序 parts
    mutating func migrateToPartsIfNeeded() {
        guard parts == nil else { return }
        var out: [MessagePart] = []

        // v9：多段思考（工具轮之间各一段）按顺序展开成多个 reasoning part——
        // 单字段 thinking 只保留最后一段，分段信息在 reasoningSegments 里
        if let segs = reasoningSegments, !segs.isEmpty {
            for seg in segs where !seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.reasoning(seg.text))
            }
        } else if let th = thinking, !th.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(.reasoning(th))
        }

        if let calls = toolCalls, !calls.isEmpty {
            for c in calls {
                // 老数据没有独立结果字段：工具结果在后续 role == "tool" 的消息里，
                // 由 ToolResultMerger 在合并时回填 result。
                out.append(.toolCall(ToolCallPayload(
                    id: c.id,
                    name: c.name,
                    arguments: c.arguments,
                    result: nil,
                    isError: false,
                    durationMs: toolDuration.map { Int(($0 * 1000).rounded()) },
                    previewImage: nil
                )))
            }
        }

        // 图片附件（v9 起以 image part 参与投影，渲染层不再从 imageDataURLs 硬读）
        if let imgs = imageDataURLs {
            for (i, uri) in imgs.enumerated() {
                out.append(.image(ImagePayload(uri: uri,
                                               mime: Self.mimeFromDataURL(uri),
                                               assetId: "\(id.uuidString)-img\(i)")))
            }
        }

        if !content.isEmpty {
            out.append(.text(content))
        }

        // 纯工具消息（role == "tool"）也要能迁移：正文即结果
        if role == "tool", content.isEmpty {
            out.append(.text(""))
        }

        parts = out
    }

    /// 便捷读取：所有正文拼起来（给搜索、摘要、降级渲染用）
    var flatText: String {
        if let parts {
            return parts.compactMap {
                if case .text(let t) = $0 { return t }
                return nil
            }.joined(separator: "\n")
        }
        return content
    }

    /// 降级渲染用：没有 parts 时按老字段拼一个等价 parts（不改自身）
    var effectiveParts: [MessagePart] {
        if let parts { return parts }
        var copy = self
        copy.migrateToPartsIfNeeded()
        return copy.parts ?? []
    }

    private static func mimeFromDataURL(_ s: String) -> String? {
        // data:image/png;base64,xxx → image/png
        guard s.hasPrefix("data:") else { return nil }
        guard let semi = s.firstIndex(of: ";") ?? s.firstIndex(of: ",") else { return nil }
        let mime = String(s[s.index(s.startIndex, offsetBy: 5)..<semi])
        return mime.isEmpty ? nil : mime
    }
}
