import XCTest
@testable import Xosvi

// MARK: - v9：投影器 / 回填 / 迁移 单测
//
// 覆盖文档给出的 5 个投影用例 + 4 个回填用例，外加两条本项目特有的约束：
//  · block id 必须与 part 索引绑定（流式追加正文时前面块 id 不变）
//  · isConsumedTool 必须是 Optional（老 JSON 缺字段不能整库解码失败）

final class TimelineProjectionTests: XCTestCase {

    // MARK: - 投影顺序

    func testOrderPreserved() {
        let parts: [MessagePart] = [
            .reasoning("想一想"),
            .toolCall(.init(id: "c1", name: "web.search", arguments: "{}",
                            result: "ok", isError: false, durationMs: 120)),
            .text("结论是 A")
        ]
        let blocks = TimelineProjector.project(parts)
        XCTAssertEqual(blocks.count, 2)                       // 过程区 + 正文
        guard case .steps(let steps) = blocks[0].kind else {
            return XCTFail("第一块应为过程区")
        }
        XCTAssertEqual(steps.count, 2)
        if case .reasoning = steps[0] {} else { XCTFail("步骤顺序错") }
        if case .tool = steps[1] {} else { XCTFail("步骤顺序错") }
        guard case .text(let t) = blocks[1].kind else { return XCTFail("第二块应为正文") }
        XCTAssertEqual(t, "结论是 A")
    }

    // MARK: - 折叠

    func testCollapseAdjacentTools() {
        var parts: [MessagePart] = []
        for i in 0..<8 {
            parts.append(.toolCall(.init(id: "c\(i)", name: "web.search",
                                         arguments: "{\"q\":\"\(i)\"}", result: "r\(i)",
                                         isError: false, durationMs: 100)))
        }
        let blocks = TimelineProjector.project(parts)
        guard case .steps(let steps) = blocks.first?.kind else { return XCTFail() }
        XCTAssertEqual(steps.count, 1)                        // 8 个折叠成 1 组
        guard case .toolGroup(_, let refs, let hidden, _) = steps[0] else {
            return XCTFail("应为折叠组")
        }
        XCTAssertEqual(refs.count, 5)                         // 尾部留 5
        XCTAssertEqual(hidden, 3)
    }

    func testMixedToolPrefixNotCollapsed() {
        let parts: [MessagePart] = [
            .toolCall(.init(id: "1", name: "web.search", arguments: "{}", result: "a", isError: false, durationMs: 1)),
            .toolCall(.init(id: "2", name: "file.read", arguments: "{}", result: "b", isError: false, durationMs: 1)),
            .toolCall(.init(id: "3", name: "web.search", arguments: "{}", result: "c", isError: false, durationMs: 1))
        ]
        let blocks = TimelineProjector.project(parts)
        guard case .steps(let steps) = blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(steps.count, 3)                        // 3 个未达阈值 → 平铺 3 条
    }

    // MARK: - 迁移

    func testMigrationFromLegacyFields() {
        var msg = ChatMessage(role: "assistant", content: "答")
        msg.thinking = "想"
        msg.toolCalls = [ToolCall(id: "x", name: "shell.exec", arguments: "{}")]
        msg.migrateToPartsIfNeeded()
        XCTAssertEqual(msg.parts?.count, 3)                   // reasoning + tool + text
        if case .reasoning = msg.parts![0] {} else { XCTFail("首部应为思考") }
        if case .toolCall = msg.parts![1] {} else { XCTFail("其次应为工具") }
        if case .text = msg.parts![2] {} else { XCTFail("末尾应为正文") }
    }

    func testMigrationIsIdempotent() {
        var msg = ChatMessage(role: "assistant", content: "答")
        msg.migrateToPartsIfNeeded()
        let first = msg.parts
        msg.migrateToPartsIfNeeded()
        XCTAssertEqual(msg.parts, first)
    }

    func testMigrationExpandsReasoningSegments() {
        var msg = ChatMessage(role: "assistant", content: "答")
        msg.reasoningSegments = [
            ReasoningSegment(text: "第一段"),
            ReasoningSegment(text: "第二段")
        ]
        msg.migrateToPartsIfNeeded()
        let reasonings = (msg.parts ?? []).compactMap { part -> String? in
            if case .reasoning(let t) = part { return t }
            return nil
        }
        XCTAssertEqual(reasonings, ["第一段", "第二段"])       // 多段思考按序保留
    }

    // MARK: - 结构边界

    func testRoundEndBreaksBlock() {
        let parts: [MessagePart] = [
            .toolCall(.init(id: "1", name: "x.y", arguments: "{}", result: "a", isError: false, durationMs: 1)),
            .roundEnd(reasoningDetails: nil),
            .text("下一轮正文")
        ]
        let blocks = TimelineProjector.project(parts)
        XCTAssertEqual(blocks.count, 2)                       // 过程区被 roundEnd 切断
        if case .text = blocks[1].kind {} else { XCTFail() }
    }

    func testRoundsSplitting() {
        let parts: [MessagePart] = [
            .text("a"),
            .roundEnd(reasoningDetails: nil),
            .text("b")
        ]
        let rounds = TimelineProjector.rounds(parts)
        XCTAssertEqual(rounds.count, 2)
        XCTAssertEqual(rounds[0].count, 1)
        XCTAssertEqual(rounds[1].count, 1)
    }

    // MARK: - 本项目特有：id 稳定性

    func testBlockIDsAreStableOnAppend() {
        let before: [MessagePart] = [.text("你好")]
        var after = before
        after[0] = .text("你好，世界")

        let a = TimelineProjector.project(before)
        let b = TimelineProjector.project(after)
        XCTAssertEqual(a.first?.id, b.first?.id)              // 同一 part 索引 → id 不变
        if case .text(let t) = b[0].kind { XCTAssertEqual(t, "你好，世界") }
    }

    func testIncrementalSkipsWhenUnchanged() {
        var inc = IncrementalTimelineProjection()
        let parts: [MessagePart] = [.text("abc")]
        XCTAssertTrue(inc.update(parts: parts))
        XCTAssertFalse(inc.update(parts: parts))              // 完全没变 → 不刷 UI
        XCTAssertEqual(inc.blocks.count, 1)
    }

    // MARK: - 工具结果回填

    func testBackfillById() {
        var a = ChatMessage(role: "assistant", content: "")
        a.parts = [
            .toolCall(.init(id: "c1", name: "web.search", arguments: "{}",
                            result: nil, isError: false, durationMs: nil)),
            .text("结论")
        ]
        let t = ChatMessage(role: "tool", content: "搜索结果",
                            toolCallId: "c1", toolName: "web.search")
        let out = [a, t].mergingToolResultsIsolated()

        guard case .toolCall(let p) = out[0].parts![0] else { return XCTFail() }
        XCTAssertEqual(p.result, "搜索结果")
        XCTAssertFalse(p.isError)
        XCTAssertTrue(out[1].isToolConsumed)                  // tool 消息被标记
    }

    func testIdempotent() {
        var a = ChatMessage(role: "assistant", content: "")
        a.parts = [.toolCall(.init(id: "c1", name: "x", arguments: "{}",
                                   result: "已有", isError: false, durationMs: nil))]
        let t = ChatMessage(role: "tool", content: "新的", toolCallId: "c1", toolName: "x")
        let once = [a, t].mergingToolResultsIsolated()
        let twice = once.mergingToolResultsIsolated()
        guard case .toolCall(let p) = twice[0].parts![0] else { return XCTFail() }
        XCTAssertEqual(p.result, "已有")                      // 不被覆盖
    }

    func testNoCrossRoundMatching() {
        // 第 1 轮的 tool 消息不能被第 2 轮的调用吃掉
        let u1 = ChatMessage(role: "user", content: "第一问")
        var a1 = ChatMessage(role: "assistant", content: "")
        a1.parts = [.toolCall(.init(id: "", name: "shell.exec", arguments: "{}",
                                    result: nil, isError: false, durationMs: nil))]
        let t1 = ChatMessage(role: "tool", content: "第一轮结果",
                             toolCallId: nil, toolName: "shell.exec")
        let u2 = ChatMessage(role: "user", content: "第二问")
        var a2 = ChatMessage(role: "assistant", content: "")
        a2.parts = [.toolCall(.init(id: "", name: "shell.exec", arguments: "{}",
                                    result: nil, isError: false, durationMs: nil))]

        let out = [u1, a1, t1, u2, a2].mergingToolResultsIsolated()

        guard case .toolCall(let p1) = out[1].parts![0] else { return XCTFail() }
        XCTAssertEqual(p1.result, "第一轮结果")               // 第 1 轮正确回填

        guard case .toolCall(let p2) = out[4].parts![0] else { return XCTFail() }
        XCTAssertNil(p2.result)                               // 第 2 轮不该拿到第 1 轮的结果
    }

    func testParallelCallsOrderIndependent() {
        var a = ChatMessage(role: "assistant", content: "")
        a.parts = [
            .toolCall(.init(id: "c1", name: "a", arguments: "{}", result: nil, isError: false, durationMs: nil)),
            .toolCall(.init(id: "c2", name: "a", arguments: "{}", result: nil, isError: false, durationMs: nil))
        ]
        // 结果乱序返回
        let t2 = ChatMessage(role: "tool", content: "第二个", toolCallId: "c2", toolName: "a")
        let t1 = ChatMessage(role: "tool", content: "第一个", toolCallId: "c1", toolName: "a")
        let out = [a, t2, t1].mergingToolResultsIsolated()

        guard case .toolCall(let p1) = out[0].parts![0],
              case .toolCall(let p2) = out[0].parts![1] else { return XCTFail() }
        XCTAssertEqual(p1.result, "第一个")                   // 按 id 匹配，不看顺序
        XCTAssertEqual(p2.result, "第二个")
    }

    // MARK: - 老数据兼容

    func testConsumedFlagDecodesFromLegacyJSON() throws {
        // 老会话 JSON 没有 isConsumedTool / parts —— 解码必须成功，不能整库丢。
        // 做法：先编码一条新消息，再把两个新 key 删掉，模拟老数据。
        let msg = ChatMessage(role: "assistant", content: "旧消息")
        let encoded = try JSONEncoder().encode([msg])
        guard var arr = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] else {
            return XCTFail("编码结果不是对象数组")
        }
        arr[0].removeValue(forKey: "isConsumedTool")
        arr[0].removeValue(forKey: "parts")
        let legacy = try JSONSerialization.data(withJSONObject: arr)

        let msgs = try JSONDecoder().decode([ChatMessage].self, from: legacy)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertFalse(msgs[0].isToolConsumed)                 // 缺字段 → 默认 false
        XCTAssertNil(msgs[0].parts)
        XCTAssertEqual(msgs[0].effectiveParts.count, 1)        // 迁移后只有一个 text part
    }

    func testMessagePartRoundTrip() throws {
        let parts: [MessagePart] = [
            .reasoning("想"),
            .toolCall(.init(id: "c1", name: "web.search", arguments: "{\"q\":\"x\"}",
                            result: "r", isError: false, durationMs: 12)),
            .roundEnd(reasoningDetails: .object(["k": .string("v")])),
            .image(.init(uri: "data:image/png;base64,AAA", mime: "image/png")),
            .file(.init(uri: "/tmp/a.txt", name: "a.txt", mime: "text/plain")),
            .unknown(kind: "future_thing", payload: "raw"),
            .text("正文")
        ]
        let data = try JSONEncoder().encode(parts)
        let back = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(back, parts)                           // 前向兼容字段无损
    }
}
