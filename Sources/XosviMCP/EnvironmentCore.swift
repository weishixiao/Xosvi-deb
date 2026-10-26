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
            printf '%s\\n%s\\n' '\(repoMain)' '\(repoComm)' > /etc/apk/repositories
            """, timeout: 20)

            // 与 Kelivo 一致：先 update 再 add，--wait 等锁
            let script = "set -e\napk --wait 60 update\napk --wait 60 add \(d.packages)\n"
            let r = ISH.run(script, timeout: 300)

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
                    self.failure = r.output.lowercased().contains("cancel") ? .cancelled : .install
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
        if l.contains("unable to lock") { return "有别的安装正在进行，稍后再试" }
        if l.isEmpty { return "安装失败，没拿到输出" }
        return String(log.suffix(300))
    }
}
