import Foundation
import Darwin
import CISH

/// v6.6.9：iSH 终端会话——持久交互式 shell。
///
/// 对接 CISH/wrapper.c 的 `cish_spawn(path, argv_buf, envp_buf, argc, stdin_fd, out_fd, err_fd, notify_fd)`，
/// 该接口本就支持 stdin/out/err 管道（注释标明"OpenMinis 同款"），因此无需改动 C 层。
///
/// 与 `ISHEngine.exec` 的区别：
///   - exec：一次性 `/bin/sh -c "<cmd>"`，同步等待，命令结束即退出
///   - 本类：持久 `/bin/sh -i`，stdin 可反复写入，输出实时回调，供终端界面使用
///
/// 线程模型：
///   - 后台线程阻塞 read(outFD) → onOutput（主线程投递）
///   - stdout 读线程 EOF → shell 退出 → onExit（不用全局 notify 管道，避免和 exec 抢）
///   - send() 在调用方线程加锁写 stdinFD
final class TerminalSession {

    private(set) var pid: Int = -1
    private var stdinFD: Int32 = -1
    private var outFD: Int32 = -1

    private var readerThread: Thread?
    private var running = false
    private let writeLock = NSLock()
    private let stateLock = NSLock()

    /// 输出回调（内容为原始字节，含 ANSI 转义序列）
    var onOutput: ((Data) -> Void)?
    /// 退出回调（退出码）
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    // MARK: - 生命周期

    /// 启动交互式 shell。返回错误文案（nil = 成功）。
    func start(cols: Int, rows: Int) -> String? {
        stateLock.lock()
        let already = running
        stateLock.unlock()
        if already { return nil }

        // 引擎总开关（与 ISHEngine.exec 一致：默认关闭防闪退）
        if !UserDefaults.standard.bool(forKey: "alpineEngineEnabled") {
            return "Alpine/iSH 引擎未启用。请到 设置 → 安全 → 打开「Alpine/iSH 引擎」后重试（该引擎在 arm64 真机上偶发段错误，终端已做子进程隔离兜底）。"
        }
        if cish_engine_broken() != 0 {
            return "iSH 引擎此前已崩溃。请重启 App 后再试。"
        }
        if let bootErr = ISHEngine.ensureBooted() {
            return bootErr
        }

        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else {
            return "管道创建失败"
        }

        let argvBuf = Self.buildCStringArray(["/bin/sh", "-i"])
        let envpBuf = Self.buildEnvp(cols: cols, rows: rows)

        // 注意：cish_spawn 的 notify 管道是**全局单例**（wrapper.c 的 g_notify_fd），
        // 同一时刻只能有一个接收者。终端是长期进程，若占用 notify 会和 ISHEngine.exec 抢，
        // 因此这里传 -1，改用"stdout 读线程 EOF = shell 已退出"来判断生命周期。
        let spawned: Int = argvBuf.withCString { av in
            envpBuf.withCString { ev in
                "/bin/sh".withCString { p in
                    // stdout 与 stderr 共用同一管道（终端里本就应混排）
                    cish_spawn(p, av, ev, 2, inPipe[0], outPipe[1], outPipe[1], -1)
                }
            }
        }

        // 父进程关闭已交给 guest 的端
        close(inPipe[0]); close(outPipe[1])

        guard spawned > 0 else {
            close(inPipe[1]); close(outPipe[0])
            return "shell 启动失败 (rc=\(spawned))。可尝试重启 App 恢复引擎。"
        }

        stateLock.lock()
        pid = spawned
        stdinFD = inPipe[1]
        outFD = outPipe[0]
        running = true
        stateLock.unlock()

        startReader()
        return nil
    }

    /// 写入 stdin（键盘输入、粘贴等）
    func send(_ data: Data) {
        stateLock.lock()
        let fd = stdinFD
        let ok = running
        stateLock.unlock()
        guard ok, fd >= 0, !data.isEmpty else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            let total = data.count
            while off < total {
                let n = write(fd, base.advanced(by: off), total - off)
                if n <= 0 {
                    if errno == EINTR { continue }
                    break
                }
                off += n
            }
        }
    }

    func send(_ text: String) {
        if let d = text.data(using: .utf8) { send(d) }
    }

    /// v6.6.12：向 guest 发送信号。
    /// 无 tty 时 Ctrl+C 的 0x03 字节只是普通输入，不会触发 SIGINT，必须由客户端直接发信号。
    func signal(_ sig: Int32) {
        stateLock.lock()
        let p = pid
        let ok = running
        stateLock.unlock()
        guard ok, p > 0 else { return }
        _ = cish_kill(p, sig)
    }

    /// 结束会话
    func stop() {
        stateLock.lock()
        let wasRunning = running
        let p = pid
        running = false
        stateLock.unlock()
        guard wasRunning else { return }

        if p > 0 {
            _ = cish_killpg(p, Int32(SIGTERM))
            usleep(80_000)
            _ = cish_killpg(p, Int32(SIGKILL))
        }
        teardownFDs()
    }

    /// 关闭 fd 并清空状态（幂等）
    private func teardownFDs() {
        stateLock.lock()
        let inFD = stdinFD, oFD = outFD
        stdinFD = -1; outFD = -1
        stateLock.unlock()
        // 关闭 fd 会让阻塞中的 read 立即返回 0/EBADF，读线程自然退出
        if inFD >= 0 { close(inFD) }
        if oFD >= 0 { close(oFD) }
    }

    // MARK: - 后台读取

    private func startReader() {
        stateLock.lock()
        let fd = outFD
        stateLock.unlock()
        guard fd >= 0 else { return }

        let t = Thread { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(fd, &buf, buf.count)
                if n > 0 {
                    let chunk = Data(buf[0..<n])
                    let cb = self.onOutput
                    DispatchQueue.main.async { cb?(chunk) }
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                break   // EOF / 错误 → shell 已退出
            }
            // v6.6.9：EOF 即退出（notify 管道全局单例，终端不占用它）
            self.stateLock.lock()
            let wasRunning = self.running
            self.running = false
            self.stateLock.unlock()
            self.teardownFDs()
            if wasRunning {
                let cb = self.onExit
                DispatchQueue.main.async { cb?(0) }
            }
        }
        t.name = "ish-terminal-reader"
        t.stackSize = 512 * 1024
        readerThread = t
        t.start()
    }


    // MARK: - C 字符串块构造

    /// NUL 分隔 + 末尾双 NUL 的 argv 块
    private static func buildCStringArray(_ args: [String]) -> String {
        args.joined(separator: "\0") + "\0\0"
    }

    /// 终端环境：TERM 开启彩色（与 exec 的 NO_COLOR=1 不同，终端要看到颜色）
    private static func buildEnvp(cols: Int, rows: Int) -> String {
        var vars: [String] = []
        vars.append("TERM=xterm-256color")
        vars.append("HOME=/root")
        vars.append("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
        vars.append("LANG=C.UTF-8")
        vars.append("CHARSET=UTF-8")
        vars.append("ENV=/etc/profile")
        vars.append("OPENSSL_armcap=0")
        vars.append("PYTHONDONTWRITEBYTECODE=1")
        vars.append("COLUMNS=\(max(20, cols))")
        vars.append("LINES=\(max(10, rows))")
        let secs = TimeZone.current.secondsFromGMT()
        let hrs = secs / 3600
        let mins = abs(secs % 3600) / 60
        let tz = mins != 0 ? String(format: "LCL%+ld:%02ld", -hrs, mins) : String(format: "LCL%+ld", -hrs)
        vars.append("TZ=\(tz)")
        vars.append("PS1=\\w \\$ ")
        return vars.joined(separator: "\0") + "\0\0"
    }
}
