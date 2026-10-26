import Foundation

// MARK: - v7.10.0 ghost 工具：技能回放 / 自动探索 / 技能生成
//
// 对应 ghost-in-the-droid 的能力，但驱动换成 ControlAgent：
//   skill.list / show / save / delete   —— 技能管理
//   skill.run                          —— 确定性回放（零 LLM）
//   skill.elements                     —— 列出当前界面可点元素（写技能用）
//   skill.explore                      —— BFS 自动遍历 App 界面，产出界面图
//   skill.draft                        —— 把当前界面 + 探索结果变成技能骨架

final class GhostTool: MCPTool {
    let definition = ToolDefinition(
        name: "ghost",
        summary: """
        技能回放与界面探索（移植自 ghost-in-the-droid 的 skills 思路）。
        核心：已知流程编成「元素定义 + 动作序列」，回放时**不花 token**、几秒跑完；只有未知任务才现想。
        子命令：
          list / show / delete / save  —— 技能管理
          run {name|id}                —— 确定性回放
          elements                     —— 列出当前界面可点元素（写技能用）
          explore {max_screens}        —— BFS 遍历 App 界面，输出界面图
          draft {name}                 —— 用当前界面生成技能骨架
        前置：要操作 App 必须先 control inject 注入 ControlAgent（技能里写 bundleId 会自动注入）。
        Example: 用户说"每天都帮我点赞第一篇" → run {name:"小红书点赞"}；还不知道怎么点时先 explore 看看有哪些界面。
        """,
        parameters: [
            "command": "list / show / run / save / delete / elements / explore / draft",
            "name": "技能名（run/save/delete/draft 用）",
            "id": "技能 id（run/delete 用，优先于 name）",
            "bundle_id": "目标 App bundleId（save / explore 用）",
            "max_screens": "explore 最多探索多少个界面（默认 15，上限 40）",
            "max_depth": "explore 最大跳转深度（默认 3）",
            "steps": "save 用：动作数组 JSON，如 [{\"action\":\"tap\",\"target\":\"btn\"}]",
            "elements": "save 用：元素定义 JSON，如 [{\"id\":\"btn\",\"label\":\"登录\"}]",
            "dry_run": "true=只校验技能不真的执行"
        ],
        returns: ["ok": "是否成功", "steps": "每步结果", "skills": "技能列表", "screens": "探索到的界面"],
        verified: false, category: "automation",
        uiSummary: "技能回放 / 界面自动探索（零 token 重放已知流程）"
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let cmd = (params["command"] as? String)?.lowercased(), !cmd.isEmpty else {
            throw MCPError.invalidParams("command required: list / show / run / save / delete / elements / explore / draft")
        }
        AuditLog.shared.log("ghost", detail: "\(cmd) \(params["name"] as? String ?? "")")

        switch cmd {
        case "list":     return listSkills()
        case "show":     return try showSkill(params)
        case "run":      return try runSkill(params)
        case "save":     return try saveSkill(params)
        case "delete":   return try deleteSkill(params)
        case "elements": return try currentElements()
        case "explore":  return try explore(params)
        case "draft":    return try draft(params)
        default:
            throw MCPError.invalidParams("未知子命令：\(cmd)")
        }
    }

    // MARK: 管理

    private func listSkills() -> [String: Any] {
        let all = GhostSkillStore.shared.list()
        return ["ok": true, "count": all.count,
                "skills": all.map { s -> [String: Any] in
                    var d: [String: Any] = ["name": s.name, "id": s.id.uuidString,
                                            "steps": s.steps.count, "runs": s.runs]
                    if let b = s.bundleId { d["bundle_id"] = b }
                    d["updated_at"] = ISO8601DateFormatter().string(from: s.updatedAt)
                    if let r = s.lastResult { d["last_result"] = r }
                    return d
                }]
    }

    private func findSkill(_ params: [String: Any]) throws -> GhostSkill {
        let all = GhostSkillStore.shared.list()
        if let idStr = params["id"] as? String, let uuid = UUID(uuidString: idStr),
           let s = all.first(where: { $0.id == uuid }) { return s }
        if let name = params["name"] as? String,
           let s = all.first(where: { $0.name == name }) ?? all.first(where: { $0.name.contains(name) }) {
            return s
        }
        throw MCPError.failed("找不到技能「\(params["name"] as? String ?? params["id"] as? String ?? "")」。先 ghost list 看看有哪些。")
    }

    private func showSkill(_ params: [String: Any]) throws -> [String: Any] {
        let s = try findSkill(params)
        return ["ok": true,
                "name": s.name, "bundle_id": s.bundleId ?? "",
                "elements": s.elements.map { ["id": $0.id, "label": $0.label ?? "", "accessibility_id": $0.accessibilityId ?? ""] },
                "steps": s.steps.enumerated().map { i, st -> [String: Any] in
                    var d: [String: Any] = ["index": i + 1, "action": st.action.rawValue]
                    if let t = st.target { d["target"] = t }
                    if let t = st.text { d["text"] = t }
                    if let k = st.key { d["key"] = k }
                    if let sec = st.seconds { d["seconds"] = sec }
                    return d
                }]
    }

    private func deleteSkill(_ params: [String: Any]) throws -> [String: Any] {
        let s = try findSkill(params)
        GhostSkillStore.shared.delete(s.id)
        return ["ok": true, "deleted": s.name]
    }

    private func saveSkill(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPError.invalidParams("name required")
        }
        // 支持传 JSON 字符串或已解析的数组
        let elements = try decodeArray(params["elements"], as: SkillElement.self, label: "elements")
        let steps = try decodeArray(params["steps"], as: SkillStep.self, label: "steps")
        guard !steps.isEmpty else { throw MCPError.invalidParams("steps 不能为空") }

        var skill = GhostSkillStore.shared.list().first { $0.name == name } ?? GhostSkill(name: name)
        skill.name = name
        if let b = params["bundle_id"] as? String, !b.isEmpty { skill.bundleId = b }
        if !elements.isEmpty { skill.elements = elements }
        skill.steps = steps
        GhostSkillStore.shared.save(skill)
        return ["ok": true, "name": name, "id": skill.id.uuidString,
                "elements": skill.elements.count, "steps": skill.steps.count,
                "path": "Workspace/ghost-skills/\(skill.id.uuidString).json"]
    }

    private func decodeArray<T: Decodable>(_ raw: Any?, as: T.Type, label: String) throws -> [T] {
        if let arr = raw as? [T] { return arr }
        guard let str = raw as? String, let data = str.data(using: .utf8) else { return [] }
        do { return try JSONDecoder().decode([T].self, from: data) }
        catch { throw MCPError.invalidParams("\(label) 解析失败：\(error.localizedDescription)") }
    }

    // MARK: 回放

    private func runSkill(_ params: [String: Any]) throws -> [String: Any] {
        let skill = try findSkill(params)
        let dry = params["dry_run"] as? Bool ?? false

        if dry {
            return ["ok": true, "dry_run": true, "name": skill.name,
                    "steps": skill.steps.count,
                    "plan": skill.steps.enumerated().map { "\($0.offset + 1). \($0.element.action.displayName)\($0.element.target.map { " → \($0)" } ?? "")" }]
        }

        let r = GhostRunner.run(skill)
        // 记录运行结果
        var s = skill
        s.runs += 1
        s.lastResult = r.ok ? "成功（\(r.steps.count) 步）" : "失败：\(r.error ?? "")"
        GhostSkillStore.shared.save(s)

        return ["ok": r.ok,
                "name": skill.name,
                "elapsed_ms": r.steps.reduce(0) { $0 + $1.ms },
                "steps": r.steps.map { x -> [String: Any] in
                    ["index": x.index, "action": x.action, "ok": x.ok, "detail": x.detail, "ms": x.ms]
                },
                "error": r.error ?? ""]
    }

    // MARK: 元素 / 探索 / 草稿

    private func currentTree() throws -> [String: Any] {
        let r = try ToolRegistry.shared.dispatch(name: "control", params: ["command": "ui_tree"])
        if let e = r["error"] as? String {
            throw MCPError.failed("拿不到界面树：\(e)。确认 ControlAgent 已注入且目标 App 在前台。")
        }
        return r
    }

    private func currentElements() throws -> [String: Any] {
        let tree = try currentTree()
        let items = GhostRunner.tappables(tree)
        return ["ok": true, "count": items.count,
                "signature": GhostRunner.screenSignature(tree),
                "elements": items.prefix(80).map { e -> [String: Any] in
                    ["label": e.label, "type": e.type,
                     "nx": (e.cx * 1000).rounded() / 1000,
                     "ny": (e.cy * 1000).rounded() / 1000]
                }]
    }

    /// BFS 遍历：从当前界面出发，逐个点可点元素，记录"从哪个界面点哪个元素到了哪个界面"
    private func explore(_ params: [String: Any]) throws -> [String: Any] {
        let maxScreens = min(max(params["max_screens"] as? Int ?? 15, 1), 40)
        let maxDepth = min(max(params["max_depth"] as? Int ?? 3, 1), 6)

        var screens: [[String: Any]] = []
        var edges: [[String: Any]] = []
        var visited = Set<String>()

        struct Node { var sig: String; var depth: Int }
        var queue: [Node] = []

        let root = try currentTree()
        let rootSig = GhostRunner.screenSignature(root)
        visited.insert(rootSig)
        queue.append(Node(sig: rootSig, depth: 0))
        screens.append(["index": screens.count, "depth": 0,
                        "labels": Array(GhostRunner.flatten(root).prefix(15))])

        var guardCount = 0
        while !queue.isEmpty && screens.count < maxScreens && guardCount < maxScreens * 4 {
            guardCount += 1
            let node = queue.removeFirst()
            if node.depth >= maxDepth { continue }

            // 回到当前节点所在界面（简单策略：回退到根再顺路径——这里退化为 back 若干次）
            _ = try? ToolRegistry.shared.dispatch(name: "control", params: ["command": "key", "key": "back"])

            let tree = (try? currentTree()) ?? [:]
            let currentSig = GhostRunner.screenSignature(tree)
            if currentSig != node.sig { continue }   // 回不到就跳过

            let targets = GhostRunner.tappables(tree).prefix(12)
            for t in targets {
                if screens.count >= maxScreens { break }
                // 点它
                let tapped = try? ToolRegistry.shared.dispatch(name: "control",
                                                              params: ["command": "tap_text", "text": t.label, "partial": true])
                if tapped == nil { continue }
                Thread.sleep(forTimeInterval: 1.0)

                guard let after = try? currentTree() else { continue }
                let sig = GhostRunner.screenSignature(after)
                if sig == node.sig { continue }   // 界面没变，不是跳转

                edges.append(["from": node.sig, "to": sig, "via": t.label])
                if visited.insert(sig).inserted {
                    screens.append(["index": screens.count, "depth": node.depth + 1,
                                    "signature": sig,
                                    "labels": Array(GhostRunner.flatten(after).prefix(15))])
                    queue.append(Node(sig: sig, depth: node.depth + 1))
                }
                // 退出这个新界面
                _ = try? ToolRegistry.shared.dispatch(name: "control", params: ["command": "key", "key": "back"])
                Thread.sleep(forTimeInterval: 0.8)
            }
        }

        return ["ok": true,
                "screens": screens.count,
                "edges": edges.count,
                "graph": screens,
                "transitions": edges,
                "note": "探索会真的点按目标 App 的界面，可能产生副作用（发消息/下单）。"]
    }

    /// 用当前界面生成技能骨架：把可点元素直接变成元素定义，动作留空待模型补
    private func draft(_ params: [String: Any]) throws -> [String: Any] {
        let name = (params["name"] as? String) ?? "未命名技能"
        let tree = try currentTree()
        let items = GhostRunner.tappables(tree).prefix(20)

        var elements: [SkillElement] = []
        var steps: [SkillStep] = []
        for (i, e) in items.enumerated() {
            let id = "el\(i + 1)"
            elements.append(SkillElement(id: id, label: e.label, accessibilityId: nil,
                                         nx: (e.cx * 1000).rounded() / 1000,
                                         ny: (e.cy * 1000).rounded() / 1000))
            steps.append(SkillStep(action: .tap, target: id, optional: true))
        }

        return ["ok": true,
                "draft": ["name": name,
                          "bundle_id": params["bundle_id"] as? String ?? "",
                          "elements": elements.map { ["id": $0.id, "label": $0.label ?? "", "nx": $0.nx ?? 0, "ny": $0.ny ?? 0] },
                          "steps": steps.map { ["action": $0.action.rawValue, "target": $0.target ?? ""] }],
                "hint": "这是骨架：删掉不需要的步骤、调整顺序、补充 type/wait/assertText，然后用 ghost save 保存。"]
    }
}
