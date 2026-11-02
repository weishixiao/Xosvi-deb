import Foundation

// MARK: - v8（PR-E2）：统一串行执行网关
//
// 文档 E2：「凡『扫全盘/枚举应用/写探针』都过它」。
// DeviceProbe.runLock、InjectionManager 串行约束此前是各写各的 NSLock；这里统一出口：
//   - 同类任务排队（key 区分域），队首执行、完成后显式唤醒下一个
//   - 与 ToolRegistry 的锁无关：只串行「重探测类」操作，不串行工具调度
//   - 支持超时，默认 60s
//
final class SerialGate {
    static let shared = SerialGate()

    /// 常用域
    static let probe = "probe"         // 设备探测 / 全盘枚举
    static let injection = "injection" // 注入 / 静注 / 回滚

    private struct Node {
        let ticket: String
        let sem: DispatchSemaphore
    }

    private var queue: [Node] = []
    private let lock = NSLock()
    private var counter = 0

    func run<T>(_ key: String, timeout: TimeInterval = 60, _ body: () throws -> T) rethrows -> T {
        counter += 1
        let ticket = "\(key)#\(counter)-\(UUID().uuidString.prefix(6))"
        let node = Node(ticket: ticket, sem: DispatchSemaphore(value: 0))
        var isHead = false

        lock.lock()
        queue.append(node)
        isHead = (queue.count == 1)
        lock.unlock()

        // 非队首：等队首完成后的显式唤醒（或超时降级为直接执行，避免探测死锁）
        if !isHead {
            _ = node.sem.wait(timeout: .now() + timeout)
        }

        defer {
            lock.lock()
            if let idx = queue.firstIndex(where: { $0.ticket == ticket }) {
                queue.remove(at: idx)
            }
            lock.unlock()
            // 唤醒下一个队首
            lock.lock()
            let next = queue.first
            lock.unlock()
            next?.sem.signal()
        }

        return try body()
    }
}