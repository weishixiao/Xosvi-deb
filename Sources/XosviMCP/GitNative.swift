import Foundation
import CryptoKit
import ZIPFoundation

// MARK: - v7.16.0：原生 Git（无子进程 / 无 iSH / 不受 jailbreak 拦截）
//
// 为什么必须自己写：
//   1. 越狱（rootHide/Relaxin）对 posix_spawn 直接返回 ENOSYS 85 → 真 git 起不来；
//   2. 内置 python3 同样被拦 → scripts/git.py（dulwich）也跑不了；
//   3. 内置 curl 是极简实现，**忽略 -H**，无法带 Authorization；
//   4. web.fetch 走 Jina Reader，会剥掉 Authorization 与 URL userinfo。
//   → 结论：任何"靠外部程序或代理转发"的路都不通，只能在本进程内用 URLSession
//     （可完全控制请求头）+ GitHub REST API 完成读写。
//
// 能力模型（不模拟 .git 目录，避免实现完整 git 协议）：
//   clone  = 下载 zipball 解到工作区 + 记录 manifest（path → sha256）
//   commit = manifest 与当前文件比对出变更 → Git Data API（blob→tree→commit→ref）
//   pull   = 比对远端 head，不一致就重新 clone
//   manifest 存在仓库根的 .gitremote/manifest.json（不入提交）

enum GitNative {

    // MARK: 配置

    static let manifestDirName = ".gitremote"
    static let manifestFileName = "manifest.json"

    /// token 来源优先级：环境变量 → Keychain。绝不回显明文。
    static var token: String? {
        let env = EnvVars.current()
        for key in ["GITHUB_TOKEN", "GH_TOKEN", "GIT_TOKEN", "GITHUB_PAT"] {
            if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
        }
        if let v = KeychainStore.shared.string(forKey: "git.github.token"),
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v
        }
        return nil
    }

    static func saveToken(_ raw: String) -> Bool {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.count > 10 else { return false }
        return KeychainStore.shared.set(v, forKey: "git.github.token")
    }

    static func mask(_ t: String) -> String {
        guard t.count > 12 else { return "••••" }
        return String(t.prefix(7)) + "…" + String(t.suffix(4))
    }

    // MARK: 清单

    struct Manifest: Codable {
        var owner: String
        var repo: String
        var branch: String
        var head: String            // 最近一次同步的 commit sha
        var files: [String: String] // path → sha256
        var updatedAt: Date
    }

    struct RepoRef {
        var root: URL
        var manifest: Manifest
    }

    static func manifestURL(in root: URL) -> URL {
        root.appendingPathComponent(manifestDirName).appendingPathComponent(manifestFileName)
    }

    static func loadManifest(_ root: URL) throws -> Manifest {
        let url = manifestURL(in: root)
        guard let data = try? Data(contentsOf: url) else {
            throw MCPError.failed("这里不是 GitNative 仓库（缺少 \(manifestDirName)/\(manifestFileName)）。先 git command:clone repo:owner/name")
        }
        // v7.16.1：编码用 iso8601、解码却用默认策略会直接抛错——必须成对
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(Manifest.self, from: data)
    }

    static func saveManifest(_ m: Manifest, in root: URL) throws {
        let dir = root.appendingPathComponent(manifestDirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(m).write(to: manifestURL(in: root))
    }

    /// 把相对路径解析到仓库根内，防目录穿越
    static func resolve(_ root: URL, _ rel: String) -> URL? {
        let t = root.appendingPathComponent(rel).standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return (t == base || t.hasPrefix(base + "/")) ? URL(fileURLWithPath: t) : nil
    }

    // MARK: HTTP

    struct APIResponse {
        var status: Int
        var json: [String: Any]?
        var data: Data?
        var error: String?
    }

    /// 同步请求（内部信号量）。method/headers/body 完全自控——这是内置 curl 做不到的部分。
    static func api(_ method: String,
                    _ path: String,
                    body: [String: Any]? = nil,
                    accept: String = "application/vnd.github+json",
                    timeout: TimeInterval = 60,
                    retryOn5xx: Bool = true) -> APIResponse {
        guard let tk = token else {
            return APIResponse(status: 0, json: nil, data: nil,
                               error: "未配置 GitHub token。用 git command:login token:<PAT> 保存（只需一次），或设置环境变量 GITHUB_TOKEN。")
        }
        let urlStr = path.hasPrefix("http") ? path : "https://api.github.com" + path
        guard let url = URL(string: urlStr) else {
            return APIResponse(status: 0, json: nil, data: nil, error: "URL 非法: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Bearer \(tk)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("Xosvi-NativeGit", forHTTPHeaderField: "User-Agent")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return perform(req, retryOn5xx: retryOn5xx)
    }

    private static func perform(_ req: URLRequest, retryOn5xx: Bool) -> APIResponse {
        var attempt = 0
        while true {
            attempt += 1
            let sem = DispatchSemaphore(value: 0)
            var resp: APIResponse?
            URLSession.shared.dataTask(with: req) { data, response, error in
                defer { sem.signal() }
                if let error = error {
                    resp = APIResponse(status: 0, json: nil, data: nil, error: error.localizedDescription)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                var json: [String: Any]?
                if let data = data, let obj = try? JSONSerialization.jsonObject(with: data) {
                    json = obj as? [String: Any]
                }
                var msg: String?
                if code >= 400 {
                    msg = (json?["message"] as? String) ?? "HTTP \(code)"
                    if let errs = json?["errors"] as? [[String: Any]], !errs.isEmpty {
                        msg? += " | " + errs.compactMap { $0["message"] as? String ?? $0["code"] as? String }.joined(separator: "; ")
                    }
                }
                resp = APIResponse(status: code, json: json, data: data, error: msg)
            }.resume()
            _ = sem.wait(timeout: .now() + req.timeoutInterval + 15)
            guard let r = resp else {
                return APIResponse(status: 0, json: nil, data: nil, error: "请求超时")
            }
            // 5xx / 429 重试一次（GitHub 偶发 502）
            if retryOn5xx, attempt < 3, r.status >= 500 || r.status == 429 {
                Thread.sleep(forTimeInterval: Double(attempt) * 1.5)
                continue
            }
            return r
        }
    }
}

// MARK: - 文件扫描 / 忽略规则

extension GitNative {

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 简易 .gitignore 匹配：支持 `dir/`、`*.ext`、`/root`、`name`、`a/b`。
    /// 不做完整 gitignore 语义（否定 !、** 通配），但覆盖 99% 的仓库。
    struct IgnoreRules {
        var patterns: [String] = []

        static func load(root: URL) -> IgnoreRules {
            var r = IgnoreRules()
            // 内置：这些永远不该进仓库
            r.patterns = ["/.gitremote/", "/.git/", "/.build/", "/build/", "/node_modules/",
                          ".DS_Store", "*.ipa", "*.tipa", "*.dSYM/"]
            guard let text = try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8) else {
                return r
            }
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") { continue }
                r.patterns.append(line)
            }
            return r
        }

        func matches(_ rel: String) -> Bool {
            let isDir = rel.hasSuffix("/")
            let path = "/" + (isDir ? String(rel.dropLast()) : rel)
            let name = (rel as NSString).lastPathComponent

            for p0 in patterns {
                var p = p0
                let dirOnly = p.hasSuffix("/")
                if dirOnly { p = String(p.dropLast()) }
                if dirOnly && !isDir && !path.contains("/" + p + "/") { continue }

                if p.hasPrefix("/") {
                    // 锚定仓库根
                    if path == p || path.hasPrefix(p + "/") { return true }
                } else if p.contains("*") {
                    let regex = "^" + NSRegularExpression.escapedPattern(for: p)
                        .replacingOccurrences(of: "\\*", with: ".*") + "$"
                    if let re = try? NSRegularExpression(pattern: regex) {
                        let ns = name as NSString
                        if re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) != nil { return true }
                        let full = String(path.dropFirst()) as NSString
                        if re.firstMatch(in: full as String, range: NSRange(location: 0, length: full.length)) != nil { return true }
                    }
                } else {
                    if name == p { return true }
                    if path == "/" + p || path.hasPrefix("/" + p + "/") { return true }
                    if path.contains("/" + p + "/") { return true }
                }
            }
            return false
        }
    }

    /// 扫描工作区，返回 rel → (absPath, size)
    static func scan(root: URL, ignoring rules: IgnoreRules) -> [String: (URL, Int)] {
        var out: [String: (URL, Int)] = [:]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles], errorHandler: nil) else { return out }
        let basePath = root.standardizedFileURL.path
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let abs = url.standardizedFileURL.path
            guard abs.hasPrefix(basePath + "/") else { continue }
            var rel = String(abs.dropFirst(basePath.count + 1))
            if isDir { rel += "/" }
            if rules.matches(rel) {
                if isDir { walker.skipDescendants() }
                continue
            }
            if isDir { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            out[rel] = (url, size)
        }
        return out
    }
}

// MARK: - 操作：clone / status / commit / log / pull

extension GitNative {

    struct ChangeSet {
        var added: [String] = []
        var modified: [String] = []
        var deleted: [String] = []
        var total: Int { added.count + modified.count + deleted.count }
    }

    /// 比对 manifest 与当前工作区
    static func diff(_ root: URL, manifest: Manifest) -> ChangeSet {
        let rules = IgnoreRules.load(root: root)
        let files = scan(root: root, ignoring: rules)
        var cs = ChangeSet()
        for (rel, info) in files {
            guard info.1 <= 45 * 1024 * 1024 else { continue }   // 超过 45MB 跳过，避免一次性吃爆内存
            let data = (try? Data(contentsOf: info.0, options: .mappedIfSafe)) ?? Data()
            let h = sha256Hex(data)
            if let old = manifest.files[rel] {
                if old != h { cs.modified.append(rel) }
            } else {
                cs.added.append(rel)
            }
        }
        for rel in manifest.files.keys where files[rel] == nil {
            cs.deleted.append(rel)
        }
        cs.added.sort(); cs.modified.sort(); cs.deleted.sort()
        return cs
    }

    // MARK: clone

    static func clone(owner: String, repo: String, branch: String, into root: URL,
                      progress: ((String) -> Void)? = nil) throws -> [String: Any] {
        progress?("下载 \(owner)/\(repo)@\(branch) …")
        // codeload 直链：不经过 api.github.com 的 302，Authorization 不会被丢弃
        let zipURL = "https://codeload.github.com/\(owner)/\(repo)/zip/refs/heads/\(branch)"
        guard let tk = token else {
            throw MCPError.failed("未配置 GitHub token：git command:login token:<PAT>")
        }
        var req = URLRequest(url: URL(string: zipURL)!)
        req.timeoutInterval = 180
        req.setValue("Bearer \(tk)", forHTTPHeaderField: "Authorization")
        req.setValue("Xosvi-NativeGit", forHTTPHeaderField: "User-Agent")
        let r = perform(req, retryOn5xx: false)
        guard r.status == 200, let zipData = r.data, zipData.count > 0 else {
            throw MCPError.failed("下载失败：HTTP \(r.status) \(r.error ?? "")")
        }
        progress?("解包 \(zipData.count / 1024) KB …")

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let tmpZip = fm.temporaryDirectory.appendingPathComponent("gitnative-\(UUID().uuidString).zip")
        try zipData.write(to: tmpZip)
        defer { try? fm.removeItem(at: tmpZip) }

        guard let archive = Archive(url: tmpZip, accessMode: .read) else {
            throw MCPError.failed("zip 打不开（下载内容可能不是 zip）")
        }
        var written = 0
        let entries = Array(archive)   // 先快照，ZIPFoundation 迭代器不能边迭代边解
        for entry in entries {
            // GitHub zipball 顶层是 <owner>-<repo>-<sha>/，剥掉
            let comps = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            guard comps.count > 1 else { continue }
            let rel = comps.dropFirst().joined(separator: "/")
            guard !rel.isEmpty, let dest = resolve(root, rel) else { continue }
            if entry.type == .directory {
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try? archive.extract(entry, to: dest)
            written += 1
        }

        // 取远端 head
        progress?("读取远端 HEAD …")
        let headResp = api("GET", "/repos/\(owner)/\(repo)/commits/\(branch)")
        let headSha = (headResp.json?["sha"] as? String) ?? ""

        let rules = IgnoreRules.load(root: root)
        let files = scan(root: root, ignoring: rules)
        var map: [String: String] = [:]
        for (rel, info) in files {
            guard info.1 <= 45 * 1024 * 1024 else { continue }
            let data = (try? Data(contentsOf: info.0, options: .mappedIfSafe)) ?? Data()
            map[rel] = sha256Hex(data)
        }
        let m = Manifest(owner: owner, repo: repo, branch: branch,
                         head: headSha, files: map, updatedAt: Date())
        try saveManifest(m, in: root)

        return ["ok": true, "path": root.path, "files": written,
                "head": String(headSha.prefix(7)), "branch": branch,
                "remote": "\(owner)/\(repo)"]
    }

    // MARK: commit（Git Data API：blob → tree → commit → ref）

    static func commit(_ root: URL, message: String,
                       only paths: [String]? = nil,
                       progress: ((String) -> Void)? = nil) throws -> [String: Any] {
        var manifest = try loadManifest(root)
        let rules = IgnoreRules.load(root: root)
        let files = scan(root: root, ignoring: rules)
        var cs = diff(root, manifest: manifest)

        if let only = paths, !only.isEmpty {
            let set = Set(only)
            cs.added = cs.added.filter { set.contains($0) }
            cs.modified = cs.modified.filter { set.contains($0) }
            cs.deleted = cs.deleted.filter { set.contains($0) }
        }
        guard cs.total > 0 else {
            return ["ok": true, "changed": 0, "message": "工作区与上次同步一致，没有需要提交的改动"]
        }

        let o = manifest.owner, rep = manifest.repo, br = manifest.branch

        // ① blobs
        var treeItems: [[String: Any]] = []
        var newHashes: [String: String] = [:]
        let touched = cs.added + cs.modified
        for (i, rel) in touched.enumerated() {
            guard let info = files[rel] else { continue }
            progress?("上传 \(i + 1)/\(touched.count)：\(rel)")
            let data = try Data(contentsOf: info.0, options: .mappedIfSafe)
            let res = api("POST", "/repos/\(o)/\(rep)/git/blobs",
                          body: ["content": data.base64EncodedString(), "encoding": "base64"])
            guard res.status == 201 || res.status == 200,
                  let sha = res.json?["sha"] as? String else {
                throw MCPError.failed("上传 \(rel) 失败：HTTP \(res.status) \(res.error ?? "")")
            }
            treeItems.append(["path": rel, "mode": "100644", "type": "blob", "sha": sha])
            newHashes[rel] = sha256Hex(data)
        }
        for rel in cs.deleted {
            // sha: nil（JSON null）表示删除
            treeItems.append(["path": rel, "mode": "100644", "type": "blob", "sha": NSNull()])
        }

        // ② base tree
        progress?("读取 base tree …")
        var baseTree: String?
        if !manifest.head.isEmpty {
            let c = api("GET", "/repos/\(o)/\(rep)/git/commits/\(manifest.head)")
            baseTree = (c.json?["tree"] as? [String: Any])?["sha"] as? String
        }
        var treeBody: [String: Any] = ["tree": treeItems]
        if let b = baseTree { treeBody["base_tree"] = b }
        let treeRes = api("POST", "/repos/\(o)/\(rep)/git/trees", body: treeBody)
        guard let treeSha = treeRes.json?["sha"] as? String else {
            throw MCPError.failed("创建 tree 失败：HTTP \(treeRes.status) \(treeRes.error ?? "")")
        }

        // ③ commit
        progress?("创建 commit …")
        var commitBody: [String: Any] = ["message": message, "tree": treeSha]
        if !manifest.head.isEmpty { commitBody["parents"] = [manifest.head] }
        let commitRes = api("POST", "/repos/\(o)/\(rep)/git/commits", body: commitBody)
        guard let newCommit = commitRes.json?["sha"] as? String else {
            throw MCPError.failed("创建 commit 失败：HTTP \(commitRes.status) \(commitRes.error ?? "")")
        }

        // ④ 更新 ref
        progress?("更新 \(br) …")
        let refRes = api("PATCH", "/repos/\(o)/\(rep)/git/refs/heads/\(br)",
                         body: ["sha": newCommit, "force": false])
        if refRes.status != 200 {
            throw MCPError.failed("更新分支失败：HTTP \(refRes.status) \(refRes.error ?? "")（可能远端有新提交，先 git command:pull）")
        }

        // ⑤ 更新 manifest
        for rel in touched { if let h = newHashes[rel] { manifest.files[rel] = h } }
        for rel in cs.deleted { manifest.files.removeValue(forKey: rel) }
        manifest.head = newCommit
        manifest.updatedAt = Date()
        try saveManifest(manifest, in: root)

        return ["ok": true,
                "commit": String(newCommit.prefix(7)),
                "added": cs.added, "modified": cs.modified, "deleted": cs.deleted,
                "changed": cs.total,
                "url": "https://github.com/\(o)/\(rep)/commit/\(newCommit)"]
    }
}
