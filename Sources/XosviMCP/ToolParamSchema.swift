// 工具参数结构化定义
//
// 背景：旧实现 `parameters: [String: String]` 只有「参数名 → 一句中文描述」，
// 生成 JSON Schema 时全部写成 type:"string"、required 只标 command。
// 后果：AI 不知道 bundle_id 是必填、不知道 limit 是数字、不知道可选值有哪些，
// 只能靠读长描述去猜，于是频繁传错（inject inspect 传 path 即典型）。
//
// 本文件把参数升级为结构化描述：类型 / 必填 / 枚举 / 正例，
// 并提供按子命令声明参数要求的 ToolVariant。
//
// 为了不改 46 个工具类，提供 .s() .i() .e() 等短构造器，允许渐进迁移：
// 未迁移的工具继续用 [String: String]，已迁移的用 [ToolParam]。

import Foundation

/// 单个参数的完整描述
public struct ToolParam {
    public enum Kind {
        case string
        case int
        case number
        case boolean
        case enumeration([String])
        case array(of: String)

        public var jsonType: String {
            switch self {
            case .string, .enumeration: return "string"
            case .int, .number: return "integer"
            case .boolean: return "boolean"
            case .array: return "array"
            }
        }
    }

    public let name: String
    public let kind: Kind
    public let description: String
    /// 整个工具层面是否总是必填。多子命令工具通常只有末尾的 command/action 属于此类，
    /// 各子命令的参数要求见 ToolVariant。
    public let required: Bool
    /// 正例，模型最容易照着抄
    public let example: String?

    public init(_ name: String, _ kind: Kind, _ description: String,
         required: Bool = false, example: String? = nil) {
        self.name = name
        self.kind = kind
        self.description = description
        self.required = required
        self.example = example
    }

    // MARK: 短构造器

    public static func s(_ name: String, _ desc: String, required: Bool = false, example: String? = nil) -> ToolParam {
        ToolParam(name, .string, desc, required: required, example: example)
    }

    public static func i(_ name: String, _ desc: String, required: Bool = false, example: String? = nil) -> ToolParam {
        ToolParam(name, .int, desc, required: required, example: example)
    }

    public static func b(_ name: String, _ desc: String, required: Bool = false) -> ToolParam {
        ToolParam(name, .boolean, desc, required: required)
    }

    public static func e(_ name: String, _ desc: String, values: [String],
                  required: Bool = false, example: String? = nil) -> ToolParam {
        ToolParam(name, .enumeration(values), desc, required: required, example: example)
    }

    /// 生成 JSON Schema 片段
    public func schemaFragment() -> [String: Any] {
        var frag: [String: Any] = ["type": kind.jsonType]
        switch kind {
        case .enumeration(let values):
            frag["enum"] = values
        case .array(let item):
            frag["items"] = ["type": item]
        default:
            break
        }
        var desc = description
        if let example, !example.isEmpty {
            desc += " (例: \(example))"
        }
        frag["description"] = desc
        return frag
    }
}

/// 子命令级别的参数要求
///
/// 多子命令工具（inject 19 个、app 20 个）的痛点：所有参数平铺在一起，
/// AI 看不出「inspect 只要 bundle_id」「enable 要 bundle_id + dylib_path」。
/// 这里按子命令声明必需/可选参数，生成时拼进该子命令的说明里。
public struct ToolVariant {
    public let command: String
    /// 该子命令必填的参数
    public let requires: [String]
    /// 该子命令会用到（可空）的参数
    public let accepts: [String]
    /// 一句话说明
    public let note: String?

    public init(_ command: String, requires: [String] = [], accepts: [String] = [], note: String? = nil) {
        self.command = command
        self.requires = requires
        self.accepts = accepts
        self.note = note
    }

    /// 生成给模型看的一行:「inspect → 需要: bundle_id」
    public var cheatsheet: String {
        var s = command
        if !requires.isEmpty {
            s += " → 必填: " + requires.joined(separator: "+")
        }
        if !accepts.isEmpty {
            s += "，可选: " + accepts.joined(separator: "/")
        }
        if let note { s += "（\(note)）" }
        return s
    }
}
