// Xosvi × VansonMod 内存引擎桥接层
//
// 目的：把 VansonMod 的 VMMemoryEngine（ObjC++，异步 completion 回调风格）
// 包装成 Swift 侧可直接同步调用的接口，供 MCP `memory` 工具使用。
//
// 两个关键适配：
//   1. 引擎所有扫描 API 都是 dispatch_async 到全局队列 + completion block 回调；
//      MCP 工具要求同步返回结果，这里用 DispatchSemaphore 做「异步转同步」。
//      （必须在非主线程调用，否则阻塞主线程。）
//   2. 引擎需要先 attachToPid 拿到 task port；attach 失败要区分「进程不存在」和
//      「task_for_pid 被拒（签名/越狱环境问题）」两种原因。
//
// 许可证：本桥接层链接 VansonMod（GPL-3.0）编译产物，整体按 GPL-3.0 分发。

import Foundation
import Darwin

// ⚠️ 注意：必须 import 由 SwiftPM target `VansonEngine` 导出的模块。
// Package.swift 中 publicHeadersPath = "include"，伞形头 VansonEngine.h
// 只导出 VMMemoryEngine.h + VMLockEngine.h（都是纯 ObjC，可安全被 Swift 导入）。
import VansonEngine

/// 引擎数据类型（与 VansonMod 的 VMDataType 一一对应）
enum VansonValueType: String, CaseIterable {
    case int8, int16, int32, int64
    case uint8, uint16, uint32, uint64
    case float, double, string

    /// 映射到引擎的 VMDataType。
    /// 注意：VMMemoryEngine.h 里是 `typedef enum : NSUInteger {...} VMDataType`（匿名 C 枚举），
    /// Swift 侧以「结构体 + 静态常量」形式导入，没有 `rawValue:` 初始化器，必须直接用常量。
    var raw: VMDataType {
        switch self {
        case .int8:   return VMDataTypeInt8
        case .int16:  return VMDataTypeInt16
        case .int32:  return VMDataTypeInt32
        case .int64:  return VMDataTypeInt64
        case .uint8:  return VMDataTypeUInt8
        case .uint16: return VMDataTypeUInt16
        case .uint32: return VMDataTypeUInt32
        case .uint64: return VMDataTypeUInt64
        case .float:  return VMDataTypeFloat
        case .double: return VMDataTypeDouble
        case .string: return VMDataTypeString
        }
    }

    /// 该类型在内存中的字节宽度（string 不定长，返回 0）
    var byteWidth: Int {
        switch self {
        case .int8, .uint8:   return 1
        case .int16, .uint16: return 2
        case .int32, .uint32, .float: return 4
        case .int64, .uint64, .double: return 8
        case .string:         return 0
        }
    }

    /// 是否支持「模糊搜索」+「数值筛选」（字符串只能精确搜）
    var supportsFuzzy: Bool { self != .string }

    /// 常用别名，便于 AI 传参（int→int32, short→int16, byte→int8 等）
    static func parse(_ s: String?) -> VansonValueType? {
        guard let s = s?.lowercased() else { return nil }
        switch s {
        case "int", "integer", "i32", "dword", "int32": return .int32
        case "int64", "long", "qword", "i64":           return .int64
        case "int16", "short", "word", "i16":           return .int16
        case "int8", "byte", "i8":                      return .int8
        case "uint32", "u32":                           return .uint32
        case "uint64", "u64":                           return .uint64
        case "uint16", "u16":                           return .uint16
        case "uint8", "u8":                             return .uint8
        case "float", "f32":                            return .float
        case "double", "f64":                           return .double
        case "string", "str", "text":                   return .string
        default:                                        return VansonValueType(rawValue: s)
        }
    }
}

/// 引擎错误
enum VansonEngineError: LocalizedError {
    case notAttached
    case pidNotFound(Int32)
    case attachDenied(Int32, Int32)   // pid, kern_return
    case timeout(String)
    case invalidValue(String)
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .notAttached:
            return "尚未附加到任何进程，请先 memory attach"
        case .pidNotFound(let pid):
            return "进程不存在或已退出 (pid=\(pid))"
        case .attachDenied(let pid, let kr):
            return "task_for_pid 被拒绝 (pid=\(pid), kr=\(kr))："
                 + "需 task_for_pid-allow entitlement；越狱环境还要求目标进程未被加固"
        case .timeout(let op):
            return "引擎操作超时：\(op)"
        case .invalidValue(let msg):
            return "参数无效：\(msg)"
        case .engine(let msg):
            return "引擎返回错误：\(msg)"
        }
    }
}

/// 内存引擎门面：单例，包装 VMMemoryEngine
final class VansonMemoryBridge {

    static let shared = VansonMemoryBridge()

    /// 底层引擎（VansonMod 原版单例）
    private var engine: VMMemoryEngine { VMMemoryEngine.shared() }

    /// 默认单次操作超时（秒）。全内存扫描大进程可能要几十秒，默认给足。
    var defaultTimeout: TimeInterval = 120

    /// 记录已 attach 的 pid，避免重复 attach 清空会话
    private(set) var attachedPid: pid_t = 0
    private(set) var attachedBundleID: String?

    private let lock = NSLock()

    private init() {}

    // MARK: - 进程附加

    /// 按 pid 附加。成功返回进程名，失败抛错。
    @discardableResult
    func attach(pid: pid_t) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        // pid 有效性先自己查一遍，便于区分「进程不存在」和「权限不足」
        if kill(pid, 0) != 0 && errno == ESRCH {
            throw VansonEngineError.pidNotFound(pid)
        }

        let eng = engine
        // 先看能否拿到 task port，失败时给准确原因（engine.attachToPid 内部失败只返回 NO）
        var task: mach_port_t = 0
        let kr = task_for_pid(mach_task_self_, pid, &task)
        if kr != KERN_SUCCESS {
            throw VansonEngineError.attachDenied(pid, Int32(kr))
        }
        mach_port_deallocate(mach_task_self_, task)

        guard eng.attach(toPid: pid) else {
            throw VansonEngineError.attachDenied(pid, Int32(kr))
        }
        attachedPid = pid
        attachedBundleID = eng.currentBundleID
        return eng.currentProcessName ?? "pid_\(pid)"
    }

    /// 当前附加状态
    var status: [String: Any] {
        let eng = engine
        return [
            "attached": attachedPid != 0,
            "pid": Int(attachedPid),
            "process": eng.currentProcessName ?? "",
            "bundle_id": eng.currentBundleID ?? "",
            "result_count": Int(eng.resultCount),
            "main_module": String(format: "0x%llx", eng.mainModuleAddress),
        ]
    }

    /// 引擎自检：确认静态库真的链进来了、单例可实例化、关键属性可读。
    /// 用于真机上快速判断「是我的用法有问题」还是「引擎没编进来」。
    /// 注意：只做只读检查，不 attach 任何进程（避免破坏用户当前会话）。
    var selfCheck: [String: Any] {
        let eng = engine
        return [
            "engine_class": NSStringFromClass(type(of: eng)),
            "singleton_ok": (eng === VMMemoryEngine.shared()),
            "result_limit": UInt64(eng.resultLimit),
            "float_tolerance": eng.floatTolerance,
            "attached_pid": Int(attachedPid),
            "attached": attachedPid != 0,
        ]
    }

    // MARK: - 异步转同步

    /// 把「completion(count, msg)」风格的引擎 API 转成同步返回值。
    /// 必须在非主线程调用。
    private func await(callback: (@escaping (UInt64) -> Void) -> Void) throws -> UInt64 {
        let sem = DispatchSemaphore(value: 0)
        var out: UInt64 = 0
        callback { n in
            out = n
            sem.signal()
        }
        if sem.wait(timeout: .now() + defaultTimeout) == .timedOut {
            throw VansonEngineError.timeout("scan")
        }
        return out
    }

    // MARK: - 搜索

    /// 首次精确搜索。返回结果数量。
    @discardableResult
    func searchExact(value: String, type: VansonValueType,
                     limit: Int = 2000, timeout: TimeInterval? = nil) throws -> (count: Int, message: String) {
        try requireAttached()
        let eng = engine
        if let timeout = timeout { defaultTimeout = timeout }
        // 临时放宽结果上限，扫完后恢复原值（引擎该属性是全局单例状态，别污染用户配置）
        let previousLimit = eng.resultLimit
        if limit > 0 { eng.resultLimit = UInt(limit) }
        defer { eng.resultLimit = previousLimit }

        let sem = DispatchSemaphore(value: 0)
        var count: UInt = 0
        var msg: String = ""
        eng.scanMemory(with: VMSearchModeExact, valStr: value, dataType: type.raw,
                       fuzzyType: VMFuzzyChanged, isNextSearch: false) { n, m in
            count = n
            msg = m ?? ""
            sem.signal()
        }
        if sem.wait(timeout: .now() + defaultTimeout) == .timedOut {
            throw VansonEngineError.timeout("search")
        }
        return (Int(count), msg)
    }

    /// 二次筛选（在上次结果集上按新值过滤）。
    @discardableResult
    func refine(value: String, type: VansonValueType) throws -> (count: Int, message: String) {
        try requireAttached()
        let eng = engine
        let sem = DispatchSemaphore(value: 0)
        var count: UInt = 0
        var msg: String = ""
        eng.scanMemory(with: VMSearchModeExact, valStr: value, dataType: type.raw,
                       fuzzyType: VMFuzzyChanged, isNextSearch: true) { n, m in
            count = n
            msg = m ?? ""
            sem.signal()
        }
        if sem.wait(timeout: .now() + defaultTimeout) == .timedOut {
            throw VansonEngineError.timeout("refine")
        }
        return (Int(count), msg)
    }

    /// 模糊搜索：greater / less / between / increased / decreased / changed / unchanged
    @discardableResult
    func searchFuzzy(mode: String, value: String, value2: String?,
                     type: VansonValueType) throws -> (count: Int, message: String) {
        try requireAttached()
        guard type.supportsFuzzy else {
            throw VansonEngineError.invalidValue("字符串类型不支持模糊搜索，请用 exact")
        }
        // VMFuzzyType 是匿名 C 枚举（VMMemoryEngine.h: VMFuzzyLess=0, Greater=1, Between=2,
        // IncreasedBy=3, DecreasedBy=4, Changed=5, Unchanged=6），用整数中转避免 Swift 导入差异。
        let fuzzyRaw: Int
        switch mode.lowercased() {
        case "greater", "gt":        fuzzyRaw = 1
        case "less", "lt":           fuzzyRaw = 0
        case "between", "range":     fuzzyRaw = 2
        case "increased", "inc":     fuzzyRaw = 3
        case "decreased", "dec":     fuzzyRaw = 4
        case "changed":              fuzzyRaw = 5
        case "unchanged", "same":    fuzzyRaw = 6
        default:
            throw VansonEngineError.invalidValue("未知模糊模式 \(mode)，可用 greater/less/between/increased/decreased/changed/unchanged")
        }
        // 显式映射到导出的常量（不依赖 rawValue: 初始化器的可用性）
        let fuzzy: VMFuzzyType
        switch fuzzyRaw {
        case 0:  fuzzy = VMFuzzyLess
        case 1:  fuzzy = VMFuzzyGreater
        case 2:  fuzzy = VMFuzzyBetween
        case 3:  fuzzy = VMFuzzyIncreasedBy
        case 4:  fuzzy = VMFuzzyDecreasedBy
        case 6:  fuzzy = VMFuzzyUnchanged
        default: fuzzy = VMFuzzyChanged
        }

        let input = (fuzzyRaw == 2)
            ? "\(value)~\(value2 ?? value)"
            : value

        let eng = engine
        let sem = DispatchSemaphore(value: 0)
        var count: UInt = 0
        var msg: String = ""
        eng.scanMemory(with: VMSearchModeFuzzy, valStr: input, dataType: type.raw,
                       fuzzyType: fuzzy, isNextSearch: false) { n, m in
            count = n
            msg = m ?? ""
            sem.signal()
        }
        if sem.wait(timeout: .now() + defaultTimeout) == .timedOut {
            throw VansonEngineError.timeout("fuzzy")
        }
        return (Int(count), msg)
    }

    /// 按条件筛选已有结果
    @discardableResult
    func filter(mode: String, value1: String, value2: String?,
                type: VansonValueType) throws -> (count: Int, message: String) {
        try requireAttached()
        // VMFilterMode: Less=0, Greater=1, Between=2, Increased=3, Decreased=4, Changed=5, Unchanged=6
        let filterRaw: Int
        switch mode.lowercased() {
        case "less", "lt":            filterRaw = 0
        case "greater", "gt":         filterRaw = 1
        case "between", "range":      filterRaw = 2
        case "increased", "inc":      filterRaw = 3
        case "decreased", "dec":      filterRaw = 4
        case "changed":               filterRaw = 5
        case "unchanged", "same":     filterRaw = 6
        default:
            throw VansonEngineError.invalidValue("未知筛选模式 \(mode)")
        }
        let f: VMFilterMode
        switch filterRaw {
        case 0:  f = VMFilterModeLess
        case 1:  f = VMFilterModeGreater
        case 2:  f = VMFilterModeBetween
        case 3:  f = VMFilterModeIncreased
        case 4:  f = VMFilterModeDecreased
        case 6:  f = VMFilterModeUnchanged
        default: f = VMFilterModeChanged
        }

        let eng = engine
        let sem = DispatchSemaphore(value: 0)
        var count: UInt = 0
        var msg: String = ""
        eng.filterResults(with: f, val1: value1, val2: value2 ?? value1,
                          type: type.raw) { n, m in
            count = n
            msg = m ?? ""
            sem.signal()
        }
        if sem.wait(timeout: .now() + defaultTimeout) == .timedOut {
            throw VansonEngineError.timeout("filter")
        }
        return (Int(count), msg)
    }

    // MARK: - 结果读取

    /// 分页读取结果（引擎一次返回单条，这里循环取）
    func results(offset: Int = 0, limit: Int = 50, type: VansonValueType) throws -> [[String: Any]] {
        try requireAttached()
        let eng = engine
        let total = Int(eng.resultCount)
        guard total > 0 else { return [] }

        let start = max(0, min(offset, total))
        let end = min(total, start + max(0, limit))
        var out: [[String: Any]] = []
        out.reserveCapacity(max(0, end - start))

        for i in start..<end {
            guard let item = eng.getResultItem(at: UInt(i), dataType: type.raw) else { continue }
            out.append([
                "index": Int(i),
                "address": String(format: "0x%llx", item.address),
                "address_dec": String(item.address),
                "value": item.valueStr ?? "",
                "type": type.rawValue,
            ])
        }
        return out
    }

    /// 结果总数
    var resultCount: Int {
        Int(engine.resultCount)
    }

    // MARK: - 读写

    /// 读单地址
    func read(address: UInt64, type: VansonValueType, length: Int = 0) throws -> String {
        try requireAttached()
        let eng = engine
        if type == .string {
            // 编码常量由 ObjC 侧 XosviVansonUTF8Encoding() 提供，
            // 避开 VMStringEncoding（NS_ENUM）在 Swift 侧的导入名差异
            return eng.readString(atAddress: address,
                                  encoding: XosviVansonUTF8Encoding(),
                                  maxBytes: UInt(max(1, length))) ?? ""
        }
        return eng.readAddress(address, type: type.raw) ?? ""
    }

    /// 写单地址
    @discardableResult
    func write(address: UInt64, value: String, type: VansonValueType) throws -> Bool {
        try requireAttached()
        let eng = engine
        if type == .string {
            return eng.writeString(atAddress: address, value: value,
                                   encoding: XosviVansonUTF8Encoding())
        }
        return eng.writeAddress(address, value: value, type: type.raw)
    }

    /// 读原始字节（hex）
    func readRaw(address: UInt64, length: Int) throws -> String {
        try requireAttached()
        // 注：readRawMemory:length: 的 length 是 size_t → Swift Int（不是 UInt）
        guard let data = engine.readRawMemory(address, length: max(1, length)) else {
            throw VansonEngineError.engine("读取失败（地址不可读或跨越不可访问区域）")
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// 写原始字节（hex 字符串）
    @discardableResult
    func writeRaw(address: UInt64, hex: String) throws -> Bool {
        try requireAttached()
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
                            .replacingOccurrences(of: "0x", with: "")
                            .replacingOccurrences(of: "0X", with: "")
        guard cleaned.count % 2 == 0, !cleaned.isEmpty,
              let data = engine.data(fromHexString: cleaned) else {
            // ObjC `dataFromHexString:` → Swift `data(fromHexString:)`（末尾 String 触发 id 前缀剥离）
            throw VansonEngineError.invalidValue("hex 必须是偶数长度的十六进制字符串")
        }
        return engine.writeRawData(data, toAddress: address)
    }

    // MARK: - 会话

    func clearResults() throws {
        try requireAttached()
        engine.clearSession()
    }

    /// 撤销上一次手动写入
    func undoLastWrite() -> Int {
        Int(engine.undoLastManualWriteBatch())
    }

    // MARK: - 工具方法

    /// 解析 "0x1234" / "1234" / 十进制 形式的地址
    static func parseAddress(_ s: String) -> UInt64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("0x") {
            return UInt64(t.dropFirst(2), radix: 16)
        }
        // 纯数字但很长（>= 9 位）时按十六进制理解更安全（内存地址通常很大）
        if let dec = UInt64(t), t.count < 9 { return dec }
        return UInt64(t, radix: 16)
    }

    private func requireAttached() throws {
        guard attachedPid != 0 else { throw VansonEngineError.notAttached }
    }
}
