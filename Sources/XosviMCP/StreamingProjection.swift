import Foundation
import SwiftUI

// MARK: - v9：流式投影（每个会话一条消息一个，配合增量投影）
//
// 文档 4 节：流式期间只重算尾部。这里做两件事：
//  1) appendText 把 delta 追加到最后一个 text part（而不是重写整段 content）
//  2) 用 IncrementalTimelineProjection 只在尾部变化时重算，返回是否需要刷 UI

final class StreamingProjection {
    private var incremental = IncrementalTimelineProjection()
    private(set) var blocks: [ProjectedBlock] = []

    /// 最近一次 update 是否有变化
    @discardableResult
    func update(parts: [MessagePart], settings: TimelineSettings = .default) -> Bool {
        let changed = incremental.update(parts: parts, settings: settings)
        if changed { blocks = incremental.blocks }
        return changed
    }

    /// 流式 delta 到达时调用；返回 true 表示 blocks 变了需要刷 UI
    @discardableResult
    func appendText(_ delta: String, to msg: inout ChatMessage) -> Bool {
        // 追加到最后一个 text part，没有就新建
        var parts = msg.effectiveParts
        if case .text(let last)? = parts.last {
            parts[parts.count - 1] = .text(last + delta)
        } else {
            parts.append(.text(delta))
        }
        msg.parts = parts
        return update(parts: parts)
    }

    /// 思考增量：追加到最后一个 reasoning part（没有则新建）
    @discardableResult
    func appendReasoning(_ delta: String, to msg: inout ChatMessage) -> Bool {
        var parts = msg.effectiveParts
        if case .reasoning(let last)? = parts.last {
            parts[parts.count - 1] = .reasoning(last + delta)
        } else {
            parts.append(.reasoning(delta))
        }
        msg.parts = parts
        return update(parts: parts)
    }

    func reset() {
        incremental.reset()
        blocks = []
    }
}

// MARK: - v9：150ms 节流的简单实现（done / 取消时 flushNow 立刻执行）

final class StreamThrottle {
    private var pending: (() -> Void)?
    private var workItem: DispatchWorkItem?

    func schedule(delay: TimeInterval = 0.15, _ block: @escaping () -> Void) {
        pending = block
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pending?()
            self?.pending = nil
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// done / 取消时立即执行挂起的最后一批（关键：避免断半句）
    func flushNow() {
        workItem?.cancel()
        pending?()
        pending = nil
    }

    /// 丢弃挂起批次（手动 flush 之后调用，避免重复执行）
    func cancelPending() {
        workItem?.cancel()
        workItem = nil
        pending = nil
    }

    var hasPending: Bool { pending != nil }
}

// MARK: - v9：投影结果缓存
//
// 为什么需要：SwiftUI 的 body 会因任何 @Published 变化重算（流式每秒几十次），
// 若每次都跑 TimelineProjector.project（含字符串切分与折叠分组），长会话会明显卡。
// 这里按 (消息 id, 内容长度, 思考长度, parts 数量) 做指纹，命中即复用上次结果。

final class ProjectedBlockCache {
    static let shared = ProjectedBlockCache()
    private init() {}

    struct Key: Equatable {
        var id: UUID
        var contentCount: Int
        var thinkingCount: Int
        var partsCount: Int
        var showReasoning: Bool
        var showTools: Bool
    }

    private var store: [UUID: (Key, [ProjectedBlock])] = [:]
    private let lock = NSLock()

    func blocks(for msg: ChatMessage, settings: TimelineSettings = .default) -> [ProjectedBlock] {
        let key = Key(id: msg.id,
                      contentCount: msg.content.count,
                      thinkingCount: (msg.thinking ?? "").count,
                      partsCount: msg.parts?.count ?? -1,
                      showReasoning: settings.showReasoning,
                      showTools: settings.showToolCalls)
        lock.lock()
        if let hit = store[msg.id], hit.0 == key {
            lock.unlock()
            return hit.1
        }
        lock.unlock()

        let produced = TimelineProjector.project(msg.effectiveParts, settings: settings)
        lock.lock()
        store[msg.id] = (key, produced)
        // 会话长了以后清掉过期条目（只保留最近 400 条）
        if store.count > 400 { store.removeAll(keepingCapacity: true) }
        lock.unlock()
        return produced
    }

    func invalidate(id: UUID) {
        lock.lock(); store.removeValue(forKey: id); lock.unlock()
    }

    func clear() {
        lock.lock(); store.removeAll(keepingCapacity: true); lock.unlock()
    }
}
