// 工具参数校验辅助
//
// 起因：AI 反复调用同一工具失败（典型：inject command:inspect 传了 path，
// 而该子命令只认 bundle_id），每次只收到 "bundle_id required" 这一句话，
// 既不知道「自己传了什么」，也不知道「该换成哪个工具」，于是原样重试到被熔断。
//
// 本文件提供两类能力：
//   1. requireParam(...)  —— 缺参时报「你传了什么 + 正确用法 + 怎么拿到值」
//   2. paramSuggestion(...) —— 给出「这个工具不接受 path，请改用 macho load」这类替代建议
//
// 设计原则：错误信息是给模型看的「纠错指令」，不是给人看的「日志」。

import Foundation

enum ToolParamHelp {

    /// 缺参报错：列出模型实际传了哪些 key，并给出正确用法示例。
    /// - Parameters:
    ///   - tool:  工具名，如 "inject"
    ///   - sub:   子命令，如 "inspect"（没有子命令传 nil）
    ///   - missing: 缺失的参数名，如 "bundle_id"
    ///   - passed: 模型实际传入的全部参数（用于指出「你传的是 path」这类错配）
    ///   - usage: 正确用法示例
    ///   - howToGet: 怎么拿到这个值
    ///   - alternatives: 如果这个工具本身选错了，给出的替代工具
    static func missing(_ missing: String,
                        tool: String,
                        sub: String? = nil,
                        passed: [String: Any],
                        usage: String,
                        howToGet: String? = nil,
                        alternatives: [String]? = nil) -> MCPError {
        let keys = passed.keys.filter { !$0.hasPrefix("_") }.sorted()
        let passedText = keys.isEmpty ? "(无)" : keys.joined(separator: ", ")
        let target = sub.map { "\(tool) \($0)" } ?? tool

        var lines: [String] = []
        lines.append("\(target) 缺少必填参数 \(missing)。")
        lines.append("你实际传的参数是: [\(passedText)]")

        // 常见错配：把路径传给了只认 bundle_id 的工具
        if missing == "bundle_id", keys.contains("path") {
            lines.append("⚠️ 你把 path 传给了这个工具，但 \(target) 只接受 bundle_id，不接受 path。")
        }

        lines.append("正确用法: \(usage)")
        if let howToGet {
            lines.append("如何获取: \(howToGet)")
        }
        if let alternatives, !alternatives.isEmpty {
            lines.append("如果你本意不是做这件事，可改用:")
            for alt in alternatives { lines.append("  - \(alt)") }
        }
        return MCPError.invalidParams(lines.joined(separator: "\n"))
    }

    /// 常用的「拿 bundle_id」提示
    static let howToGetBundleId =
        "inject command:list query:<App名称>  或  app command:list  或  直接填已知包名，如 com.tencent.xin"

    /// 静态二进制检查的替代工具集（当模型想用 inject inspect 做加密检查时）
    static func binaryCheckAlternatives(pathHint: String = "<文件绝对路径>") -> [String] {
        [
            "macho load path:\(pathHint)          → 查架构/UUID/加密状态(cryptid)",
            "macho entitlements path:\(pathHint)  → 查权限 plist",
            "macho codesign path:\(pathHint)      → 查签名/CDHash",
            "macho symbols path:\(pathHint)       → 查导出符号",
        ]
    }

    /// 冻结快照：把 params 转成可比较的稳定字符串，用于判断「是不是同样的调用」
    static func fingerprint(_ params: [String: Any]) -> String {
        let filtered = params.filter { !$0.key.hasPrefix("_") }
        let pairs = filtered.keys.sorted().map { key -> String in
            "\(key)=\(normalize(filtered[key]))"
        }
        return pairs.joined(separator: "&")
    }

    private static func normalize(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.map { normalize($0) }.joined(separator: ",")
        case let d as [String: Any]: return fingerprint(d)
        case .none: return "nil"
        default: return "\(value!)"
        }
    }

    /// 从错误文本里提取「错误类型」，用于判断连续失败是不是「同一个错误」
    /// （不同错误的失败需要不同处理，不该被同一熔断逻辑拦截）
    static func errorSignature(_ message: String) -> String {
        let m = message.lowercased()
        // v6.9.5：ENOSYS 必须先判定——85/78 是"内核不支持该 syscall"（rootless/rootHide 下
        // persona spawn 的典型返回值），不是权限不足。放到 permission 后面会被
        // "ldid -e failed (85)" 这类文本误判成 permission，把 AI 引去查 entitlements。
        if m.contains("enosys") || m.contains("(85)") || m.contains("(78)")
            || m.contains("function not implemented") || m.contains("不支持该 syscall") {
            return "unsupported_env"
        }
        if m.contains("required") || m.contains("invalid params") { return "missing_param" }
        if m.contains("not found") || m.contains("不存在") { return "not_found" }
        if m.contains("denied") || m.contains("permission") || m.contains("未授权") { return "permission" }
        if m.contains("加密") || m.contains("cryptid") || m.contains("encrypted") { return "encrypted" }
        if m.contains("timeout") || m.contains("超时") { return "timeout" }
        if m.contains("无法连接") || m.contains("connection") || m.contains("network") { return "network" }
        // 兜底：取前 40 个字符做粗粒度区分
        return String(message.prefix(40))
    }
}
