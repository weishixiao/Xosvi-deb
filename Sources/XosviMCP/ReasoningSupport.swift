// ReasoningSupport.swift — 移植 kelivo 的思考链路能力
//
// 1) ReasoningSegment：一次请求里可有多段思考（工具轮之间各一段），带起止时间
// 2) InlineThink：模型把思考写进正文（<think>…</think> / <|channel>thought…<channel|>）
//    时，按 kelivo thinking_tag_parser 的规则剥离；未闭合块按「剩下全是思考」处理
//
// 纯 Foundation，不依赖任何 UI。

import Foundation

/// 一段思考。与 kelivo 的 reasoning segment 对齐（text/startAt/finishedAt/toolStartIndex）。
struct ReasoningSegment: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var startAt: Date? = nil
    var finishedAt: Date? = nil
    /// 这段思考发生在第几个工具步骤之前（nil = 没有工具轮）
    var toolStartIndex: Int? = nil
    var expanded: Bool = false

    var duration: TimeInterval? {
        guard let start = startAt, let end = finishedAt else { return nil }
        return max(0, end.timeIntervalSince(start))
    }
}

enum InlineThink {
    struct Result {
        var visible: String
        var thoughts: [String]
        var hasThinking: Bool { !thoughts.isEmpty }
    }

    /// 开标签：<think> / <thinking> / <thought> / <|channel>thought
    private static let openPattern = "<(think|thinking|thought)>|<\\|channel>thought"

    /// 从正文里剥离思考块。未闭合块（流式中途）把剩余内容全部当思考。
    static func extract(_ input: String, includeUnclosed: Bool = true) -> Result {
        guard !input.isEmpty else { return Result(visible: input, thoughts: []) }
        let ns = input as NSString
        guard let openRe = try? NSRegularExpression(
            pattern: openPattern, options: [.caseInsensitive]
        ) else {
            return Result(visible: input, thoughts: [])
        }

        var visible = ""
        var thoughts: [String] = []
        var cursor = 0

        while cursor < ns.length {
            let searchRange = NSRange(location: cursor, length: ns.length - cursor)
            guard let open = openRe.firstMatch(in: input, options: [], range: searchRange) else {
                visible += ns.substring(from: cursor)
                break
            }
            let tagName: String? = {
                guard open.numberOfRanges > 1, open.range(at: 1).location != NSNotFound else {
                    return nil
                }
                return ns.substring(with: open.range(at: 1)).lowercased()
            }()
            let closeTag = tagName == nil ? "<channel|>" : "</\(tagName!)>"
            let openEnd = open.range.location + open.range.length
            visible += ns.substring(with: NSRange(location: cursor, length: open.range.location - cursor))

            let closeRange = ns.range(
                of: closeTag,
                options: [.caseInsensitive],
                range: NSRange(location: openEnd, length: ns.length - openEnd)
            )
            if closeRange.location == NSNotFound {
                if !includeUnclosed {
                    visible += ns.substring(from: open.range.location)
                    break
                }
                let body = ns.substring(from: openEnd)
                if !body.isEmpty { thoughts.append(body) }
                break
            }
            let body = ns.substring(
                with: NSRange(location: openEnd, length: closeRange.location - openEnd)
            )
            if !body.isEmpty { thoughts.append(body) }
            cursor = closeRange.location + closeRange.length
        }

        return Result(visible: visible, thoughts: thoughts)
    }
}
