import Foundation

// MARK: - v7.1.0 通用子代理（subagent）
//
// 解决的核心问题：主对话里"要转好几轮的探索型任务"（翻文件、试命令、查一堆网页、对比多个方案）
// 会把主上下文撑爆，用户也看不清结论在哪。
//
// 做法：独立开一个**模型调用 + 工具循环**，给它一份自包含的任务书，
// 它自己用工具跑到底，只把结论交回来；过程的每一轮都写进会话里的步骤卡，用户能展开看。
//
// 设计要点：
//   1. 复用主对话的 OpenAIClient / ToolRegistry，不另造一套网络层
//   2. 子代理用**同一套已启用工具**（可 exclude 掉自己，避免套娃）
//   3. 轮次上限 max_rounds（默认 12），超了强制要求它给出结论
//   4. 上下文按字符预算裁剪（默认 12 万字符），防止子代理自己爆
//   5. 同步执行（MCP 工具只能同步返回），但每轮都有进度回调 → UI 实时可见
//   6. v8.1：执行核心抽成 executeCore(task:...) —— 串行版 invoke 与并行派发器
//      （SubagentDispatcher）共用同一套循环/轮次上限/熔断消费/上下文裁剪逻辑

/// v8.1：任务参数白名单（并行派发与单任务共用）
enum SubagentSandbox {
    /// 子代理绝不能碰的写操作/系统级工具（并发跑写操作会互相踩）
    static let forbidden = Set<String>([
        "inject", "app", "control", "package", "subagent", "jbplot",
        "app_write_file", "bind_app_write", "macro", "automation", "project",
        "rescue", "root", "engine", "control_console"
    ])
    /// 工具名是否允许：显式 allow 白名单优先，否则按黑名单过滤
    static func allow(_ originalName: String, allowList: Set<String>?) -> Bool {
        let root = originalName.components(separatedBy: ".").first ?? originalName
        if forbidden.contains(originalName) || forbidden.contains(root) { return false }
        if let allow = allowList {
            return allow.contains(originalName) || allow.contains(root)
        }
        return true
    }
}

final class SubagentTool: MCPTool {

    /// 进度回调：runLoop 里挂上，用来在会话里更新"子代理运行中"卡片
    static var progressHandler: ((_ round: Int, _ note: String) -> Void)?

    let definition = ToolDefinition(
        name: "subagent",
        summary: """
        通用子代理：把一件**需要多轮探索**的事整套甩给它，它自己调工具跑完，只把结论交回来。 \
        支持两种用法：单任务（task 参数，串行）或多任务并行（tasks 数组，≤6 个并发跑、各自独立上下文）。 \
        Use for: 翻很多文件/试多条命令/查一堆网页/对比多个方案才得出结论的任务；或 3 个以上互不依赖的子任务（用 tasks 并行）；或者你想省主上下文时。 \
        Don't use for: 一步就能完成的动作（直接调对应工具）、需要用户拍板的选择、彼此有依赖的步骤（有依赖就先做 A 再派 B）。 \
        写法要求：task/每个子任务的 prompt 必须自包含——子代理看不到本段对话，要把目标、已知路径/URL、约束、要它返回什么写清楚。 \
        Example: 用户问"项目里哪些地方用了旧浏览器 API" → subagent {task:'在 Sources 下找出所有仍引用 BrowserManager / FloatingBrowser 的文件与行号，按文件分组返回', tools:'rg'}；\
        多个独立检索 → subagent {tasks:'[{"title":"查A","prompt":"..."},{"title":"查B","prompt":"..."}]'}
        """,
        parameters: [
            "task": "完整任务书（自包含：目标 + 已知路径/URL + 约束 + 期望返回格式）",
            "tasks": "可选：并行派发多任务，JSON 数组 [{\"title\":..., \"prompt\":..., \"tools\":[\"web.search\",\"file\"]}]（≤6 个，各自独立上下文并发跑，只回摘要）",
            "context": "可选：要原样交给子代理的素材（文件片段、报错输出、候选链接）",
            "tools": "可选：只给子代理这几个工具，逗号分隔（如 shell.exec,workspace,web.search）；不填=用当前已启用的全部工具",
            "exclude": "可选：禁用某些工具，逗号分隔（默认自动排除 subagent 自己，防止套娃）",
            "max_rounds": "最多工具轮次（默认 12，最大 40）",
            "model": "可选：指定模型名（默认用当前会话的模型配置）",
            "reasoning": "思考强度 0低/1中/2高/3最高/4极限（默认 1）"
        ],
        returns: [
            "ok": "是否跑完（false 可能是超轮次或模型报错）",
            "result": "子代理的最终结论（正文）",
            "rounds": "实际用了几轮",
            "steps": "每轮做了什么（工具名 + 简要参数）",
            "error": "失败原因（可选）"
        ],
        verified: false, category: "automation",
        uiSummary: "子代理：多轮探索任务交给它跑，只回结论"
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        // v8.1：tasks 数组 → 并行派发；否则走原来的单任务串行路径
        if let raw = params["tasks"] as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            return try invokeParallel(raw)
        }
        if let arr = params["tasks"] as? [[String: Any]], !arr.isEmpty {
            let encoded = try? JSONSerialization.data(withJSONObject: arr)
            if let s = encoded.flatMap({ String(data: $0, encoding: .utf8) }) {
                return try invokeParallel(s)
            }
        }
        let task = (params["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !task.isEmpty else { throw MCPError.invalidParams("task required（要写自包含的任务书）") }

        AuditLog.shared.log("subagent", detail: String(task.prefix(120)))

        guard let config = resolveConfig(params) else {
            throw MCPError.failed("没有可用的模型配置：请先在设置里添加模型，或用 model 参数指定")
        }
        let maxRounds = min(max(params["max_rounds"] as? Int ?? 12, 1), 40)
        let reasoning = min(max(params["reasoning"] as? Int ?? 1, 0), 4)

        // v8.1：执行核心抽出为静态方法，单任务与并行派发共用（返回结构化结果）
        let core = Self.executeCore(task: task, context: params["context"] as? String,
                                    tools: params["tools"] as? String,
                                    exclude: params["exclude"] as? String,
                                    maxRounds: maxRounds, config: config,
                                    reasoning: reasoning,
                                    progress: { round, note in
                                        SubagentTool.progressHandler?(round, note)
                                    })
        return core
    }

    // MARK: - v8.1 执行核心（单任务与并行派发共用）

    /// 一次受限的多轮工具循环。串行版 invoke 与 SubagentDispatcher 都走这里，
    /// 保证轮次上限 / 熔断消费 / 上下文裁剪 / 工具黑名单行为一致。
    static func executeCore(task: String,
                            context: String?,
                            tools: String?,
                            exclude: String?,
                            maxRounds: Int,
                            config: ModelConfig,
                            reasoning: Int,
                            progress: ((Int, String) -> Void)?) -> [String: Any] {
        let budget = 120_000

        // 工具集：白名单 / 黑名单
        let allowed: Set<String>? = {
            guard let s = tools, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return Set(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }()
        var excluded: Set<String> = ["subagent"]
        if let s = exclude {
            s.split(separator: ",").forEach { excluded.insert($0.trimmingCharacters(in: .whitespaces)) }
        }

        var schemas = ToolRegistry.shared.enabledOpenAIToolSchema()
        schemas = schemas.filter { schema in
            guard let fn = schema["function"] as? [String: Any], let name = fn["name"] as? String else { return false }
            // apiName 是下划线安全名，用原始名判断更准
            let original = ToolRegistry.shared.tool(named: name)?.definition.name ?? name
            if excluded.contains(original) || excluded.contains(name) { return false }
            if let allowed = allowed {
                return allowed.contains(original) || allowed.contains(name) || allowed.contains(original.components(separatedBy: ".").first ?? "")
            }
            return true
        }

        // 子代理的人格：只认任务书，不要客套，不要反问用户
        let system = """
        你是一个在后台运行的子代理。你没有对话历史，只有下面这项任务。
        规则：
        1. 任务要求什么就做什么；自包含信息不足时**自行用工具查证**，不要反问、不要停下来等人。
        2. 能一条命令/一次检索搞定的事就一次搞定，不要为了看起来勤奋而重复劳动。
        3. 结束时只输出**结论**：结果、关键证据（文件:行号 / URL / 命令输出片段）。不要复述过程，不要客套。
        4. 做不到就直说做不到，并给出你试过什么、卡在哪里。
        工具调用轮次上限 \(maxRounds) 轮。
        """

        var userText = "任务：\n\(task)"
        if let ctx = context, !ctx.isEmpty {
            userText += "\n\n参考素材（原样提供）：\n\(ctx)"
        }

        // v8.1：工具黑名单兜底（与并行派发共用 SubagentSandbox）
        // —— 单任务串行版同样禁止把写操作工具交给子代理
        schemas = schemas.filter { schema in
            guard let fn = schema["function"] as? [String: Any],
                  let name = fn["name"] as? String else { return false }
            let original = ToolRegistry.shared.tool(named: name)?.definition.name ?? name
            return SubagentSandbox.allow(original, allowList: nil)
        }

        var history: [ChatMessage] = [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: userText)
        ]

        var steps: [[String: Any]] = []
        var round = 0
        var finalText = ""
        var failure: String? = nil

        while round <= maxRounds {
            round += 1
            progress?(round, round == 1 ? "子代理开始" : "第 \(round) 轮")

            // 上下文预算裁剪：保留 system + 最后若干条（工具结果可能很长）
            history = Self.trim(history, budget: budget)

            let forceFinal = round > maxRounds
            if forceFinal {
                history.append(ChatMessage(role: "user", content: "已到轮次上限。现在不要再调工具，直接给出你能确定的结论。"))
            }

            let sem = DispatchSemaphore(value: 0)
            var outcome: Result<ChatResult, Error>?
            let client = OpenAIClient(config)
            client.currentReasoningLevel = reasoning
            client.send(messages: history,
                        tools: forceFinal ? nil : schemas,
                        onStatus: { _ in },
                        onDelta: { _ in },
                        onThinking: { _ in }) { r in
                outcome = r
                sem.signal()
            }
            if sem.wait(timeout: .now() + 600) == .timedOut {
                failure = "子代理单轮请求超时（600 秒）"
                break
            }
            guard let result = outcome else {
                failure = "子代理没有返回结果"
                break
            }

            switch result {
            case .success(.text(let text, _)):
                finalText = text
                round -= 1   // 这轮没调工具，不计入工具轮次
            case .success(.toolCalls(let calls, _, let content)):
                guard let call = calls.first else {
                    finalText = content ?? ""
                    break
                }
                let args = Self.parseArgs(call.arguments)
                var asst = ChatMessage(role: "assistant", content: content ?? "")
                asst.toolCalls = [call]
                history.append(asst)

                var step: [String: Any] = ["round": round, "tool": call.name, "args": Self.shortArgs(args)]
                var toolOutput = ""
                do {
                    let r = try ToolRegistry.shared.dispatch(name: call.name, params: args)
                    toolOutput = Self.stringify(r)
                    step["ok"] = true
                } catch {
                    toolOutput = "工具调用失败：\(error)"
                    step["ok"] = false
                }
                // v8（P0-1）：熔断/终止标记必须被消费——否则子代理会继续撞同一面墙
                if RunScope.consumeAbort(RunScope.currentToken) {
                    finalText = "[[RUN_TERMINATED]] 子代理已停止：连续相同参数失败，本轮终止。"
                    failure = nil
                    break
                }
                // 单条工具结果截断，防止一次把预算吃光
                if toolOutput.count > 12_000 {
                    toolOutput = String(toolOutput.prefix(12_000)) + "\n…（已截断，共 \(toolOutput.count) 字）"
                }
                step["output_chars"] = toolOutput.count
                steps.append(step)
                progress?(round, "\(call.name)：\(Self.shortArgs(args))")
                history.append(ChatMessage(role: "tool", content: toolOutput,
                                           toolCallId: call.id, toolName: call.name))
                // 如果模型一次批了多个调用，剩下的按"未执行"补空结果，保持历史合法
                for extra in calls.dropFirst() {
                    history.append(ChatMessage(role: "tool", content: "（未执行：一次只跑一个工具）",
                                               toolCallId: extra.id, toolName: extra.name))
                }
                continue
            case .failure(let err):
                failure = err.localizedDescription
            }
            break
        }

        var out: [String: Any] = [
            "ok": failure == nil && !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "result": finalText,
            "rounds": round,
            "steps": steps,
            "model": config.name
        ]
        if let f = failure { out["error"] = f }
        AuditLog.shared.log("subagent", detail: "rounds=\(round) chars=\(finalText.count)")
        return out
    }

    // MARK: - v8.1 并行派发（tasks 数组）

    /// tasks: JSON 数组 [{title, prompt, tools?}]，最多 6 个；白名单交集后交给 SubagentDispatcher。
    private func invokeParallel(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([SubagentTask].self, from: data),
              !arr.isEmpty else {
            throw MCPError.invalidParams("tasks 必须是 JSON 数组：[{\"title\":..., \"prompt\":..., \"tools\":[...]}]")
        }
        guard arr.count <= 6 else {
            throw MCPError.invalidParams("最多 6 个子任务，超出请分批派发")
        }
        // 白名单交集：prompt 里声明的 tools 与安全名单求交；结果为空则给默认只读组合
        let tasks: [SubagentTask] = arr.map { t in
            var c = t
            let requested = Set(c.tools.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            c.tools = requested.filter { SubagentSandbox.allow($0, allowList: nil) }.sorted()
            if c.tools.isEmpty { c.tools = ["web.search", "web.fetch"] }
            c.prompt = """
            【子任务：\(c.title.isEmpty ? "(未命名)" : c.title)】
            \(c.prompt)
            （提示：你没有主对话历史，本 prompt 必须自包含；可用工具：\(c.tools.joined(separator: ", "))）
            """
            return c
        }

        guard let config = ModelStore.shared.defaultConfig else {
            throw MCPError.failed("没有可用的模型配置：请先在 设置 → 模型API 添加")
        }

        AuditLog.shared.log("subagent.parallel", detail: "tasks=\(tasks.count)")

        let sem = DispatchSemaphore(value: 0)
        var out: [SubagentTask] = []
        // 进度：借用 progressHandler（runLoop 已挂到状态栏），把每个子任务的状态变化推给 UI
        SubagentDispatcher.runAll(tasks: tasks, config: config, onUpdate: { idx, t in
            SubagentTool.progressHandler?(idx + 1, "[\(t.status)] \(t.title)")
        }, completion: { results in
            out = results
            sem.signal()
        })
        if sem.wait(timeout: .now() + 3600) == .timedOut {
            throw MCPError.failed("并行子代理整体超时（3600 秒）")
        }

        let done = out.filter { $0.status == "done" }.count
        return [
            "ok": done > 0,
            "total": out.count,
            "done": done,
            "failed": out.filter { $0.status == "failed" }.count,
            "results": out.map { ["title": $0.title, "status": $0.status, "result": $0.result] },
            "note": "各子任务独立上下文并发执行；结果为各任务摘要，由你综合后答复用户。"
        ]
    }

    // MARK: - 辅助

    private func resolveConfig(_ params: [String: Any]) -> ModelConfig? {
        let store = ModelStore.shared
        if let name = params["model"] as? String, !name.isEmpty {
            if let c = store.configs.first(where: { $0.name == name || $0.model == name }) { return c }
        }
        return store.defaultConfig
    }

    /// 上下文裁剪：保留首条 system + 片段里最近的内容，超预算就从中间丢
    static func trim(_ history: [ChatMessage], budget: Int) -> [ChatMessage] {
        var total = history.reduce(0) { $0 + $1.content.count }
        guard total > budget else { return history }
        var out = history
        // 先砍中间的工具结果（保留最后 4 条便于衔接）
        var i = 1
        while total > budget && i < max(out.count - 4, 1) {
            let c = out[i].content.count
            if c > 400 {
                out[i].content = String(out[i].content.prefix(400)) + "\n…（较早内容已裁剪以控制上下文）"
                total -= (c - 400)
            }
            i += 1
        }
        return out
    }

    static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        guard JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(withJSONObject: v),
              let s = String(data: data, encoding: .utf8) else { return String(describing: v) }
        return s
    }

    static func shortArgs(_ params: [String: Any]) -> String {
        let s = stringify(params)
        return s.count > 200 ? String(s.prefix(200)) + "…" : s
    }
}
