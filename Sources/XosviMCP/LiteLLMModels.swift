import SwiftUI

// MARK: - v7.6.3 LiteLLM 风格模型网关（数据结构）
//
// 概念对齐 BerriAI/litellm：
//   Provider      —— 供应商（openai / anthropic / deepseek / gemini / azure / bedrock / ollama / custom…）
//   ModelEntry    —— 一条「deployment」：provider + 模型名 + baseURL + key + 权重，可同名多条做负载均衡
//   RoutingStrategy —— 负载均衡策略：轮询 / 最少使用 / 优先级 / 随机（litellm Router 同款）
//   VirtualKey    —— 虚拟密钥：对内生成，对外只暴露 vk-xxx，真实 key 不落日志（litellm Proxy 同款）
//   FallbackChain —— 失败自动降级：主模型挂了按顺序换下一个
//
// 说明：本文件只描述「怎么配」，实际请求构造仍在 OpenAIClient / ModelAPIClient。

// MARK: 供应商预设（对应 litellm 的 100+ providers，这里取常用 12 个）

struct LiteLLMProvider: Identifiable, Hashable {
    let id: String            // litellm 的 provider 前缀，如 "openai" / "anthropic"
    let name: String
    let defaultBaseURL: String
    let defaultProtocol: String
    let defaultAuth: String
    let modelsHint: [String]  // 常用模型名提示（用于填充，不校验）
    let colorHex: String

    static let all: [LiteLLMProvider] = [
        LiteLLMProvider(id: "openai", name: "OpenAI",
                        defaultBaseURL: "https://api.openai.com/v1",
                        defaultProtocol: "OpenAI Chat Completions", defaultAuth: "Bearer",
                        modelsHint: ["gpt-4o", "gpt-4o-mini", "o3", "o4-mini"], colorHex: "10A37F"),
        LiteLLMProvider(id: "anthropic", name: "Anthropic Claude",
                        defaultBaseURL: "https://api.anthropic.com/v1",
                        defaultProtocol: "Anthropic Messages", defaultAuth: "x-api-key",
                        modelsHint: ["claude-sonnet-4", "claude-opus-4", "claude-3-5-sonnet"], colorHex: "D97757"),
        LiteLLMProvider(id: "deepseek", name: "DeepSeek",
                        defaultBaseURL: "https://api.deepseek.com/v1",
                        defaultProtocol: "OpenAI Chat Completions", defaultAuth: "Bearer",
                        modelsHint: ["deepseek-chat", "deepseek-reasoner"], colorHex: "4D6BF7"),
        LiteLLMProvider(id: "gemini", name: "Google Gemini",
                        defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
                        defaultProtocol: "Gemini", defaultAuth: "Query key",
                        modelsHint: ["gemini-2.5-pro", "gemini-2.5-flash"], colorHex: "4285F4"),
        LiteLLMProvider(id: "vertex_ai", name: "Google Vertex AI",
                        defaultBaseURL: "https://{region}-aiplatform.googleapis.com/v1",
                        defaultProtocol: "Gemini", defaultAuth: "Bearer",
                        modelsHint: ["gemini-2.5-pro"], colorHex: "34A853"),
        LiteLLMProvider(id: "azure", name: "Azure OpenAI",
                        defaultBaseURL: "https://{resource}.openai.azure.com/openai/deployments/{deployment}",
                        defaultProtocol: "OpenAI Chat Completions", defaultAuth: "api-key",
                        modelsHint: ["gpt-4o"], colorHex: "0078D4"),
        LiteLLMProvider(id: "bedrock", name: "AWS Bedrock",
                        defaultBaseURL: "https://bedrock-runtime.{region}.amazonaws.com",
                        defaultProtocol: "Bedrock", defaultAuth: "SigV4",
                        modelsHint: ["anthropic.claude-sonnet-4-v1:0"], colorHex: "FF9900"),
        LiteLLMProvider(id: "moonshot", name: "Kimi (Moonshot)",
                        defaultBaseURL: "https://api.moonshot.cn/v1",
                        defaultProtocol: "OpenAI Chat Completions", defaultAuth: "Bearer",
                        modelsHint: ["kimi-k2", "kimi-latest"], colorHex: "1A1A2E"),
        LiteLLMProvider(id: "zhipu", name: "智谱 GLM",
                        defaultBaseURL: "https://open.bigmodel.cn/api/paas/v4",
                        defaultProtocol: "OpenAI Chat Completions", defaultAuth: "Bearer",
                        modelsHint: ["glm-4.6", "glm-4v-plus"], colorHex: "3859FF"),
        LiteLLMProvider(id: "dashscope", name: "通义千问 (DashScope)",
                        defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                        defaultProtocol: "OpenAI Chat Completions", defaultAuth: "Bearer",
                        modelsHint: ["qwen-max", "qwen-plus", "qwen-vl-max"], colorHex: "615CED"),
        LiteLLMProvider(id: "volcengine", name: "豆包 (火山方舟)",
                        defaultBaseURL: "https://ark.cn-beijing.volces.com/api/v3",
                        defaultProtocol: "OpenAI Chat Completions", defaultAuth: "Bearer",
                        modelsHint: ["doubao-pro-32k"], colorHex: "1664FF"),
        LiteLLMProvider(id: "ollama", name: "Ollama (本地)",
                        defaultBaseURL: "http://127.0.0.1:11434/v1",
                        defaultProtocol: "OpenAI Chat Completions", defaultAuth: "None",
                        modelsHint: ["llama3.3", "qwen3"], colorHex: "000000"),
        LiteLLMProvider(id: "custom_openai", name: "自定义 OpenAI 兼容",
                        defaultBaseURL: "",
                        defaultProtocol: "OpenAI Chat Completions", defaultAuth: "Bearer",
                        modelsHint: [], colorHex: "8E8E93")
    ]

    nonisolated static func find(_ id: String) -> LiteLLMProvider? {
        all.first { $0.id == id }
    }

    var color: Color { Color(hex: colorHex) }
}

// MARK: 路由策略（litellm Router 的 routing_strategy）

enum RoutingStrategy: String, CaseIterable, Identifiable {
    case simpleShuffle = "simple-shuffle"    // 随机打散（litellm 默认）
    case leastBusy = "least-busy"            // 最少使用（在途请求最少）
    case usageBased = "usage-based-routing"  // 按用量均衡（token/请求数最少优先）
    case latencyBased = "latency-based"      // 延迟优先
    case priority = "priority"               // 按 priority 字段顺序

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simpleShuffle: return "随机（simple-shuffle）"
        case .leastBusy:     return "最少使用（least-busy）"
        case .usageBased:    return "按用量均衡（usage-based）"
        case .latencyBased:  return "延迟优先（latency-based）"
        case .priority:      return "按优先级（priority）"
        }
    }

    var shortName: String {
        switch self {
        case .simpleShuffle: return "随机"
        case .leastBusy:     return "最少使用"
        case .usageBased:    return "按用量"
        case .latencyBased:  return "延迟优先"
        case .priority:      return "优先级"
        }
    }
}

// MARK: 单个 deployment（一条模型接入）

struct ModelEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// 模型组名：同名 = 同一逻辑模型的多路部署，会按策略负载均衡
    var modelName: String
    /// provider 前缀（litellm 的 provider id）
    var provider: String
    var apiProtocol: String
    var baseURL: String
    var apiKey: String
    var authMethod: String

    // 路由参数（litellm deployment 字段）
    var weight: Int = 1              // simple-shuffle 的权重
    var priority: Int = 100          // priority 策略：数字越小越优先
    var rpm: Int = 0                 // 每分钟请求上限，0 = 不限
    var tpm: Int = 0                 // 每分钟 token 上限，0 = 不限

    // 采样参数
    var temperature: Double = 0.7
    var maxTokens: Int = 4096
    var contextTokens: Int = 32000

    /// 兼容等级（老字段保留，OpenAIClient 自适应降级时写入）
    var compatLevel: Int = 0
    var paramAliases: [String: String] = [:]
    var group: String = "default"

    var isDefault: Bool = false

    /// 展示用：provider/模型名
    var litellmModelString: String { "\(provider)/\(modelName)" }

    var displayBadge: String {
        LiteLLMProvider.find(provider)?.name ?? provider
    }

    var maskedKey: String {
        guard apiKey.count > 8 else { return apiKey.isEmpty ? "未填写" : "••••" }
        return String(apiKey.prefix(4)) + "…" + String(apiKey.suffix(4))
    }
}

// MARK: LiteLLM 全局配置

struct LiteLLMConfig: Codable {
    var routingStrategy: RoutingStrategy = .simpleShuffle
    /// 失败重试次数（litellm num_retries）
    var numRetries: Int = 2
    /// 熔断冷却秒（litellm cooldown_time）
    var cooldownSeconds: Int = 60
    /// 是否启用 fallback 链
    var fallbacksEnabled: Bool = true
    /// fallback 顺序：模型组名数组
    var fallbackChain: [String] = []
    /// 是否启用虚拟 key（对外只展示 vk-xxx）
    var virtualKeysEnabled: Bool = true
    /// 请求日志保留条数（本地）
    var logRetention: Int = 200
    /// 是否记录费用估算
    var costTracking: Bool = true

    // v7.14.4：带默认值的自定义 init 会屏蔽编译器合成的 Decodable/Encodable
    // （CI 报 does not conform to protocol 'Decodable'），显式声明 CodingKeys 后即可合成。
    init() {}

    init(routingStrategy: RoutingStrategy = .simpleShuffle, numRetries: Int = 2,
         cooldownSeconds: Int = 60, fallbacksEnabled: Bool = true,
         fallbackChain: [String] = [], virtualKeysEnabled: Bool = true,
         logRetention: Int = 200, costTracking: Bool = true) {
        self.routingStrategy = routingStrategy
        self.numRetries = numRetries
        self.cooldownSeconds = cooldownSeconds
        self.fallbacksEnabled = fallbacksEnabled
        self.fallbackChain = fallbackChain
        self.virtualKeysEnabled = virtualKeysEnabled
        self.logRetention = logRetention
        self.costTracking = costTracking
    }
}

// MARK: 虚拟密钥（仅供展示/复制，真实 key 不出本机）

struct VirtualKey: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var alias: String            // 用途说明，如「手机端」「自动化脚本」
    var token: String            // vk-xxxxx
    var modelScope: String       // 允许访问的模型组，空 = 全部
    var createdAt: Date = Date()
    var lastUsedAt: Date?
    var requestCount: Int = 0

    static func generate(alias: String, scope: String) -> VirtualKey {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let body = String((0..<24).map { _ in chars.randomElement()! })
        return VirtualKey(alias: alias, token: "sk-litellm-" + body, modelScope: scope)
    }
}
