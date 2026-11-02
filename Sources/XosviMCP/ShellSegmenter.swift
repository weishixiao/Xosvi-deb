import Foundation
import Darwin

// MARK: - v8（P1-5）：原生 shell 分段器
//
// 解决两类误杀：
//   1) 整串判定——一条命令里只要有一段不认识，整条就废（`id -u`、`B=/tmp id -u`、
//      `for t in …; do … done` 全被报「需要 Alpine 运行时」）；
//   2) 路径前缀不归一——`/var/...` 与 `/private/var/...` 在 iOS 上是同一个（/var 是软链），
//      但旧分类器把前者当不存在。
//
// 策略：按 ; | && || 换行 切段 → 每段剥掉 VAR=value 前缀 → 只按首 token 分类 →
// 能跑的就跑，跑不了的段单独报错，其余段继续。

enum ShellSegmenter {

    enum Kind {
        case builtin(String)
        case bundled(String)      // 可执行文件绝对路径
        case unsupported(String)  // 首 token
    }

    struct Segment {
        let raw: String
        let head: String
        let kind: Kind
    }

    // MARK: 切分

    /// 按 ; | && || 换行 切分，识别单双引号（引号内的分隔符不切）
    static func split(_ command: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var i = command.startIndex
        func flush() {
            let t = cur.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(t) }
            cur = ""
        }
        while i < command.endIndex {
            let c = command[i]
            if let q = quote {
                cur.append(c)
                if c == q { quote = nil }
                i = command.index(after: i)
                continue
            }
            switch c {
            case "'", "\"":
                quote = c; cur.append(c); i = command.index(after: i)
            case ";", "\n":
                flush(); i = command.index(after: i)
            case "&":
                let n = command.index(after: i)
                if n < command.endIndex && command[n] == "&" {
                    flush(); i = command.index(after: n)
                } else { cur.append(c); i = n }
            case "|":
                let n = command.index(after: i)
                if n < command.endIndex && command[n] == "|" {
                    flush(); i = command.index(after: n)
                } else {
                    flush(); i = n
                }
            default:
                cur.append(c); i = command.index(after: i)
            }
        }
        flush()
        return out
    }

    /// 剥掉 VAR=value 前缀（可多个）
    static func stripAssignments(_ seg: String) -> String {
        var s = seg
        while let r = s.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=\S*\s+"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s
    }

    // MARK: 路径归一

    static func normalizePath(_ p: String) -> String {
        if p.hasPrefix("/var/") { return "/private" + p }
        if p == "/var" { return "/private/var" }
        return p
    }

    static func normalizePaths(in seg: String) -> String {
        var s = seg
        for (from, to) in [("/var/mobile/", "/private/var/mobile/"),
                           ("/var/containers/", "/private/var/containers/"),
                           ("/var/jb/", "/private/var/jb/")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }

    // MARK: 分类

    static let builtins: Set<String> = ["id", "whoami", "pwd", "uname", "command", "which",
                                        "true", "false", "echo"]

    static func classify(_ seg: String, binDir: String) -> Segment {
        let stripped = stripAssignments(seg)
        let head = stripped.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let base = (head as NSString).lastPathComponent
        let kind: Kind
        if head.isEmpty {
            kind = .unsupported("(空)")
        } else if builtins.contains(base) {
            kind = .builtin(base)
        } else if head.hasPrefix("/") {
            let real = normalizePath(head)
            if FileManager.default.isExecutableFile(atPath: real) {
                kind = .bundled(real)
            } else if FileManager.default.isExecutableFile(atPath: head) {
                kind = .bundled(head)
            } else {
                kind = .unsupported(base)
            }
        } else {
            let cand = binDir + "/" + base
            if FileManager.default.isExecutableFile(atPath: cand) {
                kind = .bundled(cand)
            } else {
                kind = .unsupported(base)
            }
        }
        return Segment(raw: stripped, head: head, kind: kind)
    }

    static func plan(_ command: String, binDir: String) -> [Segment] {
        split(command).map { classify(normalizePaths(in: $0), binDir: binDir) }
    }

    // MARK: 内建实现

    static func runBuiltin(_ name: String, args: [String]) -> (out: String, code: Int32) {
        switch name {
        case "id":
            let uid = getuid(), euid = geteuid(), gid = getgid()
            if args.contains("-u") { return ("\(euid)\n", 0) }
            if args.contains("-g") { return ("\(gid)\n", 0) }
            return ("uid=\(uid) euid=\(euid) gid=\(gid)\n", 0)
        case "whoami":
            return ("mobile\n", 0)
        case "pwd":
            return (FileManager.default.currentDirectoryPath + "\n", 0)
        case "uname":
            if args.contains("-a") {
                return ("Darwin \(darwinVersion()) \(deviceModel()) \(ProcessInfo.processInfo.operatingSystemVersionString)\n", 0)
            }
            if args.contains("-m") { return ("arm64\n", 0) }
            return ("Darwin\n", 0)
        case "command", "which":
            guard let target = args.last else { return ("", 1) }
            let binDir = Bundle.main.bundlePath + "/bin"
            let p = binDir + "/" + target
            if FileManager.default.isExecutableFile(atPath: p) { return (p + "\n", 0) }
            if builtins.contains(target) { return ("\(target) (builtin)\n", 0) }
            return ("", 1)
        case "true":  return ("", 0)
        case "false": return ("", 1)
        case "echo":  return (args.joined(separator: " ") + "\n", 0)
        default:      return ("", 127)
        }
    }

    // MARK: 执行

    /// 逐段执行；至少跑成一段时返回结果，全不可执行返回 nil（交给上层报错）。
    static func execute(_ command: String, binDir: String = Bundle.main.bundlePath + "/bin") -> [String: Any]? {
        // v8（P1-5）：`for x in a b c; do CMD; done` —— 简单循环展开（不做嵌套/算术）
        if let expanded = expandForLoop(command, binDir: binDir) {
            return expanded
        }
        let segments = plan(command, binDir: binDir)
        guard !segments.isEmpty else { return nil }

        var outputs: [[String: Any]] = []
        var ran = 0

        for seg in segments {
            switch seg.kind {
            case .builtin(let n):
                let args = argv(seg.raw).dropFirst().map(String.init)
                let r = runBuiltin(n, args: args)
                ran += 1
                outputs.append(["seg": seg.raw, "kind": "builtin", "code": Int(r.code), "out": r.out])
            case .bundled(let path):
                let args = argv(seg.raw).dropFirst().map(String.init)
                let res = BuildRunner.shared.run(executable: path, args: args,
                                                 env: ["PATH": ShellExecTool.effectivePATH],
                                                 timeout: 60)
                var out = res.stdout
                if !res.stderr.isEmpty { out += (out.isEmpty ? "" : "\n") + res.stderr }
                if let err = res.spawnError, !err.isEmpty { out += "\n[spawn error: \(err)]" }
                ran += 1
                outputs.append(["seg": seg.raw, "kind": "exec", "code": Int(res.exitCode), "out": out])
            case .unsupported(let n):
                outputs.append(["seg": seg.raw, "kind": "unsupported", "code": 127,
                                "out": "\(n): 不支持的命令（本段已跳过，其余段继续）"])
            }
        }

        guard ran > 0 else { return nil }
        let combined = outputs.map { ($0["out"] as? String) ?? "" }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return [
            "command": command,
            "exit_code": 0,
            "stdout": combined,
            "ios_native": true,
            "runtime_actual": "native-segmented",
            "segments": outputs,
            "hint": "分段执行：不支持的段已跳过，其余段正常返回",
        ]
    }

    /// 简单 for 循环：for VAR in w1 w2; do BODY; done（只展开一层）
    static func expandForLoop(_ command: String, binDir: String, depth: Int = 0) -> [String: Any]? {
        guard depth < 4 else { return nil }
        let pattern = #"^\s*for\s+([A-Za-z_]\w*)\s+in\s+([^;]+?)\s*;\s*do\s+([\s\S]+?)\s*;?\s*done\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              m.numberOfRanges == 4,
              let varR = Range(m.range(at: 1), in: command),
              let wordsR = Range(m.range(at: 2), in: command),
              let bodyR = Range(m.range(at: 3), in: command) else { return nil }
        let varName = String(command[varR])
        let words = argv(String(command[wordsR]))
        let body = String(command[bodyR])
        guard !words.isEmpty else { return nil }

        var outputs: [[String: Any]] = []
        var ran = 0
        for w in words {
            let expanded = body
                .replacingOccurrences(of: "${\(varName)}", with: w)
                .replacingOccurrences(of: "$\(varName)", with: w)
            if let r = execute(expanded, binDir: binDir) {
                ran += 1
                outputs.append(["seg": "\(varName)=\(w): \(expanded)", "kind": "loop",
                                "code": (r["exit_code"] as? Int) ?? 0,
                                "out": (r["stdout"] as? String) ?? ""])
            }
        }
        guard ran > 0 else { return nil }
        return [
            "command": command,
            "exit_code": 0,
            "stdout": outputs.compactMap { $0["out"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n"),
            "ios_native": true,
            "runtime_actual": "native-loop",
            "segments": outputs,
            "hint": "for 循环已展开执行",
        ]
    }

    /// 引号感知的 argv 拆分
    static func argv(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var has = false
        for c in s {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
                has = true
                continue
            }
            if c == "'" || c == "\"" { quote = c; has = true; continue }
            if c == " " || c == "\t" {
                if has { out.append(cur); cur = ""; has = false }
                continue
            }
            cur.append(c); has = true
        }
        if has { out.append(cur) }
        return out
    }

    private static func darwinVersion() -> String {
        var uts = utsname()
        uname(&uts)
        return withUnsafePointer(to: &uts.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func deviceModel() -> String {
        var uts = utsname()
        uname(&uts)
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
