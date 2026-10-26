import Foundation

/// v6.3.9：iSH 引擎「进程隔离」运行器（用户选定的 A 方案）。
///
/// 背景：iSH 是**进程内**链接的 x86 模拟器，段错误 = 整个 App 被系统杀掉。
/// 用户 11 条崩溃日志符号化后 100% 落在引擎内部（cpu_run_to_interrupt /
/// task_run_wakeup / poll_wakeup / err_map），即"引擎一跑就可能全 App 崩"。
///
/// 方案：主 App 用 posix_spawn 把**自己**以 `-trollish` 子模式拉起（与 HUD 的 `-hud`
/// 双模式同一套路，复用主可执行 → 无需新构建目标、无需额外签名）。命令在子进程里跑：
///   · 子进程崩（引擎段错误）→ waitpid 得到 128+signum → 主 App 存活，回报"引擎崩溃（已隔离）"
///   · 子进程正常 → 输出原文返回，退出码透传
/// 代价：每次命令要 boot 一次引擎（首次约数秒），换来"引擎常开也不闪退"。
enum TrollishRunner {
    /// 当前进程是否为隔离子进程（子进程内不得再次隔离，否则无限递归）
    private(set) static var isChild = false

    /// 子模式：在本进程内执行一次引擎命令，结果写标准输出，退出码=命令退出码。
    /// 由 AppMain 在检测到 `-trollish` 时调用（不返回）。
    static func runChildMode(args: [String]) -> Never {
        isChild = true
        var command = ""
        var timeout: TimeInterval = 60
        var i = 0
        while i < args.count {
            if args[i] == "-c", i + 1 < args.count {
                let raw = args[i + 1]
                if let d = Data(base64Encoded: raw), let s = String(data: d, encoding: .utf8) {
                    command = s
                } else {
                    command = raw
                }
                i += 2
                continue
            }
            if args[i] == "-t", i + 1 < args.count {
                timeout = TimeInterval(Double(args[i + 1]) ?? 60)
                i += 2
                continue
            }
            i += 1
        }
        guard !command.isEmpty else {
            FileHandle.standardError.write(Data("trollish: empty command\n".utf8))
            exit(2)
        }
        let (out, code, timedOut) = ISHEngine.exec(command, timeout: timeout)
        var text = out
        if timedOut { text += "\n[执行超时 \(Int(timeout))s 被终止]" }
        FileHandle.standardOutput.write(Data(text.utf8))
        exit(timedOut ? 124 : (code < 0 ? 1 : code))
    }

    /// 隔离是否可用（主可执行存在；且当前不在子进程内）
    static var available: Bool {
        if isChild { return false }
        guard let p = Bundle.main.executablePath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }

    /// 隔离开关（默认开启；设置里可关掉回退进程内执行）
    static var enabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: "ishProcessIsolation") == nil { return true }
        return d.bool(forKey: "ishProcessIsolation")
    }

    /// 在子进程里执行命令。返回 nil 表示未能隔离（子进程都没起来）→ 上层回退进程内执行。
    static func runIsolated(_ command: String, timeout: TimeInterval)
        -> (output: String, exitCode: Int32, crashed: Bool)? {
        guard available, let exe = Bundle.main.executablePath else { return nil }
        let b64 = Data(command.utf8).base64EncodedString()
        let res = BuildRunner.shared.run(executable: exe,
                                         args: ["-trollish", "-c", b64, "-t", "\(Int(timeout))"],
                                         env: ["TROLLISH_CHILD": "1"],
                                         timeout: timeout + 20)
        if res.exitCode == -1 || res.spawnError != nil {
            return nil   // 子进程未启动（如沙箱拒绝）→ 回退进程内
        }
        var out = res.stdout
        if !res.stderr.isEmpty {
            out += (out.isEmpty ? "" : "\n") + res.stderr
        }
        // BuildRunner 按 POSIX 惯例编码：被信号杀死 = 128 + signum（SIGSEGV=11 → 139）
        let crashed = res.exitCode >= 128
        if crashed {
            let sig = res.exitCode - 128
            out += "\n[⚠️ iSH 引擎在隔离子进程内崩溃（signal \(sig)），已隔离：App 未受影响、未闪退。"
                + "命令未完成——可重试，或改用原生命令（find/du/plutil/bsdtar/python3 等，均不经引擎）。]"
        }
        return (out, crashed ? 1 : res.exitCode, crashed)
    }
}