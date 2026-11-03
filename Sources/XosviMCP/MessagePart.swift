import Foundation

// MARK: - v9：结构化消息片段（移植 Kelivo MessagePart）
//
// 一条 assistant 消息 = [reasoning, toolCall, toolCall, text] 有序数组。
// 顺序信息是渲染层次的基础；旧版 content / toolCalls / thinking 三字段并行会丢顺序。
//
// 设计约束：
//  · Codable：跟 ChatMessage 一起持久化，老 JSON 缺该字段时不报错（Optional）。
//  · unknown(kind:payload:)：本版本不认识的新类型原样保留，回写不丢数据（前向兼容）。
//  · isModelInput：roundEnd / unknown 不回传给模型。

enum MessagePart: Codable, Hashable {
    case text(String)
    case reasoning(String)
    case toolCall(ToolCallPayload)
    case roundEnd(reasoningDetails: JSONValue?)
    case image(ImagePayload)
    case file(FilePayload)
    /// 前向兼容：本版本不认识的类型原样保留，回写不丢数据
    case unknown(kind: String, payload: String)

    var kind: String {
        switch self {
        case .text: return "text"
        case .reasoning: return "reasoning"
        case .toolCall: return "tool_call"
        case .roundEnd: return "assistant_round_end"
        case .image: return "image"
        case .file: return "file"
        case .unknown(let k, _): return k
        }
    }

    /// 是否回传给模型（结构边界与未知类型不回传）
    var isModelInput: Bool {
        switch self {
        case .roundEnd, .unknown: return false
        default: return true
        }
    }

    // MARK: Codable（手写：enum 带关联值，合成编码是嵌套 key，格式脆弱）

    private enum CodingKeys: String, CodingKey {
        case type, text, toolCall, reasoningDetails, image, file, unknownKind, unknownPayload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "reasoning":
            self = .reasoning(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "tool_call":
            self = .toolCall(try c.decode(ToolCallPayload.self, forKey: .toolCall))
        case "assistant_round_end":
            self = .roundEnd(reasoningDetails: try c.decodeIfPresent(JSONValue.self, forKey: .reasoningDetails))
        case "image":
            self = .image(try c.decode(ImagePayload.self, forKey: .image))
        case "file":
            self = .file(try c.decode(FilePayload.self, forKey: .file))
        default:
            self = .unknown(kind: type,
                            payload: try c.decodeIfPresent(String.self, forKey: .unknownPayload) ?? "")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .type)
        switch self {
        case .text(let t):
            try c.encode(t, forKey: .text)
        case .reasoning(let t):
            try c.encode(t, forKey: .text)
        case .toolCall(let p):
            try c.encode(p, forKey: .toolCall)
        case .roundEnd(let details):
            try c.encodeIfPresent(details, forKey: .reasoningDetails)
        case .image(let p):
            try c.encode(p, forKey: .image)
        case .file(let p):
            try c.encode(p, forKey: .file)
        case .unknown(let k, let payload):
            try c.encode(k, forKey: .unknownKind)
            try c.encode(payload, forKey: .unknownPayload)
        }
    }
}

struct ToolCallPayload: Codable, Hashable {
    var id: String
    var name: String
    /// JSON 字符串，原样保存（不做 parse，避免精度/键序丢失）
    var arguments: String
    /// 工具返回值（由 ToolResultMerger 从 role == "tool" 的消息回填）
    var result: String?
    var isError: Bool = false
    var durationMs: Int?
    /// 客户端 UI 资产，不进模型输入
    var previewImage: String?

    init(id: String, name: String, arguments: String,
         result: String? = nil, isError: Bool = false,
         durationMs: Int? = nil, previewImage: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.durationMs = durationMs
        self.previewImage = previewImage
    }
}

struct ImagePayload: Codable, Hashable {
    /// data URL（data:image/png;base64,...）或本地绝对路径
    var uri: String
    var mime: String?
    var assetId: String?
    var unavailable: Bool = false

    init(uri: String, mime: String? = nil, assetId: String? = nil, unavailable: Bool = false) {
        self.uri = uri
        self.mime = mime
        self.assetId = assetId
        self.unavailable = unavailable
    }
}

struct FilePayload: Codable, Hashable {
    var uri: String
    var name: String
    var mime: String?
    var assetId: String?
    var unavailable: Bool = false

    init(uri: String, name: String, mime: String? = nil,
         assetId: String? = nil, unavailable: Bool = false) {
        self.uri = uri
        self.name = name
        self.mime = mime
        self.assetId = assetId
        self.unavailable = unavailable
    }
}

/// 任意 JSON，用于 reasoningDetails 这类不透明的透传字段
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
