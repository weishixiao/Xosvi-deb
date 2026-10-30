import Foundation

// MARK: - 工具定义

public struct ToolDefinition {
    public let name: String
    public let summary: String
    public let parameters: [String: String]
    /// v3.0.65：返回值说明——AI 知道工具返回什么字段
    public let returns: [String: String]
    /// v2.9.184：真机实测标记——true 表示该工具已在真机远程终端验证过 (OK或明确报错分类），
    /// 未验证的工具保持 false，避免"看起来能用"的假象。
    public let verified: Bool
    /// 工具分类 (用于 UI 分组显示）：injection / app_control / ui_control / device / filesystem / shell / browser / build / backup / cleanup / macro / knowledge / system / diagnose / analysis / automation / skills / debug / misc
    public let category: String
    /// 给 UI 看的中文描述 (为空则 fallback 到 summary）
    public let uiSummary: String
    /// v3.1.1：最低支持的 iOS 主版本 (如 16 表示 iOS 16+）。nil 表示所有版本都支持。
    public let minIOSMajor: Int?
    /// v3.1.1：最高支持的 iOS 主版本 (如 17 表示只支持到 iOS 17）。nil 表示无上限。
    public let maxIOSMajor: Int?
    /// v3.1.1：是否仅在越狱环境下可用 (true = 需要越狱）
    public let requiresJailbreak: Bool
    /// v3.1.1：是否仅在 TrollStore 环境下可用 (true = 需要 TrollStore）
    public let requiresTrollStore: Bool
    /// v3.1.26：是否仅远程终端可用 (true = 内置 AI 看不到，只在远程 API 可用）
    public let remoteOnly: Bool
    /// v3.2.0：前置条件/依赖顺序——调用本工具前必须先done的操作或必须满足的条件。
    /// 例：network.capture start 前置 "inject enable NetworkTweak"；memory search 前置 "attach 已injected MemoryTweak"。
    /// AI 规划任务时按此顺序执行，避免前置不满足就调用导致报错。
    public let prerequisites: [String]

    // MARK: v6.9.1 结构化参数（可选，未填则回退到 parameters 字典）

    /// 结构化参数定义——有类型 / 必填 / 枚举 / 正例。
    /// 填了就用它生成 JSON Schema（比 parameters 字典精确得多）；留空则用 parameters 兜底。
    public let paramSpecs: [ToolParam]

    /// 子命令级参数要求——让模型知道「inspect 只要 bundle_id」「enable 要 bundle_id+dylib_path」。
    public let variants: [ToolVariant]

    public init(name: String, summary: String, parameters: [String: String] = [:], returns: [String: String] = [:], verified: Bool = false, category: String = "misc", uiSummary: String = "", minIOSMajor: Int? = nil, maxIOSMajor: Int? = nil, requiresJailbreak: Bool = false, requiresTrollStore: Bool = false, remoteOnly: Bool = false, prerequisites: [String] = [], paramSpecs: [ToolParam] = [], variants: [ToolVariant] = []) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.returns = returns
        self.verified = verified
        self.category = category
        self.uiSummary = uiSummary
        self.minIOSMajor = minIOSMajor
        self.maxIOSMajor = maxIOSMajor
        self.requiresJailbreak = requiresJailbreak
        self.requiresTrollStore = requiresTrollStore
        self.remoteOnly = remoteOnly
        self.prerequisites = prerequisites
        self.paramSpecs = paramSpecs
        self.variants = variants
    }

    /// UI 显示用：优先 uiSummary (中文），否则 fallback 到 summary
    public var displaySummary: String {
        uiSummary.isEmpty ? summary : uiSummary
    }

    /// 展示用标记：已验证的工具前缀 ✅已检验
    public var verifiedMark: String {
        verified ? "✅ verified " : ""
    }

    /// v2.9.1：OpenAI / Responses API 要求工具名只能包含 a-zA-Z0-9_-，
    /// 而原版图中的工具名可能含中文、点、空格。转换为合法的 API 名。
    public var apiName: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var sanitized = name.components(separatedBy: allowed.inverted).joined(separator: "_")
        if sanitized.isEmpty { sanitized = "tool" }
        if sanitized.first?.isNumber ?? false { sanitized = "t_\(sanitized)" }
        return sanitized
    }
}

// MARK: - 工具协议

public protocol MCPTool {
    var definition: ToolDefinition { get }
    func invoke(_ params: [String: Any]) throws -> [String: Any]
}

public enum MCPError: Error, CustomStringConvertible {
    case unknownTool(String)
    case invalidParams(String)
    case failed(String)
    /// v2.9.125：CLI 式failed分类——code + 四分类原因 + 下一步建议。
    /// description 输出为一行：tool failed: [CODE] 原因 (分类）下一步：xxx
    case classified(String, code: String, reason: String, nextStep: String)

    public var description: String {
        switch self {
        case .unknownTool(let n): return "unknown tool: \(n)"
        case .invalidParams(let m): return "invalid params: \(m)"
        case .failed(let m): return "tool failed: \(m)"
        case .classified(let m, let code, let reason, let nextStep):
            return "tool failed: [\(code)] \(m) (category: \(reason)) next: \(nextStep)"
        }
    }
}

// MARK: - CLI 式返回协议 (v2.9.125）

/// failed四分类 (对齐 Linux exit code 语义）：环境 / 目标 / 参数 / 工具自身 / 未知。
/// 放 dispatch 统一分类，工具层无需逐个改 throw 点。
enum FailureKind {
    static func classify(_ message: String) -> (code: String, reason: String, nextStep: String) {
        let m = message.lowercased()
        // 0) opainject 内存注入专项：被拒 (反调试/架构/权限）→ 明确降级路径
        if m.contains("opainject") || m.contains("dlopen") || m.contains("memory injection") {
            return ("INJECT_MEM_FAILED", "target",
                    "memory injection rejected (anti-debug/arch/permission). Try injection.enable file injection (auto backup, rollback OK), manual injection with TrollFools, or run app.decrypt for big-company Apps")
        }
        // 1) 环境：权限 / Entitlements / setuid / 容器写 / 未开权限
        if m.contains("operation not permitted") || m.contains("entitlement")
            || m.contains("setuid") || m.contains("denied") || m.contains("permission")
            || m.contains("未开启") || m.contains("未生效") {
            return ("ENV_PERMISSION", "environment",
                    "enable \"Edit Entitlements\" in TrollStore, reinstall Xosvi, then retry")
        }
        // 2) 目标：加密 / 架构 / 兼容 / 闪退 / 无法启动 / 不可注入
        if m.contains("加密") || m.contains("cryptid") || m.contains("encrypted")
            || m.contains("架构") || m.contains("arch") || m.contains("闪退")
            || m.contains("兼容") || m.contains("无法启动") || m.contains("不可注入")
            || m.contains("没有可注入") {
            return ("TARGET_INCOMPATIBLE", "target",
                    "target App incompatible with dylib (encryption/arch/dependency); switch to a matching target, decrypt first, or check plugin compatibility")
        }
        // 3) 参数：not found / 不存在 / 参数 / bundle_id 等
        // v7.15.1：删掉裸 "bundle"——"bundle 写入被拒"这类权限问题会被误判成参数错误，
        // 只有明确提到 bundle_id 才归为参数问题。
        if m.contains("not found") || m.contains("不存在") || m.contains("未找到")
            || m.contains("参数") || m.contains("invalid") || m.contains("bundle_id") {
            return ("PARAM_INVALID", "parameter",
                    "check param name/value against the tool description (bundle_id / path / name) and retry; missing required params are listed in the error message with usage example")
        }
        // 4) 工具自身：缺组件 / 执行failed / 超时
        if m.contains("未内置") || m.contains("missing") || m.contains("超时")
            // v7.15.1：第二个 "failed" 是复制粘贴错误，本意是中文"失败"，中文错误信息永不命中
            || m.contains("timeout") || m.contains("failed") || m.contains("失败") {
            return ("TOOL_FAILED", "tool",
                    "tool execution failed, inspect detail/logs or retry once")
        }
        return ("UNKNOWN", "unknown", "inspect full logs then retry")
    }

    /// 判断这个错误能不能自动重试
    static func retryable(_ message: String) -> Bool {
        let m = message.lowercased()
        // 网络错误/超时：可以重试
        if m.contains("timeout") || m.contains("超时")
            || m.contains("network") || m.contains("网络")
            || m.contains("connection") || m.contains("连接")
            || m.contains("unreachable") || m.contains("不可达") {
            return true
        }
        // 临时错误：可以重试
        if m.contains("temporary") || m.contains("临时")
            || m.contains("busy") || m.contains("忙") {
            return true
        }
        // 参数错误/权限错误/目标不兼容：不能重试
        return false
    }

    /// 兜底OK一句话 (工具未提供 message 时生成）。
    /// v2.9.125：智能提取器——按 布尔状态 → 数量 → status/summary → 首字段 顺序
    /// 从返回里提取最有信息量的一句，让全部 162 个工具都有可读结论 (而非"xx执行OK"）。
    static func defaultSuccessMessage(name: String, result: [String: Any]) -> String {
        // ① 布尔状态类 (按词义生成"动作+OK/failed"）
        let boolVerb: [String: String] = [
            "injected": "injected", "ready": "ready", "started": "started", "running": "running",
            "success": "done", "found": "found", "deleted": "deleted", "created": "created",
            "updated": "updated", "removed": "removed", "connected": "connected", "loaded": "loaded",
            "installed": "installed", "enabled": "enabled", "disabled": "disabled", "restored": "restored",
            "cleaned": "cleaned", "written": "written", "saved": "saved", "downloaded": "downloaded",
            "sent": "sent", "completed": "completed", "active": "active", "available": "available",
            "canceled": "canceled", "killed": "killed", "resumed": "resumed", "paused": "paused",
            "exists": "exists", "is_core": "resident", "valid": "valid", "compatible": "compatible"
        ]
        // v7.15.1：Dictionary 遍历顺序每进程随机，同一份结果会得出 "injectedOK"
        // 或 "readyfailed" 两种结论。改为固定优先级顺序，保证可复现。
        let boolOrder = ["injected", "ready", "started", "running", "success", "found",
                         "deleted", "created", "updated", "removed", "connected", "loaded",
                         "installed", "enabled", "disabled", "restored", "cleaned", "written",
                         "saved", "downloaded", "sent", "completed", "active", "available",
                         "canceled", "killed", "resumed", "paused", "exists", "is_core",
                         "valid", "compatible"]
        for key in boolOrder {
            if let verb = boolVerb[key], let v = result[key] as? Bool {
                return "\(verb)\(v ? "OK" : "failed")"
            }
        }
        // ② 数量类 (total/count/matched 等用"条"，size/bytes 用"字节"）
        let countKeys = ["total", "count", "matched", "found",
                         "apps", "tools", "files", "records", "items"]
        for key in countKeys {
            if let n = result[key] as? Int {
                return "total \(n)"
            }
        }
        for key in ["size", "bytes"] {
            if let n = result[key] as? Int {
                return n >= 1048576 ? "\(String(format: "%.1f", Double(n) / 1048576)) MB"
                    : n >= 1024 ? "\(String(format: "%.1f", Double(n) / 1024)) KB"
                    : "\(n) bytes"
            }
        }
        // ③ 状态/结论类字段
        for key in ["status", "verdict", "summary", "result", "state", "conclusion"] {
            if let s = result[key] as? String, !s.isEmpty {
                return s.count > 60 ? String(s.prefix(60)) + "…" : s
            }
        }
        // ④ 首个有值的简短字段 (排除大对象/长文本）
        for (k, v) in result {
            if k == "ok" || k == "message" || k == "data" || k == "error" { continue }
            if let s = v as? String, !s.isEmpty, s.count <= 40 {
                return "\(k)=\(s)"
            }
            if let n = v as? NSNumber {
                return "\(k)=\(n)"
            }
        }
        // ⑤ 终极兜底
        return "\(name) OK"
    }
}

// MARK: - v7.15.2：按 run 作用域的熔断标志

/// 熔断只应终止**触发它的那一轮 run**，不应波及其它会话/后台任务。
/// token 由 ConversationStore 在每次 send 时生成，后台线程通过 RunScope.currentToken 携带。
enum RunScope {
    private static let threadKey = "xosvi.run.token"
    private static let lock = NSLock()
    private static var abortedTokens: Set<UUID> = []
    /// 没绑 token 时的旧行为兜底（保证未迁移调用点仍能编译且语义不变）
    private static var abortedWithoutToken = false

    static var currentToken: UUID? {
        get { Thread.current.threadDictionary[threadKey] as? UUID }
        set {
            if let v = newValue { Thread.current.threadDictionary[threadKey] = v }
            else { Thread.current.threadDictionary.removeObject(forKey: threadKey) }
        }
    }

    static func requestAbort() {
        lock.lock(); defer { lock.unlock() }
        if let t = currentToken { abortedTokens.insert(t) } else { abortedWithoutToken = true }
    }

    static func requestAbort(token: UUID?) {
        lock.lock(); defer { lock.unlock() }
        if let t = token { abortedTokens.insert(t) } else { abortedWithoutToken = true }
    }

    static func peekAbort() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let t = currentToken, abortedTokens.contains(t) { return true }
        return abortedWithoutToken
    }

    static func clearCurrentAbort() {
        lock.lock(); defer { lock.unlock() }
        if let t = currentToken { abortedTokens.remove(t) }
        abortedWithoutToken = false
    }

    /// 消费式读取：必须传 runToken，主线程没绑 currentToken，读属性会落到兜底槽位。
    static func consumeAbort(_ token: UUID?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let t = token, abortedTokens.remove(t) != nil { return true }
        if abortedWithoutToken { abortedWithoutToken = false; return true }
        return false
    }

    static func clear(_ token: UUID?) {
        guard let t = token else { return }
        lock.lock(); abortedTokens.remove(t); lock.unlock()
    }
}

// MARK: - 注册表

public final class ToolRegistry: ObservableObject {
    /// v6.6.21：熔断触发后置位，ConversationStore 消费后终止本次 run
    /// v7.15.2：熔断标志改为 **run 作用域**（RunScope）。
    /// 旧版是全局 static：A 会话后台跑着，B 会话熔断 → A 也被终止，
    /// BackgroundRunManager 的会话隔离被一行代码破功。
    /// 保留同名计算属性，未迁移的调用点行为不变（走兜底槽位）。
    static var abortRunRequested: Bool {
        get { RunScope.peekAbort() }
        set { newValue ? RunScope.requestAbort() : RunScope.clearCurrentAbort() }
    }
    public static let shared = ToolRegistry()

    private var tools: [String: MCPTool] = [:]
    /// v3.1.8：公开工具总数
    // v7.15.1：register() 加锁而读取不加锁，Swift Dictionary 并发读写是未定义行为
    // （BackgroundRunManager 多会话并发调工具时实测 SIGSEGV）。读取一律加锁。
    public var toolCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tools.count
    }
    private var apiNameToOriginal: [String: String] = [:]
    private let lock = NSLock()
    private let disabledKey = "xosvi.disabled_tools"
    /// v2.9.22：会话内已授权工具 (AI 调用即自动放行，无需用户手动开 Toggle）。新会话时清空。
    private var sessionApproved: Set<String> = []
    /// v2.9.26：策略版本号。setEnabled 时递增，通过 @Published 可靠触发
    /// 工具权限策略页刷新 (修复 iOS16 List 内 Toggle 只靠 objectWillChange.send()
    /// 刷新不可靠、开关点了没反应/弹回的问题）。
    @Published private(set) var policyRevision = 0

    // v3.0.90：循环提示——记录调用次数，告诉 AI 它调了几次，让 AI 自己判断
    // 不硬拦截，AI 有全局视角，自己决定要不要继续
    private var recentCalls: [String: [Date]] = [:]
    private let loopWindow: TimeInterval = 60.0  // 1 分钟窗口
    // v6.9.0：阈值 3 → 2。同一参数连续失败 2 次就熔断并给替代方案——
    // 实测 AI 在第 3 次被拦时已经浪费两次往返，且往往还没意识到自己能换工具。
    private let loopThreshold = 2

    // v6.9.0：失败指纹跟踪——只有「同参数 + 同错误」才算循环。
    // 同参数但错误变化（如先 missing_param 后 permission）说明在推进，不该熔断。
    // key = callKey；value = (错误签名, 连续次数)
    private var failureStreak: [String: (signature: String, count: Int)] = [:]

    // v3.0.90：工具结果缓存——5 分钟内同样的调用直接返回缓存，省时间
    private var resultCache: [String: (result: [String: Any], time: Date)] = [:]
    // v4.3.26：缓存命中计数——同一调用连续第 2 次命中缓存时强制重取（防"同内容反复返回"，
    // 典型场景：浏览器页面已变化但 text/snapshot 因参数没变一直喂旧缓存）。
    private var cacheHitCounts: [String: Int] = [:]
    // v4.3.26：缓存绕过工具——有状态工具（浏览器页面内容随时可变）绝不能喂缓存。
    // web.* / workspace / browser.* 全部绕过：URL 变了 params 不变，旧缓存必错 (BUG-1/BUG-2 根因)。
    // v7.15.1：分两类补进来
    //   时效类 web —— 同 query 5 分钟后必须重抓，否则模型拿旧闻当"最新"复述；
    //   状态类 inject/app/rescue/engine —— 写操作成功后立刻读 status 必须看到新状态。
    private var cacheBypassPrefixes: [String] = ["workspace", "browser", "control",
                                                 "device.fake", "injection.mem",
                                                 "web", "inject", "app", "rescue", "engine"]
    private let defaultCacheWindow: TimeInterval = 300.0  // 默认 5 分钟缓存窗口
    private let longCacheWindow: TimeInterval = 1800.0  // 30 分钟缓存窗口 (静态数据）

    /// 哪些工具应该用长缓存 (静态数据，不常变）
    private let longCacheTools: Set<String> = [
        "fs_tree", "fs.list", "fs.ls",  // 文件列表
        "device.info", "device.probe",  // 设备信息
        "injection.list", "process.list",  // 进程列表
        "artifact.list", "macro.list",  // 列表类
        "skill.list", "skill.read",  // 技能列表
    ]

    /// v6.9.0：熔断报错——不只说「停」，还给出可执行的替代方案。
    ///
    /// 旧文案只喊 STOP，模型常常理解成「再试一次别的参数」，于是换个无关参数继续撞。
    /// 新文案明确列出：失败了几次、错误是什么、你传了什么、以及这批工具的替代选择。
    private func loopBlockedError(tool: String,
                                  params: [String: Any],
                                  errorMessage: String,
                                  count: Int) -> MCPError {
        let keys = params.keys.filter { !$0.hasPrefix("_") }.sorted()
        let passed = keys.isEmpty ? "(无)" : keys.joined(separator: ", ")
        let signature = ToolParamHelp.errorSignature(errorMessage)

        // v6.6.21：熔断必须真的结束本轮 run。
        // 实测：只返回一段"已停止本次调用"的文案，模型会把它当成又一条工具结果，
        // 继续用同样参数重试（真机连续 13 次）。这里置一个一次性标志，
        // 由 ConversationStore 在错误分支消费并终止循环。
        RunScope.requestAbort()   // v7.15.2：只终止当前 run

        var lines: [String] = []
        lines.append("🚫 已连续 \(count) 次用相同参数调用 \(tool)，错误都是同一类（\(signature)）。本次运行已终止。")
        lines.append("你传的参数: [\(passed)]")
        lines.append("错误原文: \(errorMessage.prefix(300))")
        lines.append("")
        lines.append("不要再用相同参数重试。请按下面选择一条路：")

        // 根据错误类型给针对性替代方案
        switch signature {
        case "missing_param":
            if keys.contains("path") && keys.contains("command") {
                lines.append("① 你很可能把 path 传给了只认 bundle_id 的子命令。改用:")
                for alt in ToolParamHelp.binaryCheckAlternatives() { lines.append("   - \(alt)") }
                lines.append("② 或者补上 bundle_id 后重试: \(tool) command:<子命令> bundle_id:<包名>")
                lines.append("   拿包名: \(ToolParamHelp.howToGetBundleId)")
            } else {
                lines.append("① 缺参数。按工具 description 的 parameters 列表补齐必填项后重试一次。")
                lines.append("② 如果拿不到这个参数所代表的东西，换一个能直接拿结果的工具。")
            }
        case "not_found":
            lines.append("① 确认路径/包名是否真实存在（先列出目录或列出已装 App）。")
            lines.append("② 名称含空格/中文时改用绝对路径直传。")
        case "permission", "encrypted":
            lines.append("① 权限类失败重试无意义。先跑诊断确认环境（如 inject command:diagnose / app command:diff）。")
            lines.append("② 加密 App 先砸壳: app command:decrypt → app command:replace_decrypted → 再操作。")
        case "unsupported_env":
            lines.append("① 这是当前环境不支持该 syscall（rootless/rootHide 下常见的 85 ENOSYS），重试无意义。")
            lines.append("② 换一条不需要提权/子进程路径：读二进制信息用 macho，读权限用 app command:entitlements。")
        case "network":
            lines.append("① 网络类失败稍后重试或换 endpoint，不要连续撞同一个地址。")
        default:
            lines.append("① 换一种工具或换一组参数。")
            lines.append("② 如果确实需要这个结果，把错误原文告诉用户，让他决定下一步。")
        }
        lines.append("")
        lines.append("如果以上都不适用，直接问用户，不要继续尝试。")

        return MCPError.failed(lines.joined(separator: "\n"))
    }

    /// v6.9.0：记录失败并返回是否应该熔断。
    /// 只有「同一 callKey + 同一错误签名」连续累计才计数；错误变了说明在推进，重置。
    private func noteFailure(callKey: String, errorMessage: String) -> (count: Int, blocked: Bool) {
        let sig = ToolParamHelp.errorSignature(errorMessage)
        if let prev = failureStreak[callKey], prev.signature == sig {
            let next = prev.count + 1
            failureStreak[callKey] = (sig, next)
            return (next, next >= loopThreshold)
        }
        failureStreak[callKey] = (sig, 1)
        return (1, false)
    }

    private func clearFailure(callKey: String) {
        failureStreak.removeValue(forKey: callKey)
    }

    private func callKey(name: String, params: [String: Any]) -> String {
        let sortedParams = params.sorted { $0.key < $1.key }
        let paramStr = sortedParams.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(name):\(paramStr)"
    }

    /// 根据工具名决定缓存窗口
    private func cacheWindow(for toolName: String) -> TimeInterval {
        if longCacheTools.contains(toolName) {
            return longCacheWindow
        }
        return defaultCacheWindow
    }

    private func recordCall(name: String, params: [String: Any]) -> Int {
        let key = callKey(name: name, params: params)
        let now = Date()
        // 清理过期记录
        recentCalls[key] = (recentCalls[key] ?? []).filter { now.timeIntervalSince($0) < loopWindow }
        recentCalls[key]?.append(now)
        if recentCalls[key] == nil { recentCalls[key] = [now] }
        return recentCalls[key]?.count ?? 1
    }

    /// v3.0.90：查缓存——5 分钟内同样的调用直接返回缓存结果
    private func getCachedResult(name: String, params: [String: Any]) -> [String: Any]? {
        let key = callKey(name: name, params: params)
        guard let cached = resultCache[key] else { return nil }
        // 过期了
        let window = cacheWindow(for: name)
        if Date().timeIntervalSince(cached.time) > window {
            resultCache.removeValue(forKey: key)
            return nil
        }
        return cached.result
    }

    /// v3.0.90：存缓存
    private func cacheResult(name: String, params: [String: Any], result: [String: Any]) {
        let key = callKey(name: name, params: params)
        resultCache[key] = (result, Date())
        // 清理过期缓存
        let now = Date()
        for (k, v) in resultCache {
            let window = cacheWindow(for: k.components(separatedBy: ":").first ?? "")
            if now.timeIntervalSince(v.time) > window {
                resultCache.removeValue(forKey: k)
            }
        }
    }

    public func register(_ tool: MCPTool) {
        lock.lock()
        tools[tool.definition.name] = tool
        lock.unlock()
    }

    /// v3.0.71：外部 dylib 注册工具 (AI 自我进化——AI 写 dylib 注入自己，注册新工具）
    public func registerExternalTool(_ def: ToolDefinition, handler: @escaping ([String: Any]) throws -> [String: Any]) {
        // v3.0.90：安全检查——AI 自写工具的规则
        let name = def.name.lowercased()

        // 1. 不能覆盖内置工具
        if !name.hasPrefix("custom.") && !name.hasPrefix("user.") {
            print("[TA] ❌ external tool rejected: name must start with 'custom.' or 'user.' (got \(def.name))")
            return
        }

        // 2. 不能包含危险关键词
        let dangerousKeywords = ["shell", "exec", "root", "inject", "download", "upload", "delete", "rm", "sudo", "privileged"]
        for kw in dangerousKeywords {
            if name.contains(kw) {
                print("[TA] ❌ external tool rejected: name contains dangerous keyword '\(kw)'")
                return
            }
        }

        // 3. 不能和现有工具冲突
        if tools[def.name] != nil {
            print("[TA] ❌ external tool rejected: name already exists \(def.name)")
            return
        }

        // 通过检查，注册
        let wrapper = ExternalMCPTool(definition: def, handler: handler)
        register(wrapper)
        print("[TA] ✅ external tool registered: \(def.name)")
    }

    public var definitions: [ToolDefinition] {
        // v3.0.90 曾去掉锁（"只读"），但 register() 是有锁的写——
        // Dictionary 并发读写未定义，多会话并发时实测 SIGSEGV。
        lock.lock(); defer { lock.unlock() }
        return tools.values.map { $0.definition }.sorted { $0.name < $1.name }
    }

    // v2.9.71：本地 HTTP 服务需要的工具查询接口
    public func allToolNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return tools.keys.sorted()
    }

    public func tool(named name: String) -> MCPTool? {
        lock.lock(); defer { lock.unlock() }
        return tools[name]
    }

    /// v2.9.15：聊天默认工具白名单。
    /// v3.1.66：工具已精简为 22 个大工具，全部默认启用 (shell.exec / app / inject / control 等），
    /// 新装用户开箱即用；用户手动开/关过的仍以显式状态为准。
    private static let defaultEnabledTools: Set<String> = [
        // v3.1.66：全量注册工具默认启用
        "artifact", "device", "memory", "assistant_memory", "verify", "container",
        "ssh", "diagnose", "knowledge", "location", "macro", "app", "control",
        "inject", "automation", "network.capture", "server", "project", "workspace", "subagent", "ghost",
        "shell.exec", "reminder", "rescue",
        // v4.3.65：统一工具安装闭环
        "tool.install", "env.setup_re",
        // v4.3.65：补齐"已注册但漏在白名单外"的分析工具——否则 AI 看不到 db/file/package，
        // 无法用原生 sqlite3 直读 App 数据容器、无法解包分析；vpn.capture 随 VPN 抓包恢复一并默认启用；
        // skills.* 让技能系统真正按需加载生效
        "file", "db", "package", "vpn.capture",
        "skills.list", "skills.read", "skills.set_enabled",
        // v4.3.65：恢复注册的联网检索工具（多引擎回退 + 多 query 并行 + 正文抽取）
        "web.search", "web.fetch",
        // v4.3.66：按需绑定 App 数据容器（bind_app 只读安全，bind_app_write 可写先备份，
        // app_write_file 原生直写先备份）——否则"小白一句话分析/改 App 数据"时 AI 看不到这些工具
        "bind_app", "bind_app_write", "app_write_file",
        // v7.6.5：github 工具已移除
        // v7.14.0：jb-p1lot 真机桥接（未安装二进制时工具会明确提示先 install，不会空转）
        "jb",
        // v7.16.0：原生 Git（无子进程），越狱机器上唯一可用的仓库读写通道
        "git"
    ]

    /// v2.9.31：常驻核心工具名集合 (UI 用只读访问）
    public static var coreToolNames: Set<String> { Self._coreToolNames }

    /// v2.9.31：判断工具是否常驻核心 (初始请求自动加载，无需搜索）
    /// v3.0.73：根据当前系统指令模式智能叠加常驻工具
    public func isCore(_ name: String) -> Bool {
        if Self.coreToolNames.contains(name) { return true }
        // v6.9.10：自动路由下任何模式都可能被选中，取全部模式工具的并集，
        // 避免 AI 判定为某模式后却发现其核心工具未加载。
        if SystemPrompts.shared.autoRoutingEnabled {
            return SystemPrompts.shared.allExtraCoreTools.contains(name)
        }
        // 叠加当前模式的额外常驻工具
        let extra = SystemPrompts.shared.currentExtraCoreTools
        return extra.contains(name)
    }

    /// v2.9.31：常驻核心工具 (历史渐进披露设计，tool_search 已删，现仅作 UI 参考）。
    private static let _coreToolNames: Set<String> = [
        // 最常用：终端 (代替了 artifact）
        "shell.exec",
        // 最常用：截图
        "control.screenshot"
    ]

    public func isEnabled(name: String) -> Bool {
        // v2.9.24：改用显式状态字典。用户手动开/关过的工具以显式值为准；
        // 未设置过的工具按白名单决定默认启用。修复"非白名单工具手动开启无效"bug。
        let states = UserDefaults.standard.object(forKey: disabledKey) as? [String: Bool] ?? [:]
        if let v = states[name] { return v }
        return Self.defaultEnabledTools.contains(name)
    }

    /// v2.9.22：授权某工具在本会话内可调用 (绕过策略禁用）。
    /// v2.9.31：AI 调用即自动授权，无弹窗。
    public func approveForSession(_ name: String) {
        lock.lock()
        sessionApproved.insert(name)
        lock.unlock()
    }

    /// v2.9.175：本会话已授权工具名 (原名，仅返回已注册的），
    /// 供跨消息持久注入——AI 每轮新消息都能看到调用过的工具 schema，
    /// 根治"调用过 app.decrypt 但下一轮够不到"。
    public func approvedToolNames() -> [String] {
        // v3.0.90：去掉锁——只读操作
        return Array(sessionApproved).filter { tools[$0] != nil }
    }

    /// v2.9.22：清空会话授权 (新会话时调用）。
    public func clearSessionApproval() {
        lock.lock()
        sessionApproved.removeAll()
        lock.unlock()
    }

    public func isSessionApproved(_ name: String) -> Bool {
        // v3.0.90：去掉锁——只读操作
        return sessionApproved.contains(name)
    }

    public func setEnabled(name: String, enabled: Bool) {
        // v2.9.24：直接写显式状态 (true=启用，false=禁用），而非删除 key。
        // 修复"非白名单工具手动开启后开关弹回"bug (旧实现 removeValue 后回落白名单）。
        var states = UserDefaults.standard.object(forKey: disabledKey) as? [String: Bool] ?? [:]
        states[name] = enabled
        UserDefaults.standard.set(states, forKey: disabledKey)
        // v2.9.26：@Published 递增 + objectWillChange 双保险，确保 UI 立即刷新
        policyRevision += 1
        objectWillChange.send()
        AuditLog.shared.log("policy", detail: "\(name) \(enabled ? "启用" : "禁用")")
    }

    public var enabledDefinitions: [ToolDefinition] {
        // v3.1.26: 过滤掉 remoteOnly 工具——内置 AI 看不到，只在远程 API 可用
        definitions.filter { isEnabled(name: $0.name) && !$0.remoteOnly }
    }

    /// v2.9.1：生成给 OpenAI API 用的工具 schema，同时建立 apiName → 原名映射，
    /// 供 dispatch 把模型返回的安全名转回真实工具名。
    /// v3.1.66：全量加载所有已启用工具 (tool_search 已删除，不再按 isCore 渐进披露）。
    /// 工具已精简为约 23 个大工具，全量 schema token 占用可控，AI 一次即可看到全部工具。
    public func enabledOpenAIToolSchema() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let defs = tools.values.map { $0.definition }.filter { isEnabled(name: $0.name) }
        var used = Set<String>()
        var map = [String: String]()
        var result: [[String: Any]] = []
        for def in defs {
            var safe = def.apiName
            var suffix = 1
            while used.contains(safe) {
                safe = "\(def.apiName)_\(suffix)"
                suffix += 1
            }
            used.insert(safe)
            map[safe] = def.name

            // v6.9.1：优先用结构化 paramSpecs 生成精确 schema（有类型/枚举/正例/必填）；
            // 未迁移的工具回退到旧的 [String: String] 全 string 逻辑。
            var props: [String: Any] = [:]
            var required: [String] = []

            if !def.paramSpecs.isEmpty {
                for spec in def.paramSpecs {
                    props[spec.name] = spec.schemaFragment()
                    if spec.required { required.append(spec.name) }
                }
            } else {
                for (k, v) in def.parameters {
                    props[k] = ["type": "string", "description": v]
                }
            }

            // v3.1.66：required 只保留子命令选择器 (command/action），其余参数按子命令按需提供。
            // v3.1.69：显式找 command/action 键——Dictionary.keys 是哈希顺序，prefix(1) 可能
            // 落到任意参数 (如 artifact 的 name），导致 AI 被迫填无关参数 (AI 反馈实锤）。
            let selectorCandidates = def.paramSpecs.isEmpty
                ? Array(def.parameters.keys)
                : def.paramSpecs.map(\.name)
            if let selectorKey = selectorCandidates.first(where: { $0 == "command" || $0 == "action" }) {
                if !required.contains(selectorKey) { required.append(selectorKey) }
            }

            // v3.2.0：description 追加前置条件——AI 看到工具定义即知依赖顺序，不用撞错误才知道
            var desc = def.summary
            if !def.prerequisites.isEmpty {
                desc += " 前置条件: " + def.prerequisites.joined(separator: "; ") + "。不满足时先执行前置步骤再调用本工具，不要直接调用。"
            }
            // v6.9.1：把每个子命令的参数要求压成速查表附在描述里。
            // 这是解决「inspect 到底要 bundle_id 还是 path」这类困惑的关键——
            // 模型不必从 19 个子命令的公共参数池里猜。
            if !def.variants.isEmpty {
                desc += " 子命令参数速查: "
                desc += def.variants.map { $0.cheatsheet }.joined(separator: " | ")
                desc += "。按所选子命令只传它需要的参数。"
            }
            result.append([
                "type": "function",
                "function": [
                    "name": safe,
                    "description": desc,
                    "parameters": [
                        "type": "object",
                        "properties": props,
                        "required": required
                    ]
                ]
            ])
        }
        apiNameToOriginal = map
        return result
    }

    /// v3.1.3：向量语义搜索缓存——工具描述的词袋向量 (简化版，不需要 embedding 模型）
    private var toolVectors: [String: [String: Double]] = [:]
    private var toolVectorsLoaded = false

    /// v3.1.3：预计算所有工具的词袋向量 (简化版语义搜索）
    private func loadToolVectors() {
        guard !toolVectorsLoaded else { return }
        toolVectorsLoaded = true
        for (_, tool) in tools {
            let text = (tool.definition.name + " " + tool.definition.summary).lowercased()
            var vector: [String: Double] = [:]
            // 简单分词：按空格和标点分词
            let words = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            for word in words {
                vector[word, default: 0] += 1
            }
            toolVectors[tool.definition.name] = vector
        }
    }

    /// v3.1.3：计算两个词袋向量的余弦相似度
    private func cosineSimilarity(_ a: [String: Double], _ b: [String: Double]) -> Double {
        var dotProduct: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for (key, valA) in a {
            normA += valA * valA
            if let valB = b[key] {
                dotProduct += valA * valB
            }
        }
        for valB in b.values {
            normB += valB * valB
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dotProduct / (normA.squareRoot() * normB.squareRoot())
    }

    /// 按关键词搜索工具名/摘要，返回紧凑清单 (供 UI 搜索，历史 API 保留）
    /// v3.0.90：去重——已会话授权的工具不再重复返回，避免 AI 反复搜以为能找到新工具
    public func searchTools(query: String, limit: Int = 0) -> [[String: String]] {
        // v3.0.90：去掉锁——只读操作，不需要锁，避免死锁
        // v3.1.1：iOS 版本过滤——不支持当前 iOS 版本的工具不返回
        let iosMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let jbStatus = InjectionManager.shared.jailbreakStatus()
        let isJailbroken = jbStatus["is_jailbroken"] as? Bool ?? false

        // v3.0.99: 同义词映射——用户说中文，工具描述是英文，做个映射
        let synonyms: [String: [String]] = [
            "截图": ["screenshot", "screen"],
            "抓包": ["network.capture", "network", "packet", "proxy", "http"],
            "网络抓包": ["network.capture", "network", "packet", "proxy"],
            "网络分析": ["network.capture", "network", "http", "request"],
            "请求": ["network.capture", "http", "request", "api"],
            "请求清单": ["network.capture", "network", "http"],
            "截屏": ["screenshot", "screen"],
            "屏幕": ["screenshot", "screen", "ui"],
            "网页": ["web.search", "web.fetch", "url"],
            "浏览器": ["web", "workspace"],
            "网页内容": ["web.fetch", "web.search"],
            "文本": ["text", "content"],
            "识别": ["ocr", "recognize", "extract"],
            "文字": ["ocr", "text"],
            "注入": ["inject", "injection", "jailbreak"],
            "越狱": ["jailbreak", "ellekit", "injection.enable"],
            "越狱注入": ["injection.enable", "jailbreak"],
            "安装": ["install", "ipa"],
            "卸载": ["uninstall"],
            "启动": ["launch", "app.launch"],
            "重启": ["restart", "app.restart"],
            "进程": ["process", "ps"],
            "文件": ["fs", "file"],
            "读": ["read", "artifact"],
            "写": ["write", "artifact"],
            "目录": ["tree", "ls", "shell.exec"],
            "终端": ["shell", "exec"],
            "命令": ["shell", "exec", "command"],
            "点击": ["tap", "click"],
            "点": ["tap", "click"],
            "输入": ["type", "input"],
            "滑动": ["swipe", "scroll"],
            "滚动": ["swipe", "scroll"],
            "设备": ["device", "info"],
            "系统": ["device", "system"],
            "编译": ["build", "compile", "build.runner"],
            "构建": ["build", "compile"],
            "自写工具": ["tool.load_dylib", "self-evolution", "load_dylib"],
            "自我进化": ["tool.load_dylib", "self-evolution"],
            "加载新工具": ["tool.load_dylib", "load_dylib"],
            "写个工具": ["tool.load_dylib", "write_tool", "build"],
        ]

        let q = query.lowercased()
        var hits: [(name: String, summary: String, score: Double)] = []
        loadToolVectors()  // v3.1.3：预计算工具向量 (词袋版）

        // v3.1.3：计算查询的词袋向量
        var queryVector: [String: Double] = [:]
        if !q.isEmpty {
            let queryWords = q.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            for word in queryWords {
                queryVector[word, default: 0] += 1
            }
        }

        for (_, tool) in tools {
            let def = tool.definition
            // v3.1.9: 不跳过任何工具——全部返回，AI 一次看完全部
            // 只按 iOS 版本和越狱环境过滤

            // v3.1.1：iOS 版本过滤
            if let minV = def.minIOSMajor, iosMajor < minV { continue }
            if let maxV = def.maxIOSMajor, iosMajor > maxV { continue }

            // v3.1.1：越狱环境过滤
            if def.requiresJailbreak && !isJailbroken { continue }

            let nameL = def.name.lowercased()
            let sumL = def.summary.lowercased()
            var score: Double = 0
            if !q.isEmpty {
                // v3.1.0: 类别前缀匹配——搜 "browser" 就返回同前缀的工具
                if nameL.hasPrefix(q + ".") || nameL.hasPrefix(q + "_") {
                    score += 10  // 类别匹配权重最高
                }
                if nameL.contains(q) { score += 3 }
                if sumL.contains(q) { score += 2 }
                // 简单分词：每个词命中加分
                let queryWords = q.split(separator: " ").map({ String($0) }).filter { !$0.isEmpty }
                for w in queryWords {
                    if nameL.contains(w) { score += 1 }
                    if sumL.contains(w) { score += 1 }
                }
                // v3.0.99: 同义词匹配
                for (cn, enList) in synonyms {
                    if query.contains(cn) {
                        for en in enList {
                            if nameL.contains(en.lowercased()) { score += 2 }
                            if sumL.contains(en.lowercased()) { score += 1 }
                        }
                    }
                }
                // v3.1.3: 类别速查表——常见任务 → 对应的工具类别
                let categoryMap: [String: [String]] = [
                    "截图": ["ui.screenshot", "control.screenshot", "ui"],
                    "抓包": ["network.capture", "debug.dump_network_log"],
                    "注入": ["injection", "injection.enable", "control.inject"],
                    "文件": ["fs.", "bridge.", "artifact."],
                    "浏览器": ["web.", "workspace"],
                    "自动化": ["automation.", "macro.", "task.run"],
                    "清理": ["cleanup.", "workspace.cleanup", "rescue."],
                    "编译": ["build.", "github."],
                    "崩溃": ["crash", "diagnose.", "log.collect"],
                    "设备": ["device.", "system.overview"],
                    "聊天": ["knowledge.", "assistant.memory"],
                    "微信": ["wechat."],
                    "定位": ["location."],
                    "备份": ["backup."],
                ]
                for (task, cats) in categoryMap {
                    if query.contains(task) {
                        for cat in cats {
                            if nameL.hasPrefix(cat) || nameL.contains(cat) {
                                score += 3
                            }
                        }
                    }
                }
                // v3.1.3: 词袋余弦相似度 (简化版，没下载模型时用）
                if let toolVec = toolVectors[def.name], !queryVector.isEmpty {
                    let sim = cosineSimilarity(queryVector, toolVec)
                    score += sim * 5  // 向量相似度权重
                }
            } else {
                score = 1
            }
            if score > 0 { hits.append((def.name, def.summary, score)) }
        }
        hits.sort { $0.score > $1.score }
        // v3.1.9: 返回全部可调用工具——AI 一次看完全部，不用反复搜
        // 只按 iOS 版本和越狱环境过滤，不过滤已授权的
        // limit=0 表示返回全部可调用工具
        if limit <= 0 {
            return hits.map { ["name": $0.0, "summary": $0.1] }
        }
        return hits.prefix(limit).map { ["name": $0.0, "summary": $0.1] }
    }

    /// 返回单个工具的完整 OpenAI function schema (供模型按名动态注入）
    public func openAISchema(for name: String) -> [String: Any]? {
        // v3.0.90：去掉锁——只读操作
        guard let tool = tools[name] else { return nil }
        let def = tool.definition
        var props: [String: [String: String]] = [:]
        for (k, v) in def.parameters {
            props[k] = ["type": "string", "description": v]
        }
        // v3.1.69：显式找 command/action 键 (见 enabledOpenAIToolSchema 注释——哈希顺序问题）
        let selectorKey = def.parameters.keys.first { $0 == "command" || $0 == "action" }
        return [
            "type": "function",
            "function": [
                "name": def.apiName,
                "description": def.summary,
                "parameters": [
                    "type": "object",
                    "properties": props,
                    "required": selectorKey.map { [$0] } ?? []
                ]
            ]
        ]
    }

    @discardableResult
    public func dispatch(name: String, params: [String: Any]) throws -> [String: Any] {
        // v3.0.90：去掉锁——只读操作 (查工具）
        var tool = tools[name]
        if tool == nil, let original = apiNameToOriginal[name] {
            tool = tools[original]
        }
        // v2.9.28：兜底解析——按 apiName (下划线安全名）反向匹配所有注册工具。
        // 修复：未启用/敏感工具不在 enabledOpenAIToolSchema 的 apiNameToOriginal 映射里，
        // 模型按 schema 返回 injection_enable 时 dispatch 找不到 → unknown tool。
        if tool == nil {
            tool = tools.values.first { $0.definition.apiName == name }
        }
        // v3.0.90：去掉 lock.unlock()，因为已经去掉了 lock.lock()
        guard let t = tool else { throw MCPError.unknownTool(name) }
        // v2.9.31：去掉授权弹窗。放行 = 策略启用 (isEnabled）或会话已授权。
        // 未加载/未启用工具直接返回错误，提示 AI 换用已加载工具，而不是弹窗打扰用户。
        let originalName = t.definition.name
        // v7.9.7：黑匣子——执行前先落盘工具名/参数。闪退时文件会停在 phase=start，
        // 下次启动 `diagnose lasttool` 就能知道是哪条调用把 App 带走的。
        ToolBlackBox.mark(tool: originalName, params: params, phase: "start")
        defer { ToolBlackBox.mark(tool: originalName, params: params, phase: "done") }
        // v2.9.34：放行 = 策略启用 或 会话已授权 或 常驻核心工具。
        // 修复 bug：coreToolNames 里的工具 (如 artifact.find）schema 已发给模型，
        // 但 defaultEnabledTools 未收录时 isEnabled 返回 false → 报"未加载"。
        // 常驻核心必然放行 (它本来就在初始请求里，用户开关不应对它二次拦截）。
        if isEnabled(name: originalName) || isSessionApproved(originalName) || isCore(originalName) {
            // v2.9.36：统一审计 (老 MCP 样式：OK/failed · 权限 · 耗时 · 数据量）
            let start = CFAbsoluteTimeGetCurrent()
            let perm = Self.permissionLabel(originalName)
            do {
                // v3.0.90：记录调用次数，告诉 AI 它调了几次，让 AI 自己判断
                let callCount = recordCall(name: originalName, params: params)
                // v6.9.0：失败指纹用的 callKey（同参数同错误才计熔断次数）
                let ck = callKey(name: originalName, params: params)
                // v2.9.72：工作流可视化
                WorkflowManager.shared.addStep(name: originalName, tool: originalName)

                // v3.0.90：结果缓存——5 分钟内同样的调用直接返回缓存
                // v4.3.26：有状态工具 (web./workspace/browser./control./device.fake/injection.mem）绕过缓存；
                // 其余工具连续第 2 次命中缓存也强制重取 (命中计数归零后真实执行)。
                let cacheKey = callKey(name: originalName, params: params)
                let bypassCache = cacheBypassPrefixes.contains { originalName.hasPrefix($0) }
                var cached: [String: Any]? = nil
                if !bypassCache {
                    cached = getCachedResult(name: originalName, params: params)
                    if cached != nil {
                        let hits = (cacheHitCounts[cacheKey] ?? 0) + 1
                        if hits >= 2 {
                            // 连续第 2 次命中 → 强制重取：删缓存、清计数、真实执行
                            resultCache.removeValue(forKey: cacheKey)
                            cacheHitCounts[cacheKey] = 0
                            cached = nil
                        } else {
                            cacheHitCounts[cacheKey] = hits
                        }
                    }
                }
                if let cached = cached {
                    WorkflowManager.shared.updateStep(tool: originalName, detail: "cached", success: true)
                    var cachedData = Self.compactResult(cached)
                    cachedData.removeValue(forKey: "message")
                    cachedData["_call_count"] = callCount
                    cachedData["_cached"] = true
                    cachedData["_cache_hits"] = cacheHitCounts[cacheKey] ?? 1
                    // v7.15.1：告诉模型这是缓存，避免把旧结果当实时数据引用
                    let ageSec = Int(Date().timeIntervalSince(resultCache[cacheKey]?.time ?? Date()))
                    cachedData["_cached_age_seconds"] = ageSec
                    cachedData["_cached_note"] = "缓存结果（\(ageSec)s 前），非实时抓取。涉及时效信息（价格/新闻/版本号）请勿直接引用，必要时换参数重新获取。"
                    return ["ok": true, "data": cachedData]
                }
                cacheHitCounts[cacheKey] = 0   // 真实执行前清零命中计数

                // v3.0.90：工具执行超时保护——15 秒没返回就报错，防止一直卡着
                var timedOut = false
                let timeoutWorkItem = DispatchWorkItem {
                    timedOut = true
                    WorkflowManager.shared.updateStep(tool: originalName, detail: "⏱ 超时 (15s)", success: false)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeoutWorkItem)

                // v3.1.5: 自动重试——网络错误/超时自动重试一次
                var result: [String: Any]
                do {
                    result = try t.invoke(params)
                } catch {
                    // 异常抛出的错误：判断能不能重试
                    let errStr = "\(error)"
                    if FailureKind.retryable(errStr) && callCount == 1 {
                        // 自动重试一次
                        WorkflowManager.shared.updateStep(tool: originalName, detail: "🔄 自动重试...", success: false)
                        Thread.sleep(forTimeInterval: 1.0)  // 等 1 秒再重试
                        result = try t.invoke(params)
                    } else {
                        throw error
                    }
                }
                timeoutWorkItem.cancel()
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                // v4.3.25: 超时看门狗落地——timedOut 标记此前只写不读（死代码），
                // 长工具（ai_analyze 砸壳/LLM 等待可达分钟级）跑超 15s 后 AI 收不到任何
                // "慢"信号，把慢调用误判为"空结果/无输出"，导致不继续下一步。
                // 现在：超时标记进结果让 AI 可感知；慢结果不写缓存（避免把慢当常态复读）。
                if timedOut {
                    result["_slow"] = true
                    result["_slow_note"] = "this tool took >15s (\(elapsedMs)ms total). Long analysis tools (decrypt/probe/LLM) may take minutes — treat the eventual result as valid output, do not assume it is empty."
                }
                // v2.9.134：返回式错误统一识别——工具 return ["error":...] / ["ok": false] /
                // ["status": "failed"] 不再伪装OK (旧版 ok 恒为 true，AI 无法分辨成败，
                // 即"死结果"根因）。统一走 code/reason/nextStep failed路径。
                if let errMsg = Self.extractReturnedError(result) {
                    let info = FailureKind.classify(errMsg)
                    // v3.1.5: 返回式错误也自动重试一次
                    if FailureKind.retryable(errMsg) && callCount == 1 {
                        WorkflowManager.shared.updateStep(tool: originalName, detail: "🔄 自动重试...", success: false)
                        Thread.sleep(forTimeInterval: 1.0)  // 等 1 秒再重试
                        do {
                            result = try t.invoke(params)
                        } catch {
                            // 重试还是failed，继续走failed路径
                            AuditLog.shared.logTool(originalName, status: .failure,
                                                    elapsedMs: elapsedMs, dataBytes: 0, permission: perm,
                                                    detail: errMsg, code: info.code, reason: info.reason, nextStep: info.nextStep)
                            WorkflowManager.shared.updateStep(tool: originalName, detail: errMsg, success: false)
                            let streak = noteFailure(callKey: ck, errorMessage: errMsg)
                            if streak.blocked {
                                throw loopBlockedError(tool: originalName, params: params,
                                                       errorMessage: errMsg, count: streak.count)
                            }
                            throw MCPError.classified(errMsg, code: info.code, reason: info.reason, nextStep: info.nextStep)
                        }
                        // 重试OK了，继续走OK路径 (如果还有返回式错误，继续往下走会再检查一次）
                        if Self.extractReturnedError(result) != nil {
                            // 重试还是返回式错误，继续走failed路径
                            let newErrMsg = Self.extractReturnedError(result)!
                            let newInfo = FailureKind.classify(newErrMsg)
                            AuditLog.shared.logTool(originalName, status: .failure,
                                                    elapsedMs: elapsedMs, dataBytes: 0, permission: perm,
                                                    detail: newErrMsg, code: newInfo.code, reason: newInfo.reason, nextStep: newInfo.nextStep)
                            WorkflowManager.shared.updateStep(tool: originalName, detail: newErrMsg, success: false)
                            throw MCPError.classified(newErrMsg, code: newInfo.code, reason: newInfo.reason, nextStep: newInfo.nextStep)
                        }
                        // 重试OK，继续往下走
                    } else {
                        AuditLog.shared.logTool(originalName, status: .failure,
                                                elapsedMs: elapsedMs, dataBytes: 0, permission: perm,
                                                detail: errMsg, code: info.code, reason: info.reason, nextStep: info.nextStep)
                        WorkflowManager.shared.updateStep(tool: originalName, detail: errMsg, success: false)
                        // v6.9.0: 连续同参数+同错误 2 次即熔断，并给出替代工具（见 loopBlockedError）
                        let streak = noteFailure(callKey: ck, errorMessage: errMsg)
                        if streak.blocked {
                            throw loopBlockedError(tool: originalName, params: params,
                                                   errorMessage: errMsg, count: streak.count)
                        }
                        throw MCPError.classified(errMsg, code: info.code, reason: info.reason, nextStep: info.nextStep)
                    }
                }
                let bytes = Self.resultBytes(result)
                AuditLog.shared.logTool(originalName, status: .success,
                                        elapsedMs: elapsedMs, dataBytes: bytes, permission: perm)
                WorkflowManager.shared.updateStep(tool: originalName, detail: "\(elapsedMs)ms", success: true)
                // v6.9.0：成功即清零该调用的失败计数，避免历史失败影响后续判断
                clearFailure(callKey: ck)

                // v3.0.90：存结果缓存 (OK才存，failed不缓存）
                // v4.3.25: 慢结果 (超看门狗）也不缓存——避免"慢"成为被复读的常态结果
                if !timedOut {
                    cacheResult(name: originalName, params: params, result: result)
                }

                // v2.9.125：CLI 式统一返回——顶层只留 ok/message，细节收进 data。
                // AI 读 message 一眼判成败；需要排障才展开 data。
                // v2.9.137：结果摘要化——data 内大数组 (>20）/大字符串 (>4000）
                // 递归压缩，复合工具诊断结论前置、细节按需取，防大结果占满上下文。
                // v3.1.33：截断可配置——AI 可在参数里传 limit (覆盖字符串上限，默认4000）
                // 或 full=true (不截断，返回完整结果），解决"结果被修剪看不到主体"的痛点。
                var data: [String: Any]
                if let fullFlag = params["full"] as? Bool, fullFlag {
                    data = Self.slim(result)
                } else if let lim = params["limit"] as? Int, lim > 0 {
                    data = Self.compactResult(result, strLimit: min(lim, 100_000), keepHeadTail: true)
                } else {
                    data = Self.compactResult(result)
                }
                data.removeValue(forKey: "message")
                // v6.9.0：成功路径不再用「调用次数」判断循环（成功 2 次很常见，报警只会干扰）。
                // 改为：同参数连续 3 次成功且结果一致时才提示——此时多半是在重复读同一份静态数据。
                data["_call_count"] = callCount
                if callCount >= 3 {
                    data["_loop_hint"] = "⚠️ 同参数已成功调用 \(callCount) 次（\(Int(loopWindow))秒内）。如果结果完全一样，说明这一步已经没有新信息，请直接进入下一步或换目标；不要继续重复。"
                }
                // v2.9.167：_noMessage 标记——数据自解释的工具返回里明确不需要顶层
                // message (total/tools 已自解释），省 ~10 token/次
                if result["_noMessage"] as? Bool == true {
                    data.removeValue(forKey: "_noMessage")
                    return ["ok": true, "data": data]
                }
                let msg = (result["message"] as? String)
                    ?? FailureKind.defaultSuccessMessage(name: originalName, result: result)
                // v2.9.168：全局紧凑规则——data 序列化后 >600 字节 (有实质内容自解释）
                // 时自动去掉顶层 message 省 token (201 个工具大结果统一生效）；
                // 小结果保留 message ("decrypt done: xxx"这类结论句帮 AI 秒判，不丢判断力）。
                if Self.resultBytes(data) > 600 {
                    return ["ok": true, "data": data]
                }
                return ["ok": true, "message": msg, "data": data]
            } catch {
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                var errDesc = (error as? MCPError)?.description ?? error.localizedDescription

                // v6.9.0：参数类报错统一增强——工具层大多只写 "bundle_id required"，
                // 模型看不出「自己传了什么、该换成什么工具」，于是原样重试。
                // 在这里补全上下文（工具层无需逐个改）。
                if errDesc.contains("bundle_id required") || errDesc.contains("invalid params") {
                    let keys = params.keys.filter { !$0.hasPrefix("_") }.sorted()
                    let passed = keys.isEmpty ? "(无)" : keys.joined(separator: ", ")
                    var hint = "\n你传的参数: [\(passed)]"
                    if errDesc.contains("bundle_id required") {
                        if keys.contains("path") {
                            hint += "\n⚠️ 你把 path 传给了这个工具，但它要的是 bundle_id。"
                            hint += "\n如果要检查二进制文件（加密/架构/签名），改用:"
                            for alt in ToolParamHelp.binaryCheckAlternatives(
                                pathHint: (params["path"] as? String) ?? "<文件绝对路径>") {
                                hint += "\n  - \(alt)"
                            }
                        }
                        hint += "\n取 bundle_id: \(ToolParamHelp.howToGetBundleId)"
                    }
                    hint += "\n补全参数后重试一次；如果这个工具本身选错了，换上面列出的工具。"
                    errDesc += hint
                }

                // v2.9.128：failed记录 CLI 四分类 code/reason/nextStep (供健康度聚合 + AI 自查）
                let classified: MCPError
                if case MCPError.classified(_, code: let c, reason: let r, nextStep: let n) = error {
                    classified = MCPError.classified(errDesc, code: c, reason: r, nextStep: n)
                } else {
                    let info = FailureKind.classify(errDesc)
                    classified = MCPError.classified(errDesc, code: info.code, reason: info.reason, nextStep: info.nextStep)
                }
                let (cCode, cReason, cNext) = Self.unpack(classified)
                AuditLog.shared.logTool(originalName, status: .failure,
                                        elapsedMs: elapsedMs, dataBytes: 0, permission: perm,
                                        detail: errDesc, code: cCode, reason: cReason, nextStep: cNext)
                WorkflowManager.shared.updateStep(tool: originalName, detail: errDesc, success: false)
                throw classified
            }
        }
        // v3.1.9: 工具未授权 → 自动授权 + 返回"已加载，请重新调用"
        // AI 直接调用即自动加载，无需先搜索
        approveForSession(originalName)
        throw MCPError.failed("tool \(originalName) loaded, schema injected next round, call again")
    }

    // v2.9.128：解包 classified 的 code/reason/nextStep (审计记录用）
    private static func unpack(_ err: MCPError) -> (String, String, String) {
        if case MCPError.classified(_, code: let c, reason: let r, nextStep: let n) = err {
            return (c, r, n)
        }
        let info = FailureKind.classify(err.description)
        return (info.code, info.reason, info.nextStep)
    }

    /// v2.9.134：提取"返回式错误" (工具不 throw 而是 return ["error":...]/["ok":false]/
    /// ["status":"failed"]）。返回 nil 表示该结果应视为OK。
    /// v2.9.137：结果摘要化 (递归）——大数组保持数组但截断并末尾加省略标记，
    /// 大字符串截断并附总长度。返回后 AI 仍能读结论字段，细节可带 limit 重取。
    /// `content` 字段 (artifact.read_text 的文件内容）保留完整——
    /// 它们已由 max_bytes 参数控制读取量，不能再截断。
    /// v2.9.168：通用字段瘦身 (全部工具生效）——
    /// hint 截 60、summary 截 30、删空字符串值。结构信息不删，只去冗余。
    static func slim(_ d: [String: Any]) -> [String: Any] {
        var nd = d
        if let h = nd["hint"] as? String, h.count > 60 { nd["hint"] = String(h.prefix(60)) + "…" }
        if let sm = nd["summary"] as? String, sm.count > 30 { nd["summary"] = String(sm.prefix(30)) + "…" }
        for (k, v) in nd where (v as? String)?.isEmpty == true {
            nd.removeValue(forKey: k)
        }
        return nd
    }

    /// v2.9.164：大字符串落盘到工作区 tool_spill/ (完整内容保留，AI 按路径再读）
    static func spillLarge(_ key: String, _ content: String) -> String {
        let dir = Workspace.root.appendingPathComponent("tool_spill", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "spill_\(Int(Date().timeIntervalSince1970))_\(key.replacingOccurrences(of: "/", with: "_")).txt"
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    static func compactResult(_ root: [String: Any], arrLimit: Int = 20, strLimit: Int = 4000, keepHeadTail: Bool = true) -> [String: Any] {
        var out: [String: Any] = [:]
        var truncatedAny = false
        for (k, v) in root {
            switch v {
            case let s as String:
                // v2.9.164：先压多余空行 (\n{3,}→\n\n）与行尾空格——日志/hexdump 的空行
                // 在模型侧也是 token，压缩后单次可省数百 token，且不破坏内容结构。
                var t = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                t = t.split(separator: "\n", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.joined(separator: "\n")
                if k == "content" || t.count <= strLimit {
                    out[k] = t
                } else {
                    // v3.1.33：截断策略——保留头+尾 (默认），不只留开头 (AI 诊断 P3：
                    // "只留开头最没用"）。完整内容仍落盘 tool_spill/，AI 可 cat 全量。
                    // v3.1.68：统一 truncated 标记——AI 读顶层即知结果被截断 (E items）
                    truncatedAny = true
                    let spillPath = Self.spillLarge(k, t)
                    if keepHeadTail, strLimit >= 200 {
                        let half = strLimit / 2
                        let head = String(t.prefix(half))
                        let tail = String(t.suffix(half))
                        out[k] = head + "\n…[中间省略 共\(t.count - strLimit + 40)字符，完整内容: \(spillPath)]…\n" + tail
                    } else {
                        out[k] = String(t.prefix(strLimit)) + "\n…[截断 共\(t.count)字符，完整内容: \(spillPath)]"
                    }
                }
            case let arr as [[String: Any]]:
                if arr.count > arrLimit {
                    truncatedAny = true
                    var cut = Array(arr.prefix(arrLimit))
                    cut.append(["note": "...[total \(arr.count) items, truncated, showing first \(arrLimit) items]"])
                    out[k] = cut
                } else {
                    out[k] = arr.map { slim(compactResult($0)) }
                }
            case let arr as [Any]:
                if arr.count > arrLimit {
                    truncatedAny = true
                    var cut = Array(arr.prefix(arrLimit))
                    cut.append("…[共\(arr.count) items, truncated, showing first \(arrLimit) items]")
                    out[k] = cut
                } else {
                    out[k] = arr.map { ($0 as? [String: Any]).map { Self.slim(Self.compactResult($0)) } ?? $0 }
                }
            case let d as [String: Any]:
                out[k] = slim(compactResult(d))
            default:
                out[k] = v
            }
        }
        if truncatedAny { out["truncated"] = true }
        return out
    }

    static func extractReturnedError(_ result: [String: Any]) -> String? {
        // ① 显式 ok:false
        if result["ok"] as? Bool == false {
            return Self.errorMessage(from: result["error"], fallback: "工具返回 ok=false")
        }
        // ② error 键 (String 或 [String:Any] 字典）
        // v3.1.8：nil error 不应该被当成错误——只有 error 有值时才算
        if let errBox = result["error"], !(errBox is NSNull) {
            return Self.errorMessage(from: errBox, fallback: "工具返回错误 (未提供原因)")
        }
        // ③ status failed态
        if let st = result["status"] as? String, ["failed", "error", "failure"].contains(st.lowercased()) {
            return Self.errorMessage(from: result["reason"] ?? result["error"], fallback: "工具返回failed状态 \(st)")
        }
        return nil
    }

    private static func errorMessage(from box: Any?, fallback: String) -> String {
        if let s = box as? String, !s.isEmpty { return s }
        if let d = box as? [String: Any] {
            for k in ["reason", "message", "error", "detail"] {
                if let s = d[k] as? String, !s.isEmpty { return s }
            }
            if let s = d["description"] as? String, !s.isEmpty { return s }
        }
        return fallback
    }

    // v2.9.36：权限标签 (对齐老 MCP readOnly/privilegedRead/write 语义，按工具名前缀粗分）
    private static func permissionLabel(_ name: String) -> String {        let write = ["open", "open_and_input", "enable", "disable", "remove", "write",
                     "set", "delete", "clear", "run", "send", "connect", "create",
                     "cancel", "fire", "schedule", "prepare", "stop", "import",
                     "generate", "config", "set_enabled", "output", "approve", "refresh"]
        for w in write where name.contains(w) { return "write" }
        if name.contains("cache") { return "privilegedRead" }
        return "readOnly"
    }

    // v2.9.36：结果数据量 (JSON 序列化字节估算）
    private static func resultBytes(_ result: [String: Any]) -> Int {
        guard let data = try? JSONSerialization.data(withJSONObject: result) else { return 0 }
        return data.count
    }

    /// 全量内置工具集
    public func registerBuiltinTools() {
        // M1 文件桥 + 基础
        // v3.1.39: artifact 大工具 + 子命令 (合并 3 个 artifact.* 工具）
        register(ArtifactExecTool())
        // v3.1.39: 删旧的 3 个 artifact.* 工具 (已合并到 artifact 大工具）
        // v3.1.46: 删 ArtifactFindTool (shell.exec 可以实现：shell.exec("find xxx")）
        // v3.1.46: 删 PingTool (shell.exec 可以实现：shell.exec("ping -c 4 xxx")）
        // v3.1.40: device 大工具 + 子命令 (合并 4 个 device.* 工具）
        register(DeviceExecTool())
        // v6.6.11：Hax 电脑——AI 可调用的 Alpine 工作站（exec/code/search/fetch/read/write/install）
        // v7.3.0：Hax 电脑（hax 工具）随引擎一起移除
        // v6.6.12：引擎控制——AI 可自主开关 Alpine/iSH（依赖 Alpine 的工具不再被门控卡死）
        // v7.3.0：engine 工具随引擎一起移除
        // v6.6.16：存档修改——不依赖 spawn/Alpine/注入的 SQLite+plist 直读直写
        register(SaveDataTool())
        // v3.1.40: 删旧的 4 个 device.* 工具 (已合并到 device 大工具）
        register(MemoryTweakTool())   // v6.7.0：H5GG式内存修改（默认原生 VansonMod 引擎，可切 legacy dylib）
        register(MachoExecTool())     // v6.8.0：Mach-O 静态分析（MachOKit）
        register(DisasmTool())        // v6.6.15：进程内反汇编（capstone），不依赖子进程
        register(PyEvalTool())        // v6.6.16：进程内 CPython（dlopen），不依赖子进程
        register(EnvTool())           // v6.6.19：环境变量（AI 可读写，设置页也可编辑）
        // v3.1.34: control 大工具 + 子命令 (合并 10 个 control.* 工具）
        register(ControlExecTool())
        // v3.1.34: 删旧的 10 个 control.* 工具 (已合并到 control 大工具）
        // v3.1.46: 删 WorkspaceInfoTool (shell.exec 可以实现：shell.exec("pwd")）
        // v3.1.33: 清理工具已删 (用 shell 代替）
        // 代替成：shell.exec("du -sh ...") / shell.exec("rm -rf ...")

        // M2 助理记忆 (原版命名）
        // v3.1.43: memory 大工具 + 子命令 (合并 3 个 assistant.memory.* 工具）
        register(MemoryExecTool())
        // v3.1.43: 删旧的 3 个 assistant.memory.* 工具 (已合并到 memory 大工具）

        // M2 应用与设备
        // v3.1.37: 删旧的 4 个 app.* 工具 (已合并到 app 大工具）

        // v3.0.90：系统概览工具 (AI 全局视角目录）
        // v3.1.64: 删 SystemOverviewTool (用 shell.exec("uname -a") / shell.exec("df -h") / shell.exec("free") 代替）
        // v4.4.x(优化): 重新启用 SystemOverviewTool——tool_categories 已改为从注册表动态生成
        //   (只列真实注册的大工具 + 版本从 Bundle 读)，给 AI 一个无幽灵工具名的真实目录。
        register(SystemOverviewTool())
        // v4.4.x(优化): tools.audit——工具注册表一致性审计（检测 summary/prerequisites 里引用
        //   但未注册的"幽灵工具名"，防文档漂移，AI 分不清工具的根因之一）。
        register(AuditTool())
        // v3.1.44: verify 大工具 + 子命令 (合并 2 个 verify.* 工具）
        register(VerifyExecTool())
        // v3.1.44: 删旧的 2 个 verify.* 工具 (已合并到 verify 大工具）
        // fix3cy10: wifi 系统代理控制（AI 一键开/关 HTTP(S) 代理 → 本地 MITM，不断网抓包）
        register(WifiProxyExecTool())

        // v3.1.34: inject 大工具 + 子命令 (合并 7 个 injection.* 工具）
        register(InjectionExecTool())
        // v3.1.34: 删旧的 7 个 injection.* 工具 (已合并到 inject 大工具）
        // v3.1.37: 删旧的 3 个 inject.* 工具 (已合并到 inject 大工具）
        // v3.1.38: rescue 大工具 + 子命令 (合并 3 个 rescue.* 工具）
        register(RescueExecTool())
        // v3.1.38: 删旧的 3 个 rescue.* 工具 (已合并到 rescue 大工具）
        // v2.9.90：高级工具组 (类探测/配置化 Hook/设备伪装）
        // v3.1.60: 删 ProbeInspectTool / HookApplyTool (已合并到 inject 大工具）
        // v3.1.55: 删旧的 device 工具 (已合并到 DeviceExecTool）
        // v2.9.95：设备指纹 / 容器 / entitlements (对齐 Fuck 工具箱 + 绿盾式）
        // v3.1.59: 删 AppEntitlementsTool (已合并到 app 大工具：app entitlements）
        // v3.1.60: 删 KeychainWipeTool (已合并到 inject 大工具：inject keychain_wipe）
        // v3.1.62: 删 AdvertisingTool / IdfvTool (已合并到 DeviceExecTool）
        // v3.1.41: container 大工具 + 子命令 (合并 3 个 container.* 工具）
        register(ContainerExecTool())
        // v3.1.41: 删旧的 3 个 container.* 工具 (已合并到 container 大工具）
        // v4.1.0: 按需选择性绑定 App 数据容器（替代整棵 /var/mobile 绑定）
        register(BindAppTool())
        // v4.2.0: 可写就地修改 App 数据容器（绑定前强制备份）
        register(BindAppWriteTool())
        // v4.3.3: 原生可写通道——fakefs 挂载点固定只读(bind_app_write 实测写不进, Errno 30),
        // 写 App 数据容器改用 iOS 原生 FileManager 直写(绕开 Alpine), 写前自动备份。
        register(AppWriteFileTool())
        // v2.9.99：一键新机 (绿盾式组合）
        // v3.1.62: 删 NewDeviceTool (已合并到 DeviceExecTool：device new_device）
        // v2.9.100：AI 分析引擎
        // v3.1.59: 删 AiAnalyzeTool (已合并到 app 大工具：app ai_analyze）

        // v2.9.68：SSH 远程连接 + 应用解密
        // v3.1.45: ssh 大工具 + 子命令 (合并 2 个 ssh.* 工具）
        register(SshExecTool())
        // v3.1.45: 删旧的 2 个 ssh.* 工具 (已合并到 ssh 大工具）
        // v3.1.59: 删 AppDecryptTool / AppReplaceDecryptedTool / AppEncryptInfoTool (已合并到 app 大工具）

        // v2.9.69：质量与诊断工具
        // v3.1.60: 删 IPAInspectTool / DylibInspectTool / InjectionDiagnoseTool (已合并到 inject 大工具）
        // v3.1.33: 删 LogCollectTool (用 shell cat 代替）
        register(NetworkCaptureTool())
        // v3.3.0: MITM 抓包 VPN/代理（系统级抓包，覆盖自研栈 App）
        register(VpnTool())
        // v3.3.4: 解包查看别人的包（deb / ipa：列结构、解包到工作区）
        register(PackageTool())

        // v3.1.34: app 大工具 + 子命令 (合并 5 个 app.* 工具）
        register(AppExecTool())
        // v3.1.34: 删旧的 5 个 app.* 工具 (已合并到 app 大工具）
        // v3.1.56: 删 TestRunTool (shell.exec 可以实现）

        // v3.1.42: diagnose 大工具 + 子命令 (合并 2 个 diagnose.* 工具）
        register(DiagnoseExecTool())
        // v3.1.42: 删旧的 2 个 diagnose.* 工具 (已合并到 diagnose 大工具）
        // v3.1.36: server 大工具 + 子命令 (合并 3 个 server.* 工具）
        register(ServerExecTool())
        // v3.1.36: 删旧的 3 个 server.* 工具 (已合并到 server 大工具）

        // v2.9.72：知识库 + 清理 + 符号 + 插件 + 兼容矩阵 + 崩溃复现
        // v3.1.63: 删 KnowledgeBaseTool (用 shell.exec 写文件/读文件/搜索文件代替）
        // v3.1.33: 删 WorkspaceCleanupTool (用 shell rm 代替）
        // v3.1.60: 删 BinarySymbolsTool / PluginTool (已合并到 inject 大工具）
        // v3.1.63: 删 CompatibilityTool (用 shell.exec 写文件/读文件代替）
        // v3.1.33: 删 CrashReproTool (用 shell 代替）

        // v2.9.73：项目上下文 + 任务模板
        register(ProjectTool())
        // v3.1.63: 删 TaskTool (用 shell.exec 直接运行命令代替）

        // M4 Gateway + 自动化 (含原版命名）
        // v3.1.62: 删 CronFireTool (已合并到 AutomationExecTool：automation cron_fire）
        // v3.1.35: automation 大工具 + 子命令 (合并 7 个 automation.* 工具）
        register(AutomationExecTool())
        // v3.1.35: 删旧的 7 个 automation.* 工具 (已合并到 automation 大工具）

        // M5 系统能力
        // v3.1.64: 删 ContactsSearchTool (用得少，隐私敏感，用系统电话 App 搜索联系人）
        // v3.1.64: 删 CalendarExecTool (用得少，用系统日历 App）
        // v3.1.57: 删旧的日历工具 (已合并到 CalendarExecTool）
        register(ReminderExecTool())   // v3.1.57: 提醒事项大工具 (合并 create/schedule/recurring）
        // v3.1.57: 删旧的提醒事项工具 (已合并到 ReminderExecTool）
        // v3.1.61: 删 LocationGetTool (已合并到 LocationExecTool：location get）
        // v3.1.64: 删 ScanQRTool (AI 是文字对话，不能扫码）
        // v3.1.33: 删 ProcessListTool (用 shell ps 代替）
        register(ShellExecTool())   // v3.0.28：内置终端，执行 shell 命令

        // v7.5.0：内置浏览器已删除（用户要求）。联网能力改为「多服务商搜索 + 全文读取」，
        // 工作区能力（Kelivo workspace）新增。
        register(WorkspaceExecTool())
        // v7.1.0：通用子代理——多轮探索任务甩给它，只回结论
        register(SubagentTool())
        // v3.1.47: 删旧的 13 个 browser.* 工具 (已合并到 browser 大工具）
        // v2.9.131：AI 安装/卸载 App (trollstorehelper 优先）——补全下载→安装→注入→控制链路
        // v3.1.59: 删 AppInstallTool / AppUninstallTool / AppDuplicateTool (已合并到 app 大工具）
        // v2.9.132：failed边界一条龙——注入健康检查 + 启动failed判因
        // v3.1.60: 删 InjectionVerifyTool (已合并到 inject 大工具：inject verify）
        // v3.1.59: 删 AppDiagnoseTool (已合并到 app 大工具：app diagnose）
        // v3.1.55: 删 BrowserNavigateTool (已合并到 BrowserExecTool）

        // M6 编译模式 + 模型配置 + 工作区输出 (原版命名）
        // v3.1.56: 删 BuildRunnerTokenTool (shell.exec curl 可以实现）
        // v3.1.62: 删 ProjectGenerateTweakTool (已合并到 ProjectTool：project generate_tweak）
        // v3.1.55: 删旧的 model 工具 (已合并到 ModelExecTool）
        // v4.0.0: 删 WorkspaceOutputBookmarkTool / WorkspaceOutputNameTool（已内联进 ArtifactExecTool，消除"注释称删实未删"矛盾）

        // M8 本机编译/构建 (v2.9.3，设备端编译桥）
        // v3.1.46: 删 BuildEnvironmentTool (shell.exec 可以实现：shell.exec("which clang")）
        // v3.1.56: 删 BuildRunTool (shell.exec curl 可以实现 GitHub API）

        // M9 GitHub 线上编译 (v2.9.9：账号状态 / 触发编译 / 查进度 / 下载产物）
        // v3.1.52: 删 github 大工具 (shell.exec 可以实现：shell.exec("curl https://api.github.com/...")）

        // M7 补齐缺失设备端工具
        // v3.1.57: 删 CalendarCreateEventTool (已合并到 CalendarExecTool）
        // v3.1.57: 删 ReminderScheduleTool / ReminderScheduleRecurringTool (已合并到 ReminderExecTool）
        // v3.1.62: 删 DeviceSnapshotTool (已合并到 DeviceExecTool：device snapshot）
        // v3.1.54: 删 WebSearchTool / WebFetchTool (shell.exec curl 可以实现）
        // v3.1.50: knowledge 大工具 + 子命令 (合并 4 个 knowledge.* 工具）
        register(KnowledgeExecTool())
        // v3.1.50: 删旧的 4 个 knowledge.* 工具 (已合并到 knowledge 大工具）
        // v3.1.64: 删 PhoneExecTool (用得少，用系统电话 App 打电话）
        // v3.1.61: 删旧的电话工具 (已合并到 PhoneExecTool）
        // v3.1.64: 删 SkillsSetEnabledTool (用 shell.exec 修改配置文件代替）
        // v3.6.19l: 恢复注册 skills.* —— 之前注释说"用 shell.exec 代替"但 shell.exec 并无 skills 子命令，
        //           导致 AI 永远拿不到 skills.list/read/set_enabled 工具，"AI 说调用不了技能"。恢复后按需加载机制真正生效。
        register(SkillsListTool())        // v2.9.17：技能可被 AI 发现（按需搜索，不塞全量）
        register(SkillsReadTool())        // v2.9.17：技能可被 AI 读取（完整指令）
        register(SkillsSetEnabledTool())  // 技能启停
        // v3.1.31: 之前 shell 是 Alpine，访问不到 iOS 文件系统，所以 fs.* 工具加回来了
        // v3.1.46: 现在 shell.exec 已经做了 iOS 原生命令，可以访问 iOS 文件系统了！
        // 删掉 12 个 fs.* 工具 (shell.exec 可以实现）
        // v3.1.64: 删 FSZipTool (用 shell.exec("zip/unzip") 代替）
        // v3.1.64: 删 FSImageInfoTool (用 shell.exec("file 图片路径") 代替）

        // v2.9.139：AI 控制任意 App (HID 触摸injected + 进度横幅 + 控制会话）
        // v3.1.55: 删旧的 control 工具 (已合并到 ControlExecTool）
        // v2.9.139：启动带参数 + 定位模拟
        // v3.1.59: 删 AppLaunchOptionsTool (已合并到 app 大工具：app launch_options）
        // v3.1.51: location 大工具 + 子命令 (合并 4 个 location.* 工具）
        register(LocationExecTool())
        // v3.1.51: 删旧的 4 个 location.* 工具 (已合并到 location 大工具）
        // v2.9.141：跨 App 数据桥 (沙箱破坏者）+ AI 操作宏录制/回放
        // v3.1.46: 删 6 个 bridge.* 工具 (shell.exec 可以实现）
        // v3.1.53: debug 大工具 + 子命令 (合并 4 个 debug.* 工具）
        // v3.1.53: 删旧的 4 个 debug.* 工具 (已合并到 debug 大工具）
        // v3.1.58: Chat 工具 (测试用，不是给用户用的！）
        // v3.1.49: model 大工具 + 子命令 (合并 6 个 model.* 工具）
        // v3.1.64: 删 ModelExecTool (是测试用的）
        // v3.1.49: 删旧的 6 个 model.* 工具 (已合并到 model 大工具）
        // v3.1.55: 删旧的 debug 工具 (已合并到 DebugExecTool）
        // v3.1.48: macro 大工具 + 子命令 (合并 6 个 macro.* 工具）
        register(MacroExecTool())
        // v3.1.48: 删旧的 6 个 macro.* 工具 (已合并到 macro 大工具）

        // v3.0.67：toolchain 工具
        // v3.1.56: 删 toolchain 工具 (shell.exec 可以实现：which clang / apt-get install clang）
        // v3.0.71：AI 自我进化——加载外部 dylib 注册新工具
        // v3.1.60: 删 ToolLoadDylibTool (已合并到 inject 大工具：inject load_dylib）
        // v3.0.72：语义化 UI 操作 + OCR
        // v3.1.62: 删 ControlTapTextTool / ControlTypeTextTool (已合并到 ControlExecTool）

        // v3.6.12 P5 高层跨环境工具 (v3.7.7: 自动 bind 直读 iOS 文件)
        register(FileExecTool())
        register(DbExecTool())
        // v4.3.65：统一工具安装（AI 自动装工具/依赖闭环）——tool.install / env.setup_re
        register(ToolInstallTool())
        register(EnvSetupRETool())
        // v4.3.65：恢复注册 web.search / web.fetch（v3.1.54 曾删，现升级回归：
        // 多 query 并行、多引擎回退 Bing→DuckDuckGo→Baidu、去重/来源分级、正文抽取、可沉淀知识库）
        register(WebSearchTool())
        register(WebFetchTool())
        // v4.3.66：注册 github 大工具（CI 触发/查进度/下载产物）——tool.install 触发 CI 后，
        // AI 需按提示调 github.fetch_runs / github.download_artifact 取产物；此前该工具漏注册导致后续断链
        // v7.14.0：jb-p1lot——rootless 越狱设备直控（root shell / tweak_cycle / UI / LLDB / Frida）
        register(JBPlotTool())
        // v7.16.0：原生 Git——越狱环境下真 git / python3 都被 ENOSYS 拦，
        // 内置 curl 丢 -H、web.fetch 过代理剥 Authorization，只能进程内 URLSession 直连 API
        register(GitNativeTool())
        // v3.7.7c: 移除 ish.bind 注册——bind mount 已由 autoBind 全自动（命令引用 iOS 路径自动挂载+改写），
        // 手动 bind 工具对 AI 是误导（会以为要手动挂载）。类定义保留供开发者调试/真机验证。
        // v6.9.10：模式自动路由——AI 按需拉取某个模式的完整细则（懒加载，避免 2.1 万字符全量进 context）
        register(PromptModeTool())
        AuditLog.shared.log("core", detail: "已注册 \(definitions.count) 个工具")
    }
}

// MARK: - v6.9.10 模式细则读取（自动路由配套）

/// AI 在自动路由下判定出任务性质后，用本工具拉取对应模式的完整行为准则。
/// 系统提示词里只放了各模式摘要（约 1.5k 字符），全文按需取，避免占用 context。
final class PromptModeTool: MCPTool {
    let definition = ToolDefinition(
        name: "prompt.read_mode",
        summary: "Read the full behavior rules of a work mode. Use for: after you decide which mode a task needs (see AUTO MODE ROUTING in system prompt), fetch that mode's complete rules before doing non-trivial work. Don't use for: listing modes (the summary list is already in the system prompt). Example: user asks to decrypt an app → read_mode reverse → follow its full checklist.",
        parameters: [
            "mode_id": "Mode id (required): concise / default / developer / reverse / pentester / gamehacker / uicontrol",
            "list": "true = list all modes with description only, ignore mode_id"
        ],
    verified: true, category: "misc")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        if params["list"] as? Bool == true {
            return ["modes": SystemPrompts.builtin.map {
                ["id": $0.id, "name": $0.name, "desc": $0.desc]
            }]
        }
        guard let modeId = params["mode_id"] as? String, !modeId.isEmpty else {
            throw MCPError.invalidParams("mode_id required (or pass list:true). Available: "
                + SystemPrompts.builtin.map { $0.id }.joined(separator: " / "))
        }
        guard let p = SystemPrompts.shared.fullContent(modeId: modeId) else {
            return ["error": "unknown mode: \(modeId)",
                    "available": SystemPrompts.builtin.map { $0.id }]
        }
        return [
            "mode_id": p.id,
            "name": p.name,
            "desc": p.desc,
            "rules": p.content,
            "extra_core_tools": p.extraCoreTools,
            "note": "这些是该模式完整的角色准则；硬约束（工具格式/边解说边做/危险操作确认/语言）始终优先。"
        ]
    }
}


// MARK: - 工作区

public enum Workspace {
    public static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Workspace", isDirectory: true)
    }

    public static func ensure() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// v2.9.62：把 App bundle 内 Resources/tweaks/ 下的内置 dylib 复制到工作区 tweaks/ 目录
    /// AI 可通过 artifact.find 直接定位，无需用户手动传输
    public static func ensureBundledTweaks() {
        guard let tweaksDir = Bundle.main.url(forResource: "tweaks", withExtension: nil) else { return }
        let destDir = root.appendingPathComponent("tweaks", isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: tweaksDir, includingPropertiesForKeys: nil) else { return }
        for src in files {
            let dest = destDir.appendingPathComponent(src.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: src, to: dest)
            }
        }
    }

    /// 防目录穿越：解析后必须仍在工作区内
    public static func resolve(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        let standardized = url.standardizedFileURL.path
        guard standardized.hasPrefix(root.standardizedFileURL.path) else {
            throw MCPError.invalidParams("path escapes workspace: \(path)")
        }
        return url
    }
}

// MARK: - v3.0.71：外部 dylib 工具注册 (AI 自我进化）

/// 外部工具包装：把 dylib 的 handler 包装成 MCPTool
public final class ExternalMCPTool: MCPTool {
    public let definition: ToolDefinition
    private let handler: ([String: Any]) throws -> [String: Any]

    public init(definition: ToolDefinition, handler: @escaping ([String: Any]) throws -> [String: Any]) {
        self.definition = definition
        self.handler = handler
    }

    public func invoke(_ params: [String: Any]) throws -> [String: Any] {
        try handler(params)
    }
}

/// C 函数签名：让外部 dylib 能注册工具
/// dylib 加载后调用 TARegisterTool(name, summary, paramsJSON, handler)
/// handler 是 C 函数指针：NSDictionary* (^)(NSDictionary*)
typealias TAExternalHandler = @convention(block) (NSDictionary) -> NSDictionary

/// 全局注册函数——dylib 里调这个
@_cdecl("TARegisterTool")
public func TARegisterTool(_ name: UnsafePointer<CChar>,
                           _ summary: UnsafePointer<CChar>,
                           _ paramsJSON: UnsafePointer<CChar>,
                           _ handler: @escaping @convention(block) (NSDictionary) -> NSDictionary) {
    let n = String(cString: name)
    let s = String(cString: summary)
    let p = String(cString: paramsJSON)

    // 解析 params JSON
    var params: [String: String] = [:]
    if let data = p.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
        params = obj
    }

    let def = ToolDefinition(name: n, summary: s, parameters: params, verified: true, category: "external")
    ToolRegistry.shared.registerExternalTool(def) { params in
        let result = handler(params as NSDictionary)
        // NSDictionary → [String: Any]
        var dict: [String: Any] = [:]
        for (k, v) in result {
            if let key = k as? String { dict[key] = v }
        }
        return dict
    }
}
