import Foundation

// MARK: - v9：把独立的 role == "tool" 消息回填进 ToolCallPayload.result
//
// 旧数据结构：assistant 消息带 toolCalls，工具结果放在后续 role == "tool" 的独立消息里
//            （content = 结果文本，toolCallId / toolName 指向对应调用）。
// 新结构：结果应该住在 ToolCallPayload.result 上，tool 消息可以从渲染流里消失。
//
// 关键约束：
// 1. 必须按 toolCallId 精确匹配，不能按顺序猜——并行调用时顺序不保证。
// 2. 幂等：重复调用不产生重复回填（已有 result 的 payload 直接跳过）。
// 3. 找不到匹配的 tool 消息（老数据缺 id）时，按「同 name 且尚未回填、且在当前消息之后」兜底。
// 4. 回填后仍保留原 tool 消息（标记 isConsumedTool），不物理删除——搜索/审计还要用，
//    渲染层靠该标志跳过它。

extension Array where Element == ChatMessage {

    /// 带轮次隔离的版本（推荐）：两个 user 消息之间为一轮，避免第 2 轮同名工具吃掉第 1 轮结果。
    func mergingToolResultsIsolated() -> [ChatMessage] {
        var out = self

        // 1) 计算每条消息所属轮次：遇到 user 消息轮次 +1
        var roundOf: [Int] = []
        var round = 0
        roundOf.reserveCapacity(out.count)
        for msg in out {
            if msg.role == "user" { round += 1 }
            roundOf.append(round)
        }

        // 2) tool 消息索引：(round, callId) 与 (round, name)
        var byKey: [String: Int] = [:]           // "round|callId" → index
        var byRoundName: [String: [Int]] = [:]   // "round|name" → indices
        var consumed: Set<Int> = []

        for (i, msg) in out.enumerated() where msg.role == "tool" {
            let r = roundOf[i]
            if let cid = msg.toolCallId, !cid.isEmpty {
                byKey["\(r)|\(cid)"] = i
            }
            if let name = msg.toolName, !name.isEmpty {
                byRoundName["\(r)|\(name)", default: []].append(i)
            }
        }

        // 3) 回填：迁移缺失 parts 的消息，再逐条 toolCall 匹配
        for i in out.indices {
            if out[i].parts == nil { out[i].migrateToPartsIfNeeded() }
            guard var parts = out[i].parts, !parts.isEmpty else { continue }
            let r = roundOf[i]
            var changed = false

            for pIdx in parts.indices {
                guard case .toolCall(var payload) = parts[pIdx] else { continue }
                if payload.result != nil { continue }        // 幂等：已有结果不覆盖

                var hitIndex: Int?
                if !payload.id.isEmpty,
                   let idx = byKey["\(r)|\(payload.id)"], !consumed.contains(idx) {
                    hitIndex = idx
                } else if let candidates = byRoundName["\(r)|\(payload.name)"] {
                    hitIndex = candidates.first { !consumed.contains($0) && $0 > i }
                }
                guard let h = hitIndex else { continue }

                payload.result = out[h].content
                payload.isError = out[h].isError
                if payload.durationMs == nil,
                   let d = out[h].toolDuration {
                    payload.durationMs = Int((d * 1000).rounded())
                }
                parts[pIdx] = .toolCall(payload)
                consumed.insert(h)
                out[h].isConsumedTool = true
                changed = true
            }
            if changed { out[i].parts = parts }
        }

        // 4) 顺带补齐：没有 parts 的消息也迁移一次（一次到位，后续不再判空）
        for i in out.indices where out[i].parts == nil {
            out[i].migrateToPartsIfNeeded()
        }
        return out
    }
}
