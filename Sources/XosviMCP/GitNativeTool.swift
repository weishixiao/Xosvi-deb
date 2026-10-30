import Foundation

// MARK: - MCP 工具：git（原生实现）

final class GitNativeTool: MCPTool {
    let definition = ToolDefinition(
        name: "git",
        summary: "Git operations WITHOUT any subprocess — works on jailed/rootHide devices where real git and python3 are blocked (ENOSYS 85). "
            + "Talks to GitHub REST API over URLSession with a real Authorization header (the built-in curl drops -H, web.fetch goes through a proxy that strips auth). "
            + "Commands: status / login / whoami / clone / pull / commit / build / log / branch / repos. "
            + "BUILD GATE (hard rule): if `build` shows the latest run failed, commit is REJECTED unless you pass build_red_ack=\"<run id>\" — i.e. you must fix that red build first, not stack unrelated changes. "
            + "Use for: read or write a GitHub repo from this device (clone source, review code, edit files, commit & push). "
            + "Don't use for: local-only git history (this keeps a lightweight manifest, not a .git directory). "
            + "AUTH: token comes from env vars (GITHUB_TOKEN / GH_TOKEN / GIT_TOKEN / GITHUB_PAT) or Keychain automatically — do NOT ask the user for a token; run git command:status first (ready:true means just clone). "
            + "Typical flow: git command:status → git command:clone repo:https://github.com/owner/name → edit files → git command:commit message:\"fix: ...\"。",
        parameters: [
            "command": "status / login / whoami / clone / pull / commit / build / log / branch / repos",
            "token": "for login: GitHub PAT (fine-grained 需 Contents: Read and write；classic 需 repo)",
            "repo": "for clone/repos: owner/name，例如 weishixiao/Xosvi",
            "path": "本地目录（默认 Workspace/<repo 名>），可相对或绝对",
            "branch": "分支（默认 main）",
            "message": "for commit: 提交信息",
            "files": "for commit: 只提交这些相对路径（逗号分隔，留空=全部改动）",
            "limit": "for log: 条数（默认 10）",
            "build_red_ack": "for commit: 最近一次构建失败时必须传它的 run id，否则拒绝提交"
        ],
        returns: [
            "ok": "是否成功",
            "commit": "commit 短 sha（commit 命令）",
            "files": "本地同步的文件数（clone）",
            "added/modified/deleted": "本次变更清单（commit）",
            "error": "失败原因"
        ],
        verified: false, category: "system",
        prerequisites: [
            "git command:login token:<PAT> —— token 存 Keychain，只需一次（或设置环境变量 GITHUB_TOKEN）",
            "git command:clone —— 先有本地副本才能 commit/pull"
        ])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let cmd = (params["command"] as? String)?.trimmingCharacters(in: .whitespaces), !cmd.isEmpty else {
            throw MCPError.invalidParams("command required: status/login/whoami/clone/pull/commit/log/branch/repos")
        }
        AuditLog.shared.log("git", detail: cmd)

        switch cmd {
        case "login":
            // v7.9.5：模型常把参数写成 pat / github_token / key，或者把 "Bearer " 一起粘进来。
            // 这里统一认；并且**用刚传入的 token 校验**——之前用 GitNative.api 走的是
            // "环境变量优先"的 token 取法，环境里若是旧 token 就会一直验不过。
            let rawToken = (params["token"] as? String)
                ?? (params["pat"] as? String)
                ?? (params["github_token"] as? String)
                ?? (params["key"] as? String)
                ?? ""
            let cleaned = GitNative.clean(rawToken)
            guard !cleaned.isEmpty else {
                throw MCPError.invalidParams("token required（也可用 pat / github_token / key）")
            }
            guard GitNative.saveToken(cleaned) else {
                throw MCPError.failed("保存 token 失败（Keychain 写入被拒）")
            }
            let v = GitNative.verifyToken(cleaned)
            if v.status == 200, let login = v.login {
                var out: [String: Any] = [
                    "ok": true, "user": login, "token": GitNative.mask(cleaned),
                    "message": "token 已保存到 Keychain，并验证可用",
                ]
                if let envTok = EnvVars.current()["GITHUB_TOKEN"].map(GitNative.clean),
                   !envTok.isEmpty, envTok != cleaned {
                    out["warning"] = "环境变量 GITHUB_TOKEN 仍然优先于 Keychain；如需用新 token，请先清掉那个环境变量"
                }
                return out
            }
            return ["ok": false, "token": GitNative.mask(cleaned),
                    "error": "token 已保存，但验证失败：HTTP \(v.status) \(v.error ?? "")",
                    "hint": "确认是 fine-grained PAT 且勾了 Contents: Read and write / Actions: Read；classic PAT 需要 repo 权限"]

        case "status":
            var out: [String: Any] = ["ok": true]
            if let t = GitNative.token {
                out["token"] = GitNative.mask(t)
                let envKeys = ["GITHUB_TOKEN", "GH_TOKEN", "GIT_TOKEN", "GITHUB_PAT"]
                    .filter { k in (EnvVars.current()[k]?.isEmpty == false) }
                out["token_source"] = envKeys.isEmpty ? "keychain" : "env:\(envKeys.joined(separator: ","))"
                out["ready"] = true
                out["hint"] = envKeys.isEmpty
                    ? "已用 Keychain 里的 token，可直接 clone/commit"
                    : "环境变量里已有 token，认证会自动带上；不需要再 login，直接 clone repo:owner/name 或整条仓库地址"
            } else {
                out["token"] = NSNull()
                out["ready"] = false
                out["hint"] = "未配置 token：在 设置→环境变量 加 GITHUB_TOKEN，或 git command:login token:<PAT>"
            }
            let root = try? resolveRoot(params)
            if let root,
               FileManager.default.fileExists(atPath: GitNative.manifestURL(in: root).path),
               let m = try? GitNative.loadManifest(root) {
                let cs = GitNative.diff(root, manifest: m)
                out["repo"] = "\(m.owner)/\(m.repo)"
                out["branch"] = m.branch
                out["local_head"] = String(m.head.prefix(7))
                out["path"] = root.path
                out["changes"] = ["added": cs.added, "modified": cs.modified,
                                  "deleted": cs.deleted, "total": cs.total]
            } else {
                out["repo"] = NSNull()
                out["hint2"] = "当前目录不是 GitNative 仓库"
            }
            return out

        case "whoami":
            let r = GitNative.api("GET", "/user")
            guard r.status == 200, let j = r.json else {
                throw MCPError.failed("GET /user 失败：HTTP \(r.status) \(r.error ?? "")")
            }
            return ["ok": true,
                    "login": j["login"] as? String ?? "?",
                    "name": j["name"] as? String ?? "",
                    "note": "fine-grained token 需对该仓库授权 Contents: Read and write"]

        case "repos":
            // /user/repos 返回的是 JSON 数组，不是对象
            let r = GitNative.api("GET", "/user/repos?per_page=30&sort=updated")
            guard r.status == 200, let data = r.data,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw MCPError.failed("列仓库失败：HTTP \(r.status) \(r.error ?? "")")
            }
            return ["ok": true, "count": list.count,
                    "repos": list.compactMap { $0["full_name"] as? String }]

        case "clone":
            // v7.9.15：直接吃整条仓库地址 —— 用户/模型常发 https://github.com/owner/repo(.git)
            let rawRepo = (params["repo"] as? String)
                ?? (params["url"] as? String)
                ?? (params["repository"] as? String)
                ?? ""
            guard let repo = Self.normalizeRepo(rawRepo) else {
                throw MCPError.invalidParams(
                    "repo required：可传 owner/name，也可直接传 https://github.com/owner/name")
            }
            let parts = repo.split(separator: "/")
            let owner = String(parts[0]), name = String(parts[1])
            let branch = (params["branch"] as? String) ?? "main"
            let root = try resolveRoot(params, defaultName: name)
            return try GitNative.clone(owner: owner, repo: name, branch: branch, into: root,
                                       progress: { _ in })

        case "pull":
            let root = try resolveRoot(params)
            let m = try GitNative.loadManifest(root)
            let headResp = GitNative.api("GET", "/repos/\(m.owner)/\(m.repo)/commits/\(m.branch)")
            let remoteHead = (headResp.json?["sha"] as? String) ?? ""
            if remoteHead == m.head {
                return ["ok": true, "upToDate": true, "head": String(m.head.prefix(7))]
            }
            let cs = GitNative.diff(root, manifest: m)
            if cs.total > 0 {
                throw MCPError.failed("本地有 \(cs.total) 处未提交改动，pull 会覆盖。先 git command:commit，或换目录重新 clone")
            }
            return try GitNative.clone(owner: m.owner, repo: m.repo, branch: m.branch, into: root)

        case "commit":
            guard let msg = params["message"] as? String, !msg.isEmpty else {
                throw MCPError.invalidParams("message required")
            }
            let root = try resolveRoot(params)
            var only: [String]?
            if let f = params["files"] as? String, !f.isEmpty {
                only = f.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            return try GitNative.commit(
                root, message: msg, only: only,
                redAck: params["build_red_ack"] as? String,
                progress: { _ in })

        case "build":
            let root = try resolveRoot(params)
            let m = try GitNative.loadManifest(root)
            guard let run = GitNative.latestRun(
                owner: m.owner, repo: m.repo, branch: m.branch) else {
                return ["ok": true, "run": NSNull(), "message": "这个仓库还没有 workflow 运行记录"]
            }
            return [
                "ok": true,
                "run_id": run.id,
                "status": run.status,
                "conclusion": run.conclusion,
                "head_sha": String(run.headSha.prefix(8)),
                "name": run.name,
                "url": run.htmlURL,
                "red": ["failure", "cancelled", "timed_out"].contains(run.conclusion),
            ]

        case "log":
            let root = try resolveRoot(params)
            let m = try GitNative.loadManifest(root)
            let n = (params["limit"] as? Int) ?? 10
            let r = GitNative.api("GET", "/repos/\(m.owner)/\(m.repo)/commits?sha=\(m.branch)&per_page=\(n)")
            guard r.status == 200, let data = r.data,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw MCPError.failed("读提交历史失败：HTTP \(r.status) \(r.error ?? "")")
            }
            let items: [[String: Any]] = list.map { c in
                let commit = c["commit"] as? [String: Any] ?? [:]
                let author = commit["author"] as? [String: Any] ?? [:]
                return ["sha": String(((c["sha"] as? String) ?? "").prefix(7)),
                        "message": ((commit["message"] as? String) ?? "").split(separator: "\n").first.map(String.init) ?? "",
                        "author": author["name"] as? String ?? "",
                        "date": author["date"] as? String ?? ""]
            }
            return ["ok": true, "repo": "\(m.owner)/\(m.repo)", "count": items.count, "commits": items]

        case "branch":
            let root = try resolveRoot(params)
            let m = try GitNative.loadManifest(root)
            guard let name = params["branch"] as? String, !name.isEmpty else {
                // 列分支
                let r = GitNative.api("GET", "/repos/\(m.owner)/\(m.repo)/branches?per_page=100")
                guard r.status == 200, let data = r.data,
                      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw MCPError.failed("列分支失败：HTTP \(r.status)")
                }
                return ["ok": true, "current": m.branch,
                        "branches": list.compactMap { $0["name"] as? String }]
            }
            let r = GitNative.api("POST", "/repos/\(m.owner)/\(m.repo)/git/refs",
                                  body: ["ref": "refs/heads/\(name)", "sha": m.head])
            if r.status == 201 {
                var nm = m; nm.branch = name
                try GitNative.saveManifest(nm, in: root)
                return ["ok": true, "created": name, "from": String(m.head.prefix(7))]
            }
            throw MCPError.failed("创建分支失败：HTTP \(r.status) \(r.error ?? "")")

        default:
            throw MCPError.invalidParams("未知子命令 \(cmd)。可用：status/login/whoami/clone/pull/commit/log/branch/repos")
        }
    }

    // MARK: 路径解析

    /// v7.9.15：owner/name 或整条 URL → owner/name
    static func normalizeRepo(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        if s.contains("://"), let u = URL(string: s) {
            s = u.path
        } else if s.hasPrefix("git@"), let colon = s.firstIndex(of: ":") {
            s = String(s[s.index(after: colon)...])
        }
        let parts = s.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return parts[parts.count - 2] + "/" + parts[parts.count - 1]
    }

    private func resolveRoot(_ params: [String: Any], defaultName: String? = nil) throws -> URL {
        if let p = params["path"] as? String, !p.isEmpty {
            if p.hasPrefix("/") { return URL(fileURLWithPath: p) }
            return Workspace.root.appendingPathComponent(p)
        }
        if let n = defaultName { return Workspace.root.appendingPathComponent(n) }
        // 没有 path 也没 defaultName：若 workspace 下只有一个 GitNative 仓库就用它
        let fm = FileManager.default
        let base = Workspace.root
        if let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) {
            var found: [URL] = []
            for d in dirs {
                if fm.fileExists(atPath: GitNative.manifestURL(in: d).path) { found.append(d) }
            }
            if found.count == 1 { return found[0] }
            if found.count > 1 {
                throw MCPError.invalidParams("workspace 下有多个仓库：\(found.map { $0.lastPathComponent }.joined(separator: ", "))。请用 path: 指定")
            }
        }
        // v7.9.14：记住上一次操作的仓库（clone/loadManifest 时写入），
        // 这样即使仓库不在 Workspace（例如用户传入绝对路径），后续命令也不用每次带 path。
        if let last = UserDefaults.standard.string(forKey: GitNative.lastRepoKey), !last.isEmpty {
            let url = URL(fileURLWithPath: last)
            if fm.fileExists(atPath: GitNative.manifestURL(in: url).path) { return url }
        }
        throw MCPError.invalidParams(
            "还没有可用的本地仓库。先建一个：git command:clone repo:owner/name "
            + "（已有仓库但不在 Workspace 下时，传 path:"/绝对路径"）")
    }
}
