import Foundation

// MARK: - v9：时间线投影器（移植 Kelivo timeline_projection）
//
// 职责：把 [MessagePart] 变成可直接渲染的 [ProjectedBlock]。
// 纯函数、无 UI 依赖、可单测。渲染层只认 block，不再认 part。
//
// 与文档草稿的唯一有意差异：block / step 的 id 用「part 索引 + 类型」而不是自增序号，
// 这样流式追加正文时前面所有 block 的 id 完全不变，LazyVStack / SwiftUI diff 天然不重建它们
// （文档第 4 节末尾也建议这么做，这里直接落地）。

// MARK: 视图设置

struct TimelineSettings {
    var showReasoning: Bool = true
    var showToolCalls: Bool = true
    /// 图片块是否由投影器渲染（气泡内已有独立的附件条时置 false，避免重复）
    var showImages: Bool = true
    /// 连续同类工具折叠阈值（Kelivo: 6）
    var collapseThreshold: Int = 6
    /// 折叠后保留尾部条数（Kelivo: 5）
    var collapseTail: Int = 5
    /// 折叠时按工具名前缀归组（browser 一组、web 一组…）
    var groupByToolPrefix: Bool = true

    static let `default` = TimelineSettings()
}

// MARK: 渲染单元

struct ProjectedBlock: Identifiable {
    enum Kind {
        case text(String)
        case image(ImagePayload)
        case file(FilePayload)
        /// 思考 + 工具组成的「过程区」，按步骤顺序渲染
        case steps([ProjectedStep])
    }
    let id: String
    var kind: Kind

    /// 过程区是否全部是工具（用于决定折叠样式）
    var isToolOnly: Bool {
        if case .steps(let s) = kind { return s.allSatisfy { $0.isTool } }
        return false
    }
}

enum ProjectedStep: Identifiable {
    /// 思考段。toolCountAfter = 这一思考之后还有几个工具步骤（折叠时显示计数）
    case reasoning(id: String, text: String, toolCountAfter: Int)
    /// 单个工具
    case tool(id: String, ref: ToolStepRef)
    /// 连续同类工具折叠组
    case toolGroup(id: String, refs: [ToolStepRef], hiddenCount: Int, lite: Bool)

    var id: String {
        switch self {
        case .reasoning(let id, _, _): return id
        case .tool(let id, _): return id
        case .toolGroup(let id, _, _, _): return id
        }
    }

    var isTool: Bool { if case .reasoning = self { return false }; return true }

    var primaryRef: ToolStepRef? {
        switch self {
        case .tool(_, let r): return r
        case .toolGroup(_, let refs, _, _): return refs.last
        case .reasoning: return nil
        }
    }
}

struct ToolStepRef: Identifiable, Hashable {
    var id: String
    var name: String
    var argumentsPreview: String      // 单行、截断到 120 字符
    var resultPreview: String?        // 单行、截断（气泡内摘要用）
    /// 完整参数 / 完整结果——点开步骤面板时看全量（不参与折叠，仅展示）
    var argumentsFull: String = ""
    var resultFull: String? = nil
    var isError: Bool
    var durationMs: Int?
    var isRunning: Bool
}

// MARK: 投影器

enum TimelineProjector {

    static func project(_ parts: [MessagePart],
                        settings: TimelineSettings = .default) -> [ProjectedBlock] {
        var blocks: [ProjectedBlock] = []
        var pendingSteps: [ProjectedStep] = []
        var stepSeq = 0

        func flushSteps(_ endPartIndex: Int) {
            guard !pendingSteps.isEmpty else { return }
            // 连续同类工具折叠
            let collapsed = collapseAdjacentTools(pendingSteps, settings: settings)
            blocks.append(ProjectedBlock(id: "steps@\(endPartIndex)",
                                         kind: .steps(collapsed)))
            pendingSteps.removeAll()
        }

        // 先统计工具总数，供 reasoning.toolCountAfter 使用
        let totalTools = parts.reduce(0) {
            if case .toolCall = $1 { return $0 + 1 }
            return $0
        }
        var toolsSeen = 0

        for (idx, part) in parts.enumerated() {
            switch part {
            case .reasoning(let text):
                guard settings.showReasoning,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                pendingSteps.append(.reasoning(
                    id: "r@\(idx)#\(stepSeq)",
                    text: text,
                    toolCountAfter: totalTools - toolsSeen
                ))
                stepSeq += 1

            case .toolCall(let p):
                guard settings.showToolCalls else { continue }
                toolsSeen += 1
                pendingSteps.append(.tool(id: "t@\(idx)#\(stepSeq)", ref: makeRef(p)))
                stepSeq += 1

            case .text(let t):
                guard !t.isEmpty else { continue }
                flushSteps(idx)
                blocks.append(ProjectedBlock(id: "txt@\(idx)", kind: .text(t)))

            case .image(let img):
                guard settings.showImages else { continue }
                flushSteps(idx)
                blocks.append(ProjectedBlock(id: "img@\(idx)", kind: .image(img)))

            case .file(let f):
                flushSteps(idx)
                blocks.append(ProjectedBlock(id: "file@\(idx)", kind: .file(f)))

            case .roundEnd, .unknown:
                // 结构边界：结束过程区，不产生可见块
                flushSteps(idx)
            }
        }
        flushSteps(parts.count)
        return blocks
    }

    // MARK: 工具 ref

    static func makeRef(_ p: ToolCallPayload) -> ToolStepRef {
        let argLine = oneLine(p.arguments, limit: 120)
        let resLine = p.result.map { oneLine($0, limit: 200) }
        return ToolStepRef(
            id: p.id,
            name: p.name,
            argumentsPreview: argLine,
            resultPreview: resLine,
            argumentsFull: p.arguments,
            resultFull: p.result,
            isError: p.isError,
            durationMs: p.durationMs,
            isRunning: p.result == nil && !p.isError
        )
    }

    static func oneLine(_ s: String, limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    // MARK: 连续同类工具折叠

    static func collapseAdjacentTools(_ steps: [ProjectedStep],
                                      settings: TimelineSettings) -> [ProjectedStep] {
        guard settings.collapseThreshold > 1 else { return steps }

        // 先把步骤切成「连续同类工具段」和「其它步骤段」
        struct Run { var items: [ProjectedStep]; var key: String? }
        var runs: [Run] = []

        for step in steps {
            if case .tool(_, let ref) = step {
                let key = settings.groupByToolPrefix
                    ? String(ref.name.prefix(while: { $0 != "." && $0 != "_" }))
                    : ref.name
                if var last = runs.last, last.key == key {
                    last.items.append(step)
                    runs[runs.count - 1] = last
                } else {
                    runs.append(Run(items: [step], key: key))
                }
            } else {
                runs.append(Run(items: [step], key: nil))
            }
        }

        var out: [ProjectedStep] = []
        for run in runs {
            guard run.key != nil,
                  run.items.count > settings.collapseThreshold else {
                out.append(contentsOf: run.items)
                continue
            }
            let refs = run.items.compactMap { $0.primaryRef }
            let tail = max(1, settings.collapseTail)
            let shown = Array(refs.suffix(tail))
            let hidden = refs.count - shown.count
            out.append(.toolGroup(
                id: "grp-\(run.items.first?.id ?? UUID().uuidString)",
                refs: shown,
                hiddenCount: hidden,
                lite: false
            ))
        }
        return out
    }

    // MARK: 回合切段（任务面板用：按 roundEnd 把一条消息切成多段）
    //
    // 文档二节：任务视图不是特殊会话类型，而是同一套 MessagePart 流按 roundEnd 切段的另一种投影。

    static func rounds(_ parts: [MessagePart]) -> [[MessagePart]] {
        var out: [[MessagePart]] = []
        var cur: [MessagePart] = []
        for p in parts {
            if case .roundEnd = p {
                if !cur.isEmpty { out.append(cur); cur.removeAll() }
            } else {
                cur.append(p)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

// MARK: - v9：增量投影（流式用）

/// 流式期间只重算尾部：前面的块若 part 完全没变，直接复用 identity。
struct IncrementalTimelineProjection {
    private(set) var blocks: [ProjectedBlock] = []
    private var lastPartsCount = 0
    private var lastLastPartHash = 0
    /// 上一轮复用了几块（供调试/性能观察）
    private(set) var reusedPrefixCount = 0

    /// 返回是否需要刷新 UI。只有尾部变化时 blocks 的 prefix 保持同一 id。
    @discardableResult
    mutating func update(parts: [MessagePart],
                         settings: TimelineSettings = .default) -> Bool {
        // 尾部判据：part 数量 + 最后一个 part 的 hash。都相同 → 跳过
        let tailHash = parts.last?.hashValue ?? 0
        if parts.count == lastPartsCount && tailHash == lastLastPartHash {
            reusedPrefixCount = blocks.count
            return false
        }

        let full = TimelineProjector.project(parts, settings: settings)
        reusedPrefixCount = commonPrefixLength(blocks, full)
        blocks = full
        lastPartsCount = parts.count
        lastLastPartHash = tailHash
        return true
    }

    mutating func reset() {
        blocks = []
        lastPartsCount = 0
        lastLastPartHash = 0
        reusedPrefixCount = 0
    }

    private func commonPrefixLength(_ a: [ProjectedBlock], _ b: [ProjectedBlock]) -> Int {
        var i = 0
        while i < a.count, i < b.count, a[i].id == b[i].id { i += 1 }
        return i
    }
}
