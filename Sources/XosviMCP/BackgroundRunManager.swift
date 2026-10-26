// BackgroundRunManager.swift — 会话级并发（v6.6.17）
//
// 问题：ConversationStore 是单例，isLoading / currentClient / 流式缓冲 /
// 各种纠正计数器都是实例字段，两个会话同时跑会互相踩（切走再发消息，
// 前一个任务的输出会被写进新会话，反之亦然）。
//
// 做法：不动主循环，给"第二个会话"开一个独立的 ConversationStore 实例
// （background: true）。它拥有完整的独立运行状态，不读写共享存储；
// 跑完后由本类把整段会话合并回 ConversationStore.shared。
//
// 取舍：后台会话不显示逐字流式（它的 streaming 写在自己的副本里），
// 完成后一次性出现；同时只有一个会话占用 UI 的实时输出。

import Foundation
import Combine

final class BackgroundRunManager: ObservableObject {
    static let shared = BackgroundRunManager()

    /// 正在后台运行的会话 id（UI 可据此显示标记）
    @Published private(set) var runningIds: Set<UUID> = []

    private var workers: [UUID: ConversationStore] = [:]
    private var timers: [UUID: Timer] = [:]

    private init() {}

    func isRunning(_ convId: UUID) -> Bool { runningIds.contains(convId) }

    /// 启动一个后台运行。调用方（ConversationStore.send）已经把用户消息写进共享会话。
    func start(conversation: ChatConversation, config: ModelConfig,
               reasoningLevel: Int, smartSearch: Bool) {
        let id = conversation.id
        guard workers[id] == nil else { return }

        let worker = ConversationStore(background: true)
        worker.conversations = [conversation]
        worker.selectedId = id
        workers[id] = worker
        runningIds.insert(id)
        ShellDiag.log("background run start conv=\(id)")
        AuditLog.shared.log("background.start", detail: "conv=\(id)")

        // appendUserMessage=false：用户消息已经在快照里，避免重复
        worker.send("", using: config, imageDataURLs: nil,
                    reasoningLevel: reasoningLevel, smartSearch: smartSearch,
                    appendUserMessage: false)

        // 轮询替代回调：worker 的 isLoading 是 @Published，结束时机分散在
        // runLoop/handleDispatchResult/cancel 等多处，集中改太容易漏；0.5s 轮询最稳。
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard let w = self.workers[id] else { return }
            if !w.isLoading { self.finish(id: id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[id] = timer
    }

    private func finish(id: UUID) {
        timers[id]?.invalidate()
        timers[id] = nil
        guard let worker = workers[id] else { return }
        let conv = worker.conversations.first { $0.id == id }
        workers[id] = nil
        runningIds.remove(id)

        if let conv = conv {
            // 合并必须在主线程（@Published 数组）
            if Thread.isMainThread {
                ConversationStore.shared.mergeBackgroundResult(conv)
            } else {
                DispatchQueue.main.async { ConversationStore.shared.mergeBackgroundResult(conv) }
            }
            let n = conv.messages.filter { $0.role == "assistant" }.count
            ShellDiag.log("background run finish conv=\(id) assistantMessages=\(n)")
            AuditLog.shared.log("background.finish", detail: "conv=\(id) msgs=\(n)")
        }
    }

    /// 用户删除会话时清掉对应后台任务
    func cancel(convId: UUID) {
        timers[convId]?.invalidate()
        timers[convId] = nil
        if let w = workers[convId] {
            w.cancelCurrent()
            workers[convId] = nil
        }
        runningIds.remove(convId)
    }
}
