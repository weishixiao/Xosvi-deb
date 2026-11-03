import Foundation

// MARK: - v8.1：子代理并行派发（主代理 → 派发器 → N 个子代理并发 → 结果汇总）
//
// 已有 SubagentTool 是"一次一个任务"的串行版（自包含任务书 + 工具循环 + 轮次上限）。
// 这里按文档补并行层：
//   · SubagentTask：{title, prompt, tools} 三元组
//   · SubagentDispatcher：OperationQueue 限流并发（默认 3，防中转站 429/内存）
//   · 工具白名单收窄：子代理只给只读/分析类工具，禁止 inject/app 写操作/control
//     ——多个子代理并发做写操作会互相踩
//   · 每个子任务独立 OpenAIClient（实例内有 cancelled/streamTriedLevels 等状态，不能共用）
//   · prompt 自包含是成败关键：子代理看不到主对话，靠主代理把背景写全
//
// 复用现有 SubagentTool 的单任务执行核心（executeCore），串行版与并行版行为一致。

struct SubagentTask: Codable {
    var title: String = ""
    var prompt: String = ""
    var tools: [String] = []
    /// 派发后回填（不参与解码输入）
    var status: String = "pending"   // pending/running/done/failed
    var result: String = ""
}

enum SubagentDispatcher {

    /// 并发执行多个子任务，全部结束后回调（每个子任务一张步骤卡，状态实时更新）。
    static func runAll(tasks: [SubagentTask],
                       config: ModelConfig,
                       onUpdate: @escaping (Int, SubagentTask) -> Void,
                       completion: @escaping ([SubagentTask]) -> Void) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3   // 文档：并发上限 3，防限流/防内存
        var results = tasks
        let group = DispatchGroup()
        let lock = NSLock()

        for (idx, task) in tasks.enumerated() {
            group.enter()
            queue.addOperation {
                autoreleasepool {
                    var t = task
                    t.status = "running"
                    onUpdate(idx, t)
                    let r = runOne(task: t, config: config)
                    lock.lock()
                    t.status = r.ok ? "done" : "failed"
                    t.result = r.text
                    results[idx] = t
                    lock.unlock()
                    onUpdate(idx, t)
                    group.leave()
                }
            }
        }
        group.notify(queue: .global()) {
            completion(results)
        }
    }

    /// 单个子代理 = 一次受限的多轮工具循环（直接复用 SubagentTool 的执行核心，
    /// 保证轮次上限 / 熔断消费 / 上下文裁剪行为与串行版一致）。
    static func runOne(task: SubagentTask, config: ModelConfig) -> (ok: Bool, text: String) {
        let out = SubagentTool.executeCore(
            task: task.prompt,
            context: nil,
            tools: task.tools.isEmpty ? nil : task.tools.joined(separator: ","),
            exclude: nil,
            maxRounds: 12,
            config: config,
            reasoning: 1,
            progress: { round, note in
                // 并发下共用全局 progressHandler 会互相覆盖，静默处理——
                // 状态变化由 runAll 的 onUpdate 统一上报
                _ = (round, note)
            })
        return (out["ok"] as? Bool ?? false, out["result"] as? String ?? "")
    }
}
