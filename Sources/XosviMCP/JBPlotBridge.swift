import Foundation
// Process / posix_spawn 在 iOS SDK 里归 Darwin 的 Foundation 扩展，必须显式导入
import Darwin

// MARK: - v7.14.0：jb-p1lot 桥接（rootless 越狱设备直控）
//
// jb-p1lot（https://github.com/castdrian/jb-p1lot，GPL-3.0）是 rootless 越狱设备上的
// MCP 守护进程：设备端 daemon 监听 TCP 5912（TLS 1.3 双向认证）、SpringBoard 侧 HID/截屏 agent，
// 宿主侧 `jb-p1lot` CLI 既提供命令（jb-p1lot <command> --device ... --param k=v），
// 也提供 stdio MCP server（jb-p1lot mcp）。
//
// 原来的用法是"电脑上跑 CLI，AI(Claude/Cursor) 通过 MCP 连它"。
// 在 Xosvi 里我们把这层搬进 App 自己：
//   1) iOS 版可执行按需从上游 GitHub Release（iphoneos-arm64.deb）取出并重签，
//      落 App 沙盒。GPL-3.0 的产物不随本 App 捆绑分发（见 SettingsView 里的说明）。
//   2) 身份/配对状态放 App 沙盒（hosts.json、identity/），首次 setup 时生成。
//   3) 工具层（JBTool）负责子命令分发 → 进程调 CLI → 解析 JSON。
//
// 所以本文件不做协议层复刻（设备侧协议在 jb-p1lot 内部，且随版本演进），
// 只做：二进制管理 / 进程执行 / 结果解析 / 设备发现缓存。

public enum JBPlot {

    // MARK: - 常量

    /// 上游仓库（二进制来源、版本检查）
    static let repo = "castdrian/jb-p1lot"
    /// Relaxin / rootHide 可写越狱路径（App 内拷贝出来备用，方便 ssh / NewTerm 直接跑）
    static let jailbreakPath = "/var/jb/usr/local/bin/jb-p1lot"

    /// 设备桥接端口（与上游一致）
    static let bridgePort = 5912
    /// 单次命令默认超时（秒）
    static let defaultTimeout: TimeInterval = 120

    // MARK: - 位置

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("jb-p1lot", isDirectory: true)
    }

    /// 宿主二进制路径：下载的优先（可升级），其次 App 内捆绑
    static var binaryURL: URL {
        supportDir.appendingPathComponent("bin/jb-p1lot")
    }


    static func ensureDirs() {
        try? FileManager.default.createDirectory(at: supportDir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: supportDir.appendingPathComponent("identity"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: supportDir.appendingPathComponent("artifacts"), withIntermediateDirectories: true)
    }

    // MARK: - 状态（UI 只读）

    /// 安装状态：二进制是否可用（下载或捆绑）
    static var binaryState: String {
        FileManager.default.isExecutableFile(atPath: binaryURL.path) ? "installed" : "missing"
    }

    /// 已配对设备（discovery.json 缓存，避免每次问 daemon）
    static var pairedDevices: [[String: Any]] {
        let p = supportDir.appendingPathComponent("discovery.json")
        guard let d = try? Data(contentsOf: p),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let list = obj["devices"] as? [[String: Any]] else { return [] }
        return list
    }

    /// 默认设备选择器（多设备时必须显式指定，与上游技能约定一致）
    static var defaultDevice: String {
        UserDefaults.standard.string(forKey: "jb.defaultDevice") ?? ""
    }

    // MARK: - 执行

    // v7.14.1：宿主二进制装在 App 容器内。2026-11 实测 App 未沙盒化、纯 C 工具可 exec，
    // 所以这里的失败多半是宿主自身（架构/@rpath/签名）而不是「越狱拦截」。
    // 仍然给替代路径，但不再断言 ENOSYS(85) 是 rootHide 的锅。
    static let spawnBlockedHint = """
    本机执行 jb-p1lot 失败。实测环境是健康的（no-sandbox=true，jq/bsdtar/ldid 可直接 exec），
    所以更可能是宿主二进制自身的架构/@rpath/签名问题，而不是越狱拦截。可选路径：
      1) 设置 → jb-p1lot →「拷贝到越狱路径」，再点「远程 SSH · 本机」用 ssh 方式跑；
      2) 在另一台电脑/手机上跑 jb-p1lot CLI（命令行或 MCP），Xosvi 只负责生成与审阅代码；
      3) 本机能力退回 shell.exec（root 操作需要 rootd 模板里的 root 会话）。
    """

    static func looksLikeSpawnBlocked(_ stderr: String, code: Int32) -> Bool {
        if code == 85 { return true }
        let s = stderr.lowercased()
        return s.contains("enosys") || s.contains("bad executable")
            || s.contains("code signature") || s.contains("operation not permitted")
    }

    public struct RunResult {
        var code: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var json: [String: Any]?

        var isOK: Bool { code == 0 && !timedOut }
        /// 给 AI 看的一行结论
        public var brief: String {
            if timedOut { return "jb-p1lot 超时未返回（长任务请拆分或加 timeout 参数）" }
            if let j = json {
                if let err = j["error"] as? String, !err.isEmpty { return err }
                return "ok"
            }
            let line = (stderr.isEmpty ? stdout : stderr)
                .split(separator: "\n").first.map(String.init) ?? ""
            return line.isEmpty ? "exit \(code)" : line
        }
    }

    /// 定位可用二进制；没有就报错（设置页可一键安装）
    static func resolvedBinary() throws -> String {
        if FileManager.default.isExecutableFile(atPath: binaryURL.path) { return binaryURL.path }
        throw MCPError.failed("jb-p1lot 宿主程序未安装：设置 → jb-p1lot → 安装（从上游 Release 下载，GPL-3.0）。")
    }

    /// 跑一个子命令。`params` 里的值按 --param k=v 传递（数组用逗号，布尔用 true/false）
    static func run(_ command: String,
                    device: String? = nil,
                    params: [String: Any] = [:],
                    project: String? = nil,
                    rawParams: [String: String]? = nil,
                    json: Bool = true,
                    timeout: TimeInterval = defaultTimeout) -> RunResult {
        var args: [String] = [command]
        if json { args.append("--json") }
        let explicit = (device?.isEmpty == false) ? device : nil
        let dev: String?
        if let explicit = explicit { dev = explicit }
        else if defaultDevice.isEmpty { dev = nil }
        else { dev = defaultDevice }
        if let dev = dev { args += ["--device", dev] }
        if let project = project, !project.isEmpty { args += ["--project", project] }
        // v7.14.3：原始值直传通道。上游 parseKeyValues 支持 `--param k v` 双参数形式、
        // 且整数字符串会再 coerce 成 float64——含 '=' 的字符串（base64、命令行片段）走这里，
        // 避免被按第一个 '=' 切断键值。
        let raw = rawParams ?? [:]
        for (k, v) in params.sorted(by: { $0.key < $1.key }) where !raw.keys.contains(k) {
            if let s = paramString(v) { args += ["--param", "\(k)=\(s)"] }
        }
        for (k, v) in raw.sorted(by: { $0.key < $1.key }) {
            args += ["--param", k, v]
        }
        return exec(args, timeout: timeout)
    }

    static func paramString(_ v: Any) -> String? {
        switch v {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double: return d == d.rounded() ? String(Int(d)) : String(d)
        case let n as NSNumber: return n.stringValue
        case let a as [Any]:
            let parts = a.compactMap { paramString($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ",")
        case let d as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) { return s }
            return nil
        default: return nil
        }
    }

    /// 低层执行：posix_spawn 直接启动（不用 shell，避免引号问题）。
    /// v7.14.5：iOS SDK 里 Process 即使 import Foundation/Darwin 也不在可用 API 范围
    /// （CI: cannot find 'Process' in scope），改用仓库已验证的 posix_spawn 路径
    /// （BuildRunner / InjectionManager 同款），输出落临时文件避免管道缓冲死锁。
    static func exec(_ args: [String], timeout: TimeInterval) -> RunResult {
        guard let bin = try? resolvedBinary() else {
            return RunResult(code: -1, stdout: "", stderr: "jb-p1lot binary missing", timedOut: false, json: nil)
        }
        ensureDirs()

        var env = ProcessInfo.processInfo.environment
        // 身份与状态目录全部落在 App 沙盒（JB_P1LOT_HOME 优先，其次 HOME 派生）
        for (k, v) in EnvVars.current() { env[k] = v }
        env["HOME"] = supportDir.path
        env["JB_P1LOT_HOME"] = supportDir.path
        env["TMPDIR"] = NSTemporaryDirectory()

        let outPath = NSTemporaryDirectory() + "jb_out_\(UUID().uuidString).log"
        let errPath = NSTemporaryDirectory() + "jb_err_\(UUID().uuidString).log"

        var argv: [UnsafeMutablePointer<CChar>?] = ([bin] + args).map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }
        var cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        cenv.append(nil)
        defer { for p in cenv where p != nil { free(p) } }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, outPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, errPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, bin, &actions, nil, &argv, &cenv)
        posix_spawn_file_actions_destroy(&actions)

        guard rc == 0 else {
            let errnoText = String(cString: strerror(rc))
            if JBPlot.looksLikeSpawnBlocked(errnoText, code: rc) && rc == 85 {
                return RunResult(code: rc, stdout: "", stderr: spawnBlockedHint, timedOut: false, json: nil)
            }
            return RunResult(code: Int32(rc), stdout: "", stderr: "posix_spawn failed: \(errnoText) (errno \(rc))",
                             timedOut: false, json: nil)
        }

        // 超时守护：到点 SIGTERM，1 秒后再 SIGKILL
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var status: Int32 = 0
        while true {
            let w = waitpid(pid, &status, WNOHANG)
            if w == pid || (w == -1 && errno != EINTR) { break }
            if Date() > deadline {
                timedOut = true
                kill(pid, SIGTERM)
                let killAt = Date().addingTimeInterval(1.0)
                while Date() < killAt {
                    if waitpid(pid, &status, WNOHANG) == pid { break }
                    usleep(50_000)
                }
                if waitpid(pid, &status, WNOHANG) == 0 { kill(pid, SIGKILL) }
                _ = waitpid(pid, &status, 0)
                break
            }
            usleep(30_000)
        }
        let exitCode: Int32 = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : -(status & 0x7f)

        let out = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: outPath)
        try? FileManager.default.removeItem(atPath: errPath)
        let outData = Data(out.utf8)

        var parsed: [String: Any]?
        if let obj = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] {
            parsed = obj
        } else if let start = out.firstIndex(of: "{"), let end = out.lastIndex(of: "}"), start < end,
                  let d = String(out[start...end]).data(using: .utf8) {
            parsed = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        return RunResult(code: exitCode, stdout: out, stderr: err,
                         timedOut: timedOut, json: parsed)
    }

    // MARK: - 安装 / 下载

    /// 安装宿主程序。
    ///
    /// v7.13.3：原来下载 `jb-p1lot-darwin-arm64` 是错的——那个二进制
    /// `platform = macOS`，在 iOS 上 dyld 直接拒绝，重签也没用；而且资产名里没有
    /// `jb-p1lot`，用 `releases/latest/download/jb-p1lot` 只会拿到 404 HTML。
    ///
    /// 正确做法：下 **iphoneos-arm64.deb**，从里面取出 iOS 版 `jb-p1lot`
    /// （实测 `platform = iOS`，fat arm64/arm64e），再落到沙盒并重签。
    static func downloadBinary(version: String? = nil, progress: ((String) -> Void)? = nil) -> (ok: Bool, message: String) {
        ensureDirs()
        progress?("查询上游 Release…")
        // v7.14.15：GitHub API 匿名访问会被限流（实测 HTTP 403 rate limit exceeded），
        // 而 Release 的**下载直链**不受此限制（实测 200 / 1.4MB / 2.5s）。
        // 所以先试 API；失败则走"已知版本 + 直链"探测，实在不行再从 tags 页面抓版本号。
        var asset: (tag: String, name: String)?
        if let a = resolveDebAsset(tag: version) {
            asset = a
        } else {
            progress?("API 不可用（可能被限流），改用直链探测…")
            asset = probeDebAsset()
        }
        guard let asset = asset else {
            return (false, "取不到 jb-p1lot 的 iOS 版 deb（API 被限流且直链探测失败）。\n"
                 + "可临时方案：在自己的电脑上下载 "
                 + "https://github.com/\(repo)/releases/latest/download/ 里的 *iphoneos-arm64.deb，"
                 + "用 SSHTools 传到本机后手动放到 Application Support/jb-p1lot/bin/。")
        }

        // ① 下载 deb（直连 + 镜像前缀）
        var urls = ["https://github.com/\(repo)/releases/download/\(asset.tag)/\(asset.name)"]
        for m in UpdateManager.shared.mirrors { urls.append(m + urls[0]) }
        var debData: Data?
        var lastError = ""
        for urlStr in urls {
            guard let url = URL(string: urlStr) else { continue }
            progress?("下载 \(asset.name)")
            if let d = httpGet(url), d.count > 200_000, d.starts(with: Array("!<arch>\n".utf8)) {
                debData = d
                break
            }
            lastError = "下载失败：\(urlStr)"
        }
        guard let deb = debData else {
            return (false, lastError.isEmpty ? "deb 下载失败" : lastError)
        }

        // ② 解包（复用内置 package 工具，它已经能处理 ar + data.tar.lzma/xz/gz）
        let workRoot = binaryURL.deletingLastPathComponent()
            .appendingPathComponent("jb-unpack-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workRoot) }

        let debPath = workRoot.appendingPathComponent(asset.name)
        do { try deb.write(to: debPath) } catch {
            return (false, "写入 deb 失败：\(error.localizedDescription)")
        }
        progress?("解包 deb…")
        // v7.14.17：不再借道 package 工具（`try?` 会吞掉解包错误，只留下"没找到可执行"），
        // 这里直接解析 ar 成员，把 data.tar.* 交给 package 的同一套解压实现，
        // 并把每个成员的错误原样带出来。
        var unpackErrors: [String] = []
        do {
            let members = try arMembers(deb)
            guard !members.isEmpty else { throw MCPError.failed("deb 不是合法的 ar 归档") }
            for m in members where m.name.hasPrefix("data.tar") {
                _ = try unpackTarMember(m.data, into: workRoot, label: m.name)
            }
            if !members.contains(where: { $0.name.hasPrefix("data.tar") }) {
                unpackErrors.append("deb 里没有 data.tar.* 成员（内容: \(members.map { $0.name }.joined(separator: ", "))）")
            }
        } catch {
            unpackErrors.append("\(error)")
        }

        // ③ 找 CLI 可执行（优先 Applications 里的 jb-p1lot，其次 libexec 的 daemon）
        let candidates = [
            workRoot.appendingPathComponent("var/jb/Applications/jb-p1lot.app/jb-p1lot").path,
            workRoot.appendingPathComponent("var/jb/usr/bin/jb-p1lot").path,
            workRoot.appendingPathComponent("var/jb/usr/libexec/jb-p1lot-daemon").path,
        ]
        guard let src = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            // 把工作区里实际解出的内容列出来，别再只给一句"没找到"
            let found = (try? FileManager.default.contentsOfDirectory(atPath: workRoot.path))?.joined(separator: ", ") ?? "（空）"
            return (false, "deb 里没找到 jb-p1lot 可执行。解出的顶层: \(found)"
                 + (unpackErrors.isEmpty ? "" : "；解包错误: \(unpackErrors.joined(separator: " | "))"))
        }
        guard let data = FileManager.default.contents(atPath: src) else {
            return (false, "读取解出的二进制失败")
        }
        // 拒绝 macOS 二进制（就摆在平台里，省得以后又装错）
        if !isIOSMachO(data) {
            return (false, "解出的二进制不是 iOS Mach-O（platform ≠ iOS），拒绝安装")
        }

        // ④ 落到沙盒 + 重签 + 自检
        let dest = binaryURL
        do {
            try? FileManager.default.removeItem(at: dest)
            try data.write(to: dest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        } catch {
            return (false, "写入失败：\(error.localizedDescription)")
        }
        let signed = signBinary(dest.path)
        let probe = exec(["--version"], timeout: 15)
        if probe.isOK {
            let v = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return (true, "已安装 iOS 版 jb-p1lot（\(data.count / 1024) KB）\(v.isEmpty ? "" : "v\(v)")\(signed ? "" : "（未签名，可能被系统拒绝执行）")")
        }
        return (false, "已解出但执行失败：\(probe.stderr.prefix(200))")
    }

    /// 查上游最新（或指定 tag）Release 里的 iphoneos-arm64.deb
    /// 不依赖 GitHub API 的资产探测：
    ///   ① 逐个试已知版本号（vX.Y.Z）+ 该版本的标准资产名；
    ///   ② 版本号从 Release 页面 HTML 里抓（不受 API 限流）；
    ///   ③ 都失败返回 nil，由调用方给出可操作的兜底说明。
    /// 资产名规则（上游稳定）：dev.adrian.jb-p1lot_<ver>_iphoneos-arm64.deb
    private static func probeDebAsset() -> (tag: String, name: String)? {
        func assetName(_ ver: String) -> String {
            "dev.adrian.jb-p1lot_\(ver)_iphoneos-arm64.deb"
        }
        func urlFor(_ ver: String) -> String {
            "https://github.com/\(repo)/releases/download/v\(ver)/\(assetName(ver))"
        }
        func headOK(_ ver: String) -> Bool {
            guard let u = URL(string: urlFor(ver)) else { return false }
            var req = URLRequest(url: u)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 12
            let sem = DispatchSemaphore(value: 0)
            var code = 0
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 15)
            return code == 200
        }

        // ① 已知版本（新版本发布后这里可追加；不命中就走 ②）
        for v in ["0.1.6", "0.1.5", "0.1.4"] where headOK(v) {
            return ("v\(v)", assetName(v))
        }

        // ② 从 API 的镜像前缀重试（镜像通常不转发限流状态，但可能直接透传正文）
        //    再兜底：从 releases 页面 HTML 抓 /releases/tag/vX.Y.Z
        var pageURLs = ["https://github.com/\(repo)/releases"]
        for m in UpdateManager.shared.mirrors { pageURLs.append(m + pageURLs[0]) }
        for pu in pageURLs {
            guard let u = URL(string: pu), let d = httpGet(u),
                  let html = String(data: d, encoding: .utf8) else { continue }
            let pattern = "/releases/tag/v([0-9]+\\.[0-9]+\\.[0-9]+)"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = html as NSString
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let ver = ns.substring(with: m.range(at: 1))
                if headOK(ver) { return ("v\(ver)", assetName(ver)) }
            }
        }
        return nil
    }

    private static func resolveDebAsset(tag: String?) -> (tag: String, name: String)? {
        let api = tag == nil || tag == "latest"
            ? "https://api.github.com/repos/\(repo)/releases/latest"
            : "https://api.github.com/repos/\(repo)/releases/tags/\(tag!)"
        guard let url = URL(string: api), let data = httpGet(url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        // 优先 iphoneos-arm64.deb；名字里带版本号，不能硬编码
        for a in assets {
            guard let n = a["name"] as? String else { continue }
            if n.hasSuffix(".deb") && n.contains("iphoneos-arm64") {
                return (tagName, n)
            }
        }
        return nil
    }

    /// 解析 ar 归档成员（deb：debian-binary / control.tar.* / data.tar.*）
    private static func arMembers(_ data: Data) throws -> [(name: String, data: Data)] {
        guard data.count > 8, data.prefix(8).elementsEqual(Array("!<arch>\n".utf8)) else {
            throw MCPError.failed("不是 ar 归档")
        }
        var out: [(String, Data)] = []
        var off = 8
        while off + 60 <= data.count {
            let hdr = data.subdata(in: off..<(off + 60))
            let rawName = String(data: hdr.subdata(in: 0..<16), encoding: .utf8) ?? ""
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let sizeStr = String(data: hdr.subdata(in: 48..<58), encoding: .utf8) ?? ""
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces)),
                  size >= 0, size <= data.count - off - 60 else { break }
            let body = data.subdata(in: (off + 60)..<(off + 60 + size))
            if !name.isEmpty, name != "/", name != "//" { out.append((name, body)) }
            off += 60 + size + (size & 1)
        }
        return out
    }

    /// 把 data.tar.* 解到 dest。复用 PackageTool.extractTar——
    /// 那条路径已处理 gz / lzma-alone / xz / bz2 / 裸 tar 的判定与落盘。
    private static func unpackTarMember(_ raw: Data, into dest: URL, label: String) throws -> Int {
        do {
            return try PackageTool().extractTar(raw, into: dest, label: label)
        } catch {
            throw MCPError.failed("\(label) 解包失败: \(error)")
        }
    }

    /// 判断是否为 iOS 平台的 Mach-O（fat 或 thin 都看一遍）
    private static func isIOSMachO(_ data: Data) -> Bool {
        func platform(of slice: Data) -> UInt32? {
            guard slice.count > 32 else { return nil }
            let magic = slice.withUnsafeBytes { $0.load(as: UInt32.self) }
            guard magic == 0xfeedfacf else { return nil }
            let ncmds: UInt32 = slice.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
            var off = 32
            var i: UInt32 = 0
            while i < ncmds, off + 8 <= slice.count {
                let cmd: UInt32 = slice.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }
                let size: UInt32 = slice.withUnsafeBytes { $0.load(fromByteOffset: off + 4, as: UInt32.self) }
                if cmd == 0x32, off + 24 <= slice.count {   // LC_BUILD_VERSION
                    return slice.withUnsafeBytes { $0.load(fromByteOffset: off + 8, as: UInt32.self) }
                }
                if size == 0 { break }
                off += Int(size)
                i += 1
            }
            return nil
        }

        let magicBE = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        if magicBE == 0xcafebabe {                 // fat：任一 slice 是 iOS 就算
            let n: UInt32 = data.withUnsafeBytes { UInt32(bigEndian: $0.load(fromByteOffset: 4, as: UInt32.self)) }
            var i = 0
            while i < Int(n) {
                let base = 8 + i * 20
                guard base + 20 <= data.count else { break }
                let off: UInt32 = data.withUnsafeBytes { UInt32(bigEndian: $0.load(fromByteOffset: base + 8, as: UInt32.self)) }
                let size: UInt32 = data.withUnsafeBytes { UInt32(bigEndian: $0.load(fromByteOffset: base + 12, as: UInt32.self)) }
                if Int(off) + Int(size) <= data.count {
                    let slice = data.subdata(in: Int(off)..<(Int(off) + Int(size)))
                    if platform(of: slice) == 2 { return true }
                }
                i += 1
            }
            return false
        }
        return platform(of: data) == 2
    }

    /// Relaxin 适配：把沙盒里的宿主二进制复制到越狱可写区（App 内越狱视图可能只读，
    /// 失败时如实返回原因，让用户改用 ssh / NewTerm 手动放）。
    static func copyToJailbreakPath() -> (ok: Bool, message: String) {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            return (false, "先安装宿主程序")
        }
        let dest = URL(fileURLWithPath: jailbreakPath)
        // ① root spawn /bin/cp（Relaxin 下越狱路径只有 root 能写）
        let mgr = InjectionManager.shared
        _ = mgr.spawnRoot("/bin/mkdir", args: ["-p", dest.deletingLastPathComponent().path], timeout: 15)
        if mgr.spawnRoot("/bin/cp", args: ["-f", binaryURL.path, dest.path], timeout: 60).0 == 0 {
            _ = mgr.spawnRoot("/bin/chmod", args: ["755", dest.path], timeout: 10)
            return (true, jailbreakPath)
        }
        // ② App 自身有权限时直接拷
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: binaryURL, to: dest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            return (true, jailbreakPath)
        } catch {
            return (false, "拷贝失败（越狱视图只读？）：\(error.localizedDescription)")
        }
    }

    private static func httpGet(_ url: URL) -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.setValue("Xosvi/jb-p1lot", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { result = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 90)
        return result
    }

    /// ad-hoc 重签：优先 App 自带 ldid，其次系统 codesign。Relaxin 下统一走
    /// InjectionManager（先试普通 spawn，失败再转 root spawn）。
    @discardableResult
    static func signBinary(_ path: String) -> Bool {
        let mgr = InjectionManager.shared
        let ldidCandidates = [
            Bundle.main.bundleURL.appendingPathComponent("bin/ldid").path,
            Bundle.main.bundleURL.appendingPathComponent("Resources/bin/ldid").path,
        ]
        if let ldid = ldidCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            if mgr.spawnRoot(ldid, args: ["-S", path], timeout: 60).0 == 0 { return true }
        }
        return mgr.spawnRoot("/usr/bin/codesign", args: ["-f", "-s", "-", path], timeout: 60).0 == 0
    }


    // MARK: - 命令目录（tools/list 等价物）

    /// 与上游 registry 一致的 32 个子命令 + 说明 + 关键参数（AI 用它决定调哪个子命令）
    struct CommandSpec {
        let name: String
        let summary: String
        let params: [String]       // 关键参数（完整 schema 见上游 schemas/commands.json）
        let destructive: Bool
    }

    static let catalog: [CommandSpec] = [
        .init(name: "device_list", summary: "发现已配对设备与桥接地址", params: [], destructive: false),
        .init(name: "device_status", summary: "读桥接/越狱/传输/后端状态", params: [], destructive: false),
        .init(name: "device_action", summary: "生命周期或显示动作（reboot 始终是 Dopamine 用户态重启）", params: ["action", "reason"], destructive: true),
        .init(name: "shell_exec", summary: "在设备上执行 root shell 命令", params: ["command", "cwd", "timeoutMs"], destructive: true),
        .init(name: "file_list", summary: "列设备目录", params: ["path", "recursive"], destructive: false),
        .init(name: "file_read", summary: "读设备文件（有长度上限）", params: ["path", "maxBytes"], destructive: false),
        .init(name: "file_write", summary: "原子写设备文件", params: ["path", "data", "encoding", "mode"], destructive: true),
        .init(name: "file_transfer", summary: "宿主↔设备传输文件", params: ["source", "destination", "direction"], destructive: true),
        .init(name: "file_search", summary: "按模式搜设备路径（结果有上限）", params: ["root", "pattern", "maxResults"], destructive: false),
        .init(name: "screen_capture", summary: "截屏为 PNG", params: ["display"], destructive: false),
        .init(name: "screen_stream", summary: "可重连 H.264 屏幕流", params: ["record", "durationMs", "fps"], destructive: false),
        .init(name: "ui_snapshot", summary: "读帧级无障碍树（node id 只在当帧有效）", params: ["application"], destructive: false),
        .init(name: "ui_action", summary: "语义/坐标/HID/键盘/按钮/显示/系统手势输入", params: ["action", "frameId", "nodeId", "selector", "x", "y", "text", "button"], destructive: true),
        .init(name: "ui_wait", summary: "等待无障碍或视觉条件", params: ["selector", "timeoutMs", "pollMs"], destructive: false),
        .init(name: "app_manage", summary: "查看/启动/安装/卸载 App", params: ["action", "bundleId", "path"], destructive: true),
        .init(name: "process_manage", summary: "查看/发信号/spawn/结束进程", params: ["action", "pid", "command", "signal"], destructive: true),
        .init(name: "package_manage", summary: "查看/安装/移除/回滚 deb 包", params: ["action", "package", "path", "version"], destructive: true),
        .init(name: "port_forward", summary: "创建/停止 USBMux 或 WiFi 端口转发", params: ["action", "localPort", "remotePort", "protocol"], destructive: true),
        .init(name: "log_query", summary: "有界统一日志流（predicate/process/since）", params: ["predicate", "process", "since", "limit", "follow"], destructive: false),
        .init(name: "crash_manage", summary: "列出/取回/符号化/清理崩溃报告", params: ["action", "process", "path"], destructive: true),
        .init(name: "diagnostics_collect", summary: "收集 sysdiagnose 与桥接诊断", params: ["kind", "durationMs"], destructive: false),
        .init(name: "metrics_stream", summary: "读 CPU/内存/图形/能耗/网络指标", params: ["durationMs", "intervalMs", "process"], destructive: false),
        .init(name: "network_capture", summary: "BPF 过滤的有界 PCAP 抓包", params: ["interface", "filter", "durationMs", "snaplen"], destructive: false),
        .init(name: "debug_session", summary: "启动/控制 LLDB（debugserver）会话", params: ["action", "sessionId", "pid", "bundleId", "command"], destructive: true),
        .init(name: "frida_session", summary: "启动/控制 Frida 会话", params: ["action", "sessionId", "pid", "bundleId", "script"], destructive: true),
        .init(name: "tweak_build", summary: "构建 Theos tweak 并返回最新包产物", params: ["project", "configuration", "clean"], destructive: false),
        .init(name: "tweak_deploy", summary: "安装 rootless tweak 包并校验心跳", params: ["package", "reload", "processes"], destructive: true),
        .init(name: "tweak_cycle", summary: "构建→安装→重载→日志→校验→崩溃回滚 一条龙", params: ["project", "reload", "processes", "rollbackOnCrash", "clean"], destructive: true),
        .init(name: "session_list", summary: "列长驻会话", params: [], destructive: false),
        .init(name: "session_read", summary: "读长驻会话缓冲输出", params: ["sessionId", "maxBytes", "waitMs"], destructive: false),
        .init(name: "session_write", summary: "向长驻会话写输入", params: ["sessionId", "data"], destructive: true),
        .init(name: "session_stop", summary: "停止长驻会话", params: ["sessionId"], destructive: true),
    ]

    /// 供系统提示词 / 技能用的紧凑命令目录
    static func catalogText() -> String {
        catalog.map { c in
            "- \(c.name): \(c.summary)" + (c.params.isEmpty ? "" : " | params: " + c.params.joined(separator: ","))
        }.joined(separator: "\n")
    }

    static func spec(_ name: String) -> CommandSpec? {
        catalog.first { $0.name == name }
    }
}
