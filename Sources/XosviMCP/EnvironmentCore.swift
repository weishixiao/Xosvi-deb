import Foundation

// MARK: - v7.9.0 环境预设 / 镜像（严格对齐 Kelivo 的实现）
//
// 与 Kelivo 的对应关系：
//   EnvironmentDependency        → EnvDependency（6 个预设，包名与探测命令逐字对齐）
//   EnvironmentDependencies      → EnvironmentInstaller（进程内单例，离开页面不中断安装）
//   MirrorEntry / MirrorService  → AlpineMirror / MirrorCatalog
//   MirrorSpeedTest              → MirrorCatalog.speedTest（**在宿主侧**用 Range 请求测，不下发到 guest）
//
// 上一版为什么装不上：
//   1) 探测脚本写成了 printf '%@=' —— Objective-C 的格式符，shell 不认，等于永远探不出来
//   2) 安装直接 apk add --no-cache，没先 apk update；iSH 的 apk 需要先拉索引
//   3) SSH 包名写成 openssh-client，Alpine 里实际是 openssh-client-default
//   4) 测速在 guest 里跑 wget，沙盒没起来时全超时

// MARK: - 环境预设

enum EnvDependency: String, CaseIterable, Identifiable {
    case python, node, git, ssh, network, archive
    var id: String { rawValue }

    var title: String {
        switch self {
        case .python: return "Python"
        case .node: return "Node.js"
        case .git: return "Git"
        case .ssh: return "SSH"
        case .network: return "网络工具"
        case .archive: return "压缩工具"
        }
    }
    var subtitle: String {
        switch self {
        case .python: return "Python、pip 和虚拟环境"
        case .node: return "Node.js 和 npm"
        case .git: return "克隆仓库与版本管理"
        case .ssh: return "SSH、SCP、SFTP 与密钥生成"
        case .network: return "curl · wget"
        case .archive: return "zip · unzip"
        }
    }
    var icon: String {
        switch self {
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .node: return "cube"
        case .git: return "point.topleft.down.curvedto.point.bottomright.up"
        case .ssh: return "key"
        case .network: return "globe"
        case .archive: return "archivebox"
        }
    }

    /// 与 Kelivo 完全一致（alpine 分支）
    var packages: String {
        switch self {
        case .python: return "python3 py3-pip py3-virtualenv"
        case .node: return "nodejs npm"
        case .git: return "git"
        case .ssh: return "openssh-client-default"
        case .network: return "curl wget"
        case .archive: return "zip unzip"
        }
    }

    /// 与 Kelivo 完全一致：全部子命令都成功才算装了
    var probe: String {
        switch self {
        case .python: return "python3 --version && python3 -m pip --version && virtualenv --version"
        case .node: return "node --version && npm --version"
        case .git: return "git --version"
        case .ssh: return "ssh -V && command -v scp && command -v sftp && command -v ssh-keygen"
        case .network: return "curl --version && wget --version"
        case .archive: return "zip -v && unzip -v"
        }
    }
}

enum DependencyStatus { case unknown, missing, installed }

enum DependencyFailure { case check, install, cancelled }

// MARK: - 镜像

struct AlpineMirror: Identifiable, Equatable {
    var id: String
    var name: String
    var region: String          // "中国" / "全球"
    var base: String            // https://mirrors.aliyun.com/alpine/

    var displayName: String { region.isEmpty ? name : "\(name) · \(region)" }

    func apkIndexURL(alpineVersion: String = "v3.21") -> URL? {
        URL(string: base + "\(alpineVersion)/main/aarch64/APKINDEX.tar.gz")
    }
    func pipIndexURL() -> String {
        switch id {
        case "pip.aliyun": return "https://mirrors.aliyun.com/pypi/simple"
        case "pip.tuna": return "https://pypi.tuna.tsinghua.edu.cn/simple"
        case "pip.ustc": return "https://mirrors.ustc.edu.cn/pypi/simple"
        default: return "https://pypi.org/simple"
        }
    }
    var npmRegistry: String {
        id == "npm.official" ? "https://registry.npmjs.org" : "https://registry.npmmirror.com"
    }
}

enum MirrorCatalog {
    static let apk: [AlpineMirror] = [
        .init(id: "apk.aliyun", name: "阿里云", region: "中国", base: "https://mirrors.aliyun.com/alpine/"),
        .init(id: "apk.tuna", name: "清华 TUNA", region: "中国", base: "https://mirrors.tuna.tsinghua.edu.cn/alpine/"),
        .init(id: "apk.ustc", name: "中科大", region: "中国", base: "https://mirrors.ustc.edu.cn/alpine/"),
        .init(id: "apk.huawei", name: "华为云", region: "中国", base: "https://repo.huaweicloud.com/alpine/"),
        .init(id: "apk.tencent", name: "腾讯云", region: "中国", base: "https://mirrors.cloud.tencent.com/alpine/"),
        .init(id: "apk.official", name: "官方", region: "全球", base: "https://dl-cdn.alpinelinux.org/alpine/"),
    ]
    static let pip: [AlpineMirror] = [
        .init(id: "pip.aliyun", name: "阿里云", region: "中国", base: ""),
        .init(id: "pip.tuna", name: "清华 TUNA", region: "中国", base: ""),
        .init(id: "pip.ustc", name: "中科大", region: "中国", base: ""),
        .init(id: "pip.official", name: "官方", region: "全球", base: ""),
    ]
    static let npm: [AlpineMirror] = [
        .init(id: "npm.npmmirror", name: "npmmirror", region: "中国", base: ""),
        .init(id: "npm.official", name: "官方", region: "全球", base: ""),
    ]

    static func current(_ kind: String) -> AlpineMirror {
        let key = "mirror.\(kind)"
        let saved = UserDefaults.standard.string(forKey: key)
        let list = kind == "apk" ? apk : (kind == "pip" ? pip : npm)
        return list.first { $0.id == saved } ?? list[0]
    }

    static func setCurrent(_ kind: String, _ m: AlpineMirror) {
        UserDefaults.standard.set(m.id, forKey: "mirror.\(kind)")
    }

    /// 宿主侧测速（Kelivo 的做法）：Range 请求 APKINDEX，比在 guest 里跑 wget 稳
    static func speedTest(_ mirrors: [AlpineMirror], timeout: TimeInterval = 6) -> [(AlpineMirror, Double)] {
        var out: [(AlpineMirror, Double)] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for m in mirrors {
            guard let url = m.apkIndexURL() else { continue }
            group.enter()
            var req = URLRequest(url: url, timeoutInterval: timeout)
            req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            let start = CFAbsoluteTimeGetCurrent()
            URLSession.shared.dataTask(with: req) { _, resp, err in
                defer { group.leave() }
                let dt = CFAbsoluteTimeGetCurrent() - start
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard err == nil, code >= 200, code < 400 else { return }
                lock.lock(); out.append((m, dt)); lock.unlock()
            }.resume()
        }
        _ = group.wait(timeout: .now() + timeout + 2)
        return out.sorted { $0.1 < $1.1 }
    }
}

// MARK: - 安装器（进程内单例，离开页面不中断）

final class EnvironmentInstaller: ObservableObject {
    static let shared = EnvironmentInstaller()

    @Published private(set) var statuses: [EnvDependency: DependencyStatus] = [:]
    @Published private(set) var installing: EnvDependency?
    @Published private(set) var lastInstalled: EnvDependency?
    @Published private(set) var failure: DependencyFailure?
    @Published private(set) var log: String = ""
    @Published private(set) var busy = false

    private var queue = DispatchQueue(label: "env.installer", qos: .userInitiated)

    func status(_ d: EnvDependency) -> DependencyStatus { statuses[d] ?? .unknown }

    // MARK: 探测

    /// 一次 shell 把 6 个都探完（用醒目的标记，避免和命令自身输出混在一起）
    func refresh(completion: (() -> Void)? = nil) {
        guard !busy else { completion?(); return }
        busy = true
        let script = EnvDependency.allCases.map { d in
            "if ( \(d.probe) ) >/dev/null 2>&1; then echo '__envdep_\(d.rawValue)=1'; "
            + "else echo '__envdep_\(d.rawValue)=0'; fi"
        }.joined(separator: "\n")

        queue.async {
            let r = ISH.run(script, timeout: 60)
            var map: [EnvDependency: DependencyStatus] = [:]
            for line in r.output.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("__envdep_"), let eq = t.firstIndex(of: "=") else { continue }
                let key = String(t[t.index(t.startIndex, offsetBy: 9)..<eq])
                let val = String(t[t.index(after: eq)...])
                if let d = EnvDependency(rawValue: key) {
                    map[d] = (val == "1") ? .installed : .missing
                }
            }
            DispatchQueue.main.async {
                self.statuses = map
                self.busy = false
                if map.isEmpty { self.failure = .check }
                completion?()
            }
        }
    }

    // MARK: 安装

    func install(_ d: EnvDependency) {
        guard installing == nil else { return }
        installing = d
        failure = nil
        log = ""

        queue.async {
            // 先把当前选择的 APK 源写进去（Kelivo 也是先应用源再装）
            let mirror = MirrorCatalog.current("apk")
            let repoMain = mirror.base + "v3.21/main"
            let repoComm = mirror.base + "v3.21/community"
            _ = ISH.run("""
            mkdir -p /etc/apk
            old=$(cat /etc/apk/repositories 2>/dev/null)
            printf '%s\\n%s\\n' '\(repoMain)' '\(repoComm)' > /etc/apk/repositories
            if [ "$old" != "$(cat /etc/apk/repositories)" ]; then
              rm -f /var/cache/apk/APKINDEX.*.tar.gz
              echo "[env] 镜像源已切换，清空旧索引缓存"
            fi
            """, timeout: 25)

            // v7.14.7：先清残锁。iSH 内核里的 apk 进程被强杀/沙盒重启后，
            // /lib/apk/db/lock 可能留下"无人持有但 apk 认为被占"的状态，
            // 表现为一直卡在 "Waiting for repository lock"。
            // 用 flock -n 判定：能拿到 = 确实没人持有 → 删除锁文件重来。
            _ = ISH.run("""
            if command -v flock >/dev/null 2>&1; then
              if flock -n /lib/apk/db/lock true 2>/dev/null; then
                rm -f /lib/apk/db/lock
                echo "[env] 清理残留 apk 锁"
              fi
            fi
            """, timeout: 20)

            // 与 Kelivo 一致：先 update 再 add，--wait 等锁
            // v7.14.9：分步执行并把每一步的耗时/退出码写进日志。
            // 之前一条 script 跑完只见两行 fetch 就"取消"，无法判断是 update 卡住、
            // apk 被信号打断，还是沙盒中途重启——现在日志里能直接看出是哪一步。
            var logLines: [String] = []

            // v7.14.10：App 内的沙盒进程有时**拉索引会挂住**（实测：同样命令在 shell 里 6s，
            // 在 App 启动的沙盒进程里 128s 拿不到第一行回复）。索引其实常常已经存在，
            // 所以先探测：索引可用就跳过 update，直接用缓存装；只有确实没有才去拉。
            // 关键：apk 的索引缓存文件名是**按仓库 URL 哈希**的（APKINDEX.<hash>.tar.gz），
            // 换镜像后旧缓存对不上，apk 会去网络重新拉。所以不能"有任何索引文件就算有"。
            // 这里带 --no-network 让 apk 只读缓存：能列出包 = 当前仓库的索引确实在本地。
            let probe = ISH.run("apk --no-network info >/dev/null 2>&1 && echo IDX_OK || echo IDX_MISSING", timeout: 45)
            let hasIndex = probe.output.contains("IDX_OK")
            logLines.append("[env] 索引: \(hasIndex ? "已有，跳过 update" : "缺失，需要 update")")

            var upd = ISH.RunResult(output: "", exitCode: 0, timedOut: false)
            if !hasIndex {
                let t0 = Date()
                upd = ISH.run("apk --wait 60 update", timeout: 300)               // 慢镜像留足时间
                let tUpdate = Int(Date().timeIntervalSince(t0))
                logLines.append("[env] update: exit=\(upd.exitCode) timedOut=\(upd.timedOut) \(tUpdate)s")
                logLines.append(upd.output)
                // 拉索引超时：再给一次机会（第一次往往是沙盒进程刚起，DNS/网络栈还没热）
                if upd.timedOut {
                    logLines.append("[env] update 超时，重试一次（沙盒网络栈预热）")
                    let t2 = Date()
                    upd = ISH.run("apk --wait 30 update", timeout: 180)
                    logLines.append("[env] update 重试: exit=\(upd.exitCode) timedOut=\(upd.timedOut) \(Int(Date().timeIntervalSince(t2)))s")
                    logLines.append(upd.output)
                }
            }

            var r = upd
            // 只有"索引确实对应当前仓库"才直接装；否则必须先 update 拉索引
            if hasIndex || (upd.exitCode == 0 && !upd.timedOut) {
                let t1 = Date()
                let add = ISH.run("apk --wait 60 add \(d.packages)", timeout: 1800)   // 对齐 Kelivo：30 分钟
                let tAdd = Int(Date().timeIntervalSince(t1))
                logLines.append("[env] add: exit=\(add.exitCode) timedOut=\(add.timedOut) \(tAdd)s")
                logLines.append(add.output)
                r = ISH.RunResult(output: logLines.joined(separator: "\n"),
                                  exitCode: add.exitCode, timedOut: add.timedOut)
            } else {
                r = ISH.RunResult(output: logLines.joined(separator: "\n"),
                                  exitCode: upd.exitCode, timedOut: upd.timedOut)
            }

            // 装完立刻复查这一项（不靠返回值猜）
            let verify = ISH.run("if ( \(d.probe) ) >/dev/null 2>&1; then echo 1; else echo 0; fi", timeout: 60)
            let ok = verify.output.contains("1")

            DispatchQueue.main.async {
                self.log = r.output
                self.installing = nil
                if ok {
                    self.statuses[d] = .installed
                    self.lastInstalled = d
                } else {
                    self.statuses[d] = .missing
                    // v7.14.9：原来靠 `output.contains("cancel")` 猜状态——apk 在某些失败/中断的
                    // 输出里也带 "cancel"，于是任何失败都会被说成"安装已取消"，误导排查。
                    // 现在按**真实结果**判定：超时 / 非零退出 / 探测仍未通过。
                    if r.timedOut {
                        self.failure = .cancelled
                        self.log = r.output + "\n[env] 安装超时（apk 等待锁或网络过慢），已中止"
                    } else if r.exitCode != 0 {
                        self.failure = .install
                    } else {
                        self.failure = .install
                        self.log = r.output + "\n[env] apk 返回成功但探测未通过（包可能已装，命令名不一致）"
                    }
                }
            }
        }
    }

    /// 安装失败时给人看的解释
    func diagnose(_ d: EnvDependency) -> String {
        let l = log.lowercased()
        if l.contains("no space") { return "沙盒空间不足" }
        if l.contains("network") || l.contains("unable to select") || l.contains("temporary failure")
            || l.contains("could not connect") { return "拉不到软件源，换一个镜像再试" }
        if l.contains("unable to lock") || l.contains("waiting for repository lock") {
            return "apk 锁被占用或残留：点「重新安装」会自动清一次残留锁；仍不行就重启 iSH 沙盒后再试"
        }
        if l.contains("apk: not found") || l.contains("/sbin/apk") && l.contains("no such file") {
            return "沙盒里没有 apk，说明 rootfs 不完整：到 设置 → 环境 页重装 rootfs"
        }
        if l.isEmpty { return "安装失败，没拿到输出（沙盒可能未启动，见 设置 → 环境 → 沙盒状态）" }
        return String(log.suffix(300))
    }
}
