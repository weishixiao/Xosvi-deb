import Foundation
import Combine

// MARK: - GitHub 账号模型

struct GitHubAccount: Codable, Identifiable, Equatable {
    var login: String
    var name: String?
    var avatarURL: String?
    var token: String
    var id: String { login }
}

/// GitHub Actions run 摘要 (用于线上编译状态展示）
struct GitHubRun: Identifiable {
    let id: Int
    let status: String          // queued / in_progress / completed
    let conclusion: String?     // success / failure / null
    let createdAt: String
    let headBranch: String
    let displayTitle: String

    var statusText: String {
        switch status {
        case "completed":
            return (conclusion ?? "unknown") == "success" ? "✅ done" : "❌ \(conclusion ?? "failed")"
        case "in_progress": return "⏳ building"
        default: return "🕐 queued"
        }
    }
}

// MARK: - GitHub 账号 + 线上编译 (v2.9.5）

/// 管理多个 GitHub 账号：PAT 登录 / 切换 / 删除 / 触发线上编译 workflow / 查询 run 状态。
/// Token 存 UserDefaults (与项目 GatewayClient 同款策略；TrollStore 下 Keychain 受 entitlements 限制不可靠）。
final class GitHubAccountStore: ObservableObject {
    static let shared = GitHubAccountStore()

    @Published private(set) var accounts: [GitHubAccount] = []
    @Published var activeLogin: String?
    @Published var isVerifying = false
    @Published var isTriggering = false
    @Published var lastError: String?
    @Published private(set) var runs: [GitHubRun] = []

    // 目标仓库 (可在设置页修改；默认 xosvi 仓库 + build-tweak workflow）
    @Published var repoOwner: String
    @Published var repoName: String
    @Published var workflowId: String
    @Published var branch: String

    // Device Flow 用 OAuth App client_id。
    // 默认值 = 内置共享 Client ID (origina47487lhe-droid 注册的 "Xosvi 线上编译" OAuth App，
    // Device Flow 已启用）。任意 GitHub 用户都可借此授权，各自拿自己的 token——新手零配置。
    // 高级用户可在「仓库设置」覆盖为自己的 OAuth App。
    @Published var clientID: String

    // Device Flow 轮询状态
    @Published var deviceFlowState: String?   // 提示文案 (含 user_code）
    @Published var isDevicePolling = false
    private var pollTimer: DispatchSourceTimer?   // 持有强引用，防止局部变量被释放导致轮询停止
    /// v6.6.20：GitHub 要求的最小轮询间隔（秒）。收到 slow_down 时按规范 +5s 并重排定时器。
    private var pollInterval: TimeInterval = 5
    /// v6.6.20：上一次换取 token 的时间——手动"立即检查"必须遵守间隔，否则必然 slow_down。
    private var lastExchangeAt: Date = .distantPast

    private let accountsKey = "xosvi.github_accounts"
    private let activeKey = "xosvi.github_active"
    private let ownerKey = "xosvi.github_repo_owner"
    private let repoKey = "xosvi.github_repo_name"
    private let workflowKey = "xosvi.github_workflow_id"
    private let branchKey = "xosvi.github_branch"
    private let clientIDKey = "xosvi.github_client_id"

    /// 内置默认 OAuth App Client ID (origina47487lhe-droid 注册的 "Xosvi 线上编译"，Device Flow 实测有效）
    static let defaultClientID = "Ov23li890n3hM15edlcw"

    private let apiBase = "https://api.github.com"
    private let loginBase = "https://github.com"

    init() {
        let def = UserDefaults.standard
        repoOwner = def.string(forKey: ownerKey) ?? "zrrt"
        repoName = def.string(forKey: repoKey) ?? "xosvi-ios"
        workflowId = def.string(forKey: workflowKey) ?? "build-xosvi-ios.yml"
        branch = def.string(forKey: branchKey) ?? "main"
        // v2.9.117：空字符串也回退内置默认 (旧版删空保存会覆盖默认值，导致"未设置 Client ID"）
        let savedCID = def.string(forKey: clientIDKey) ?? ""
        clientID = savedCID.isEmpty ? Self.defaultClientID : savedCID
        load()
    }

    // MARK: - 账号访问

    var activeAccount: GitHubAccount? {
        guard let login = activeLogin else { return nil }
        return accounts.first { $0.login == login }
    }

    var activeToken: String? { activeAccount?.token }

    func token(for login: String) -> String? {
        accounts.first { $0.login == login }?.token
    }

    // MARK: - 持久化

    private func load() {
        // v2.9.110：旧配置自动迁移——早期默认指向 origina47487lhe-droid (Actions 配额已耗尽）与
        // build-tweak workflow (已更名 build-xosvi-ios.yml）。覆盖安装会保留旧 UserDefaults，
        // 这里检测到旧值自动纠正，避免线上编译 404 / 触发到错误仓库。
        // v6.6.7：GitHub 仓库改名 xosvi→xosvi-ios，workflow 文件同步改名；
        // 老用户若之前手动配置过 build-xosvi.yml，升级后自动切到新名。
        let def = UserDefaults.standard
        if def.string(forKey: ownerKey) == "origina47487lhe-droid" {
            repoOwner = "zrrt"
        }
        if let old = def.string(forKey: workflowKey),
           old == "build-tweak" || old == "build-xosvi.yml" {
            workflowId = "build-xosvi-ios.yml"
        }
        // v6.6.20：仓库本体也改名了（xosvi → xosvi-ios）。
        // 只改 workflow 文件不够——trigger 会打到 repos/<owner>/xosvi/...，
        // 结果就是"触发 failed (HTTP 403/404)"，而界面上看不出问题出在仓库名。
        if def.string(forKey: repoKey) == "xosvi" {
            repoName = "xosvi-ios"
        }
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let saved = try? JSONDecoder().decode([GitHubAccount].self, from: data) {
            accounts = saved
        }
        activeLogin = UserDefaults.standard.string(forKey: activeKey)
        if let l = activeLogin, !accounts.contains(where: { $0.login == l }) {
            activeLogin = accounts.first?.login
        }
        persist()   // v2.9.110：迁移后的值落盘，一次性纠正旧配置
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
        UserDefaults.standard.set(activeLogin, forKey: activeKey)
        let def = UserDefaults.standard
        def.set(repoOwner, forKey: ownerKey)
        def.set(repoName, forKey: repoKey)
        def.set(workflowId, forKey: workflowKey)
        def.set(branch, forKey: branchKey)
        // v2.9.123：留空 = 使用内置默认，且删除旧的自定义值 (根治"清空无效"——旧错误值残留 UserDefaults 导致重启后仍 404）
        let trimmedCID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCID.isEmpty {
            def.removeObject(forKey: clientIDKey)
        } else {
            def.set(trimmedCID, forKey: clientIDKey)
        }
    }

    /// v2.9.124：一键恢复内置默认 (内存立即生效 + 持久化，避免"恢复后不重启仍报空值"）
    func restoreDefaultClientID() {
        clientID = Self.defaultClientID
        persistNow()
    }

    // MARK: - Device Flow (内置浏览器登录，gh CLI 同款）

    /// 设备授权码模型
    struct DeviceCode: Codable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    /// 第一步：请求设备授权码。回调返回验证 URL 与 user_code。
    func startDeviceFlow(completion: @escaping (DeviceCode?, String?) -> Void) {
        // v2.9.124：空值一律回退内置默认 (恢复默认/手动清空后即使不重启 App 也能直接登录）
        let cid = clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultClientID
            : clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        var req = URLRequest(url: URL(string: "\(loginBase)/login/device/code")!, timeoutInterval: 30)
        setHTTPMethod("POST", on: &req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // scope：repo (读仓库+触发 workflow）+ workflow (workflow dispatch 必须）
        let body = "client_id=\(cid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cid)&scope=repo%20workflow"
        req.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    self.lastError = "网络错误: \(err.localizedDescription)"
                    completion(nil, self.lastError)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let data = data,
                      let code = try? JSONDecoder().decode(DeviceCode.self, from: data) else {
                    let raw = data.map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
                    self.lastError = status == 404 ? "Client ID 无效。若手动填过 Client ID：请到仓库设置里清空并保存 (自动回退内置默认)，或注册自己的 OAuth App 后填入真实 Client ID。" : "设备码请求failed (HTTP \(status)) \(raw.prefix(200))"
                    completion(nil, self.lastError)
                    return
                }
                self.deviceFlowState = "请在浏览器输入代码 \(code.user_code)"
                NetworkLog.shared.log("GitHub Device Flow 开始: user_code=\(code.user_code)")
                completion(code, nil)
            }
        }.resume()
    }

    /// 第二步：轮询换取 access_token (interval 秒一次，最长 expires_in 秒）。
    /// v6.4.3：最近一次 device code（供"我已授权·立即检查"手动触发）
    @Published var currentDeviceCode: DeviceCode?

    /// v6.4.3：手动立即检查一次（用户已在网页授权完成，但自动轮询因网络抖动一直没拿到 token
    /// ——实测痛点："已授权但 app 里无法返回授权请求"，因为轮询失败是静默重试、界面无反馈）。
    func checkNow() {
        guard let dc = currentDeviceCode else { return }
        // v6.6.20：遵守 OAuth 规定的轮询间隔。
        // 之前从授权页返回就立刻查一次，往往距上次轮询不足 interval → 必然 slow_down，
        // 而 slow_down 又被当成"确认失败"显示，用户体感就是"怎么都登不上"。
        let elapsed = Date().timeIntervalSince(lastExchangeAt)
        let wait = pollInterval - elapsed
        if wait > 0 {
            deviceFlowState = "请等待 \(Int(wait.rounded(.up))) 秒后自动确认…"
            return
        }
        deviceFlowState = "正在确认授权结果…"
        exchangeDeviceToken(deviceCode: dc) { [weak self] token, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let token = token {
                    self.pollTimer?.cancel()
                    self.pollTimer = nil
                    self.isDevicePolling = false
                    self.deviceFlowState = nil
                    self.finishLoginWith(token: token) { _, _ in }
                } else if let error = error {
                    // 把真实原因显示出来（网络/HTTP/错误码），不再静默
                    self.lastError = error
                    self.deviceFlowState = "确认失败：\(error)（可稍后重试或改用下方手动 Token）"
                }
            }
        }
    }

    /// v6.9.11：用户主动取消等待——停掉轮询定时器并复位状态。
    /// 只把 isDevicePolling 置 false 不会停 timer，后台仍会继续打 GitHub，
    /// 一旦成功还会把用户"意外登录"，所以必须显式 cancel。
    func cancelDevicePolling() {
        pollTimer?.cancel()
        pollTimer = nil
        currentDeviceCode = nil
        isDevicePolling = false
        deviceFlowState = nil
    }

    func pollDeviceToken(deviceCode: DeviceCode, completion: @escaping (Bool, String?) -> Void) {
        isDevicePolling = true
        currentDeviceCode = deviceCode   // v6.4.3：供手动立即检查
        deviceFlowState = "请在浏览器输入代码 \(deviceCode.user_code)，等待授权…"

        let deadline = Date().addingTimeInterval(Double(deviceCode.expires_in))
        pollInterval = max(5, Double(deviceCode.interval))   // GitHub 规定最小 5s
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        pollTimer = timer
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { timer.cancel(); return }
            if Date() > deadline {
                timer.cancel()
                self.pollTimer = nil
                DispatchQueue.main.async {
                    self.isDevicePolling = false
                    self.deviceFlowState = nil
                    completion(false, "授权超时，请重试")
                }
                return
            }
            self.exchangeDeviceToken(deviceCode: deviceCode) { token, error in
                if let token = token {
                    timer.cancel()
                    self.pollTimer = nil
                    DispatchQueue.main.async {
                        self.isDevicePolling = false
                        self.deviceFlowState = nil
                        // 用拿到的 token 走统一验证流程 (GET /user + 存储）
                        self.finishLoginWith(token: token) { ok, msg in
                            completion(ok, msg)
                        }
                    }
                } else if error == "slow_down" {
                    // v6.6.20：OAuth 规范要求——收到 slow_down 时把间隔 +5s 再重试，
                    // 而不是按原间隔继续打（旧实现照旧轮询，会一直被限流，永远拿不到 token）。
                    self.pollInterval += 5
                    timer.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval)
                    DispatchQueue.main.async {
                        self.deviceFlowState = "GitHub 要求放慢轮询，已自动调整为每 \(Int(self.pollInterval)) 秒一次…"
                    }
                } else if let error = error {
                    // v3.0.42：只有"终止性"错误才停轮询；网络错误/解析failed/authorization_pending
                    // 一律继续等下一次——之前网络错误会 cancel timer，移动网络一抖授权流程就死，卡"等待授权"。
                    // v6.4.1：把"配置类"错误也判终止（原来会一直转圈到超时，用户只看到"等待授权"）：
                    // incorrect_client_credentials / device_flow_disabled / unsupported_grant_type
                    // 都是 Client ID 或 OAuth App 未开 Device Flow 导致的，必须立刻告诉用户。
                    let terminalErrors = ["access_denied", "expired_token",
                                          "incorrect_client_credentials", "invalid_grant",
                                          "device_flow_disabled", "unsupported_grant_type"]
                    if terminalErrors.contains(error) {
                        timer.cancel()
                        self.pollTimer = nil
                        DispatchQueue.main.async {
                            self.isDevicePolling = false
                            self.deviceFlowState = nil
                            completion(false, error)
                        }
                    }
                    // 可重试错误：继续轮询 (timer 按 interval 再次触发）
                }
            }
        }
        timer.resume()
    }

    private func exchangeDeviceToken(deviceCode: DeviceCode,
                                     completion: @escaping (String?, String?) -> Void) {
        let cid = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        lastExchangeAt = Date()   // v6.6.20：供 checkNow 计算冷却
        var req = URLRequest(url: URL(string: "\(loginBase)/login/oauth/access_token")!, timeoutInterval: 20)
        setHTTPMethod("POST", on: &req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(cid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cid)&device_code=\(deviceCode.device_code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? deviceCode.device_code)&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
        req.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            // v6.4.1：诊断透出——原来解析失败只说"响应解析failed"，无法定位（用户"已授权但 app
            // 收不到 token"就是被这句吞掉的）。现在保留 HTTP 状态 + 原始响应片段。
            if let err = err { completion(nil, "网络错误: \(err.localizedDescription)"); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(无响应体)"
                completion(nil, "HTTP \(status) 响应无法解析：\(raw.prefix(160))")
                return
            }
            if let token = json["access_token"] as? String {
                completion(token, nil)
            } else if let err = json["error"] as? String {
                completion(nil, err)   // authorization_pending / slow_down / expired_token / access_denied
            } else {
                completion(nil, "未知响应")
            }
        }.resume()
    }

    /// 统一登录落库：验证 token 身份 → 加入/更新账号
    private func finishLoginWith(token: String, completion: @escaping (Bool, String?) -> Void) {
        var req = URLRequest(url: URL(string: "\(apiBase)/user")!, timeoutInterval: 30)
        setHTTPMethod("GET", on: &req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    self.lastError = "网络错误: \(err.localizedDescription)"
                    completion(false, self.lastError)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let login = json["login"] as? String else {
                    self.lastError = "身份验证failed (HTTP \(status))"
                    completion(false, self.lastError)
                    return
                }
                let acct = GitHubAccount(login: login,
                                         name: json["name"] as? String,
                                         avatarURL: json["avatar_url"] as? String,
                                         token: token)
                // v2.9.117：全新账号授权OK后，若 Owner 仍是内置默认值 → 自动填入当前登录账号
                let isDefaultOwner = (self.repoOwner == "zrrt" || self.repoOwner == "origina47487lhe-droid")
                if isDefaultOwner && self.repoOwner != login {
                    self.repoOwner = login
                    self.persist()
                }
                if let idx = self.accounts.firstIndex(where: { $0.login == login }) {
                    self.accounts[idx] = acct
                } else {
                    self.accounts.append(acct)
                }
                self.activeLogin = login
                NetworkLog.shared.log("GitHub 网页登录OK: \(login)")
                self.persist()
                completion(true, "已登录 @\(login)")
            }
        }.resume()
    }

    // MARK: - PAT 登录 / 验证

    /// 用 GitHub PAT 验证并登录/更新账号。OK回调 true + 账号 login。
    func verifyAndLogin(token: String, completion: @escaping (Bool, String?) -> Void) {
        guard !token.isEmpty else {
            lastError = "Token 不能为空"
            completion(false, lastError)
            return
        }
        isVerifying = true
        var req = URLRequest(url: URL(string: "\(apiBase)/user")!, timeoutInterval: 30)
        setHTTPMethod("GET", on: &req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isVerifying = false
                if let err = err {
                    self.lastError = "网络错误: \(err.localizedDescription)"
                    completion(false, self.lastError)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let login = json["login"] as? String else {
                    self.lastError = status == 401 ? "Token 无效或已过期 (请检查 repo + workflow 权限)"
                        : "GitHub 验证failed (HTTP \(status))"
                    completion(false, self.lastError)
                    return
                }
                let name = json["name"] as? String
                let avatar = json["avatar_url"] as? String
                let acct = GitHubAccount(login: login, name: name, avatarURL: avatar, token: token)
                // v2.9.117：全新账号授权OK后，若 Owner 仍是内置默认值 → 自动填入当前登录账号
                let isDefaultOwner = (self.repoOwner == "zrrt" || self.repoOwner == "origina47487lhe-droid")
                if isDefaultOwner && self.repoOwner != login {
                    self.repoOwner = login
                    self.persist()
                }
                if let idx = self.accounts.firstIndex(where: { $0.login == login }) {
                    self.accounts[idx] = acct
                } else {
                    self.accounts.append(acct)
                }
                self.activeLogin = login
                NetworkLog.shared.log("GitHub 账号登录: \(login) (HTTP \(status))")
                self.persist()
                completion(true, login)
            }
        }.resume()
    }

    func switchTo(_ login: String) {
        guard accounts.contains(where: { $0.login == login }) else { return }
        activeLogin = login
        persist()
    }

    func remove(_ login: String) {
        accounts.removeAll { $0.login == login }
        if activeLogin == login {
            activeLogin = accounts.first?.login
        }
        persist()
    }

    /// 手动触发持久化 (仓库设置页保存按钮）
    func persistNow() {
        persist()
    }

    // MARK: - 线上编译 (触发 GitHub Actions）

    func triggerBuild(tweak: String, completion: @escaping (Bool, String?) -> Void) {
        guard let token = activeToken else {
            lastError = "未登录 GitHub 账号"
            completion(false, lastError)
            return
        }
        guard !tweak.isEmpty else {
            lastError = "请填写 tweak 目录名"
            completion(false, lastError)
            return
        }
        isTriggering = true
        var req = URLRequest(url: URL(string: "\(apiBase)/repos/\(repoOwner)/\(repoName)/actions/workflows/\(workflowId)/dispatches")!, timeoutInterval: 60)
        setHTTPMethod("POST", on: &req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // v6.5.9：inputs 仅在 tweak 非空时携带（避免仓库 workflow 未声明 input 时的 422）
        var body: [String: Any] = ["ref": branch]
        let tw = tweak.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tw.isEmpty { body["inputs"] = ["tweak": tw] }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isTriggering = false
                if let err = err {
                    self.lastError = "网络错误: \(err.localizedDescription)"
                    completion(false, self.lastError)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 422, !tw.isEmpty {
                    // 仓库 workflow 未声明 input → 去掉 inputs 再试一次
                    var req2 = URLRequest(url: URL(string: "\(self.apiBase)/repos/\(self.repoOwner)/\(self.repoName)/actions/workflows/\(self.workflowId)/dispatches")!, timeoutInterval: 60)
                    setHTTPMethod("POST", on: &req2)
                    req2.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req2.httpBody = try? JSONSerialization.data(withJSONObject: ["ref": self.branch])
                    URLSession.shared.dataTask(with: req2) { [weak self] _, r2, _ in
                        let st2 = (r2 as? HTTPURLResponse)?.statusCode ?? 0
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            if st2 == 204 {
                                self.lastError = nil
                                completion(true, "已触发（该仓库未声明 tweak input，已按全量构建触发）")
                            } else {
                                self.lastError = "触发失败 HTTP \(st2)（已尝试去掉 inputs 重试；请检查 token 是否含 Actions write 权限）"
                                completion(false, self.lastError)
                            }
                        }
                    }.resume()
                    return
                }
                if status == 204 {
                    NetworkLog.shared.log("触发线上编译 \(self.repoOwner)/\(self.repoName) tweak=\(tweak) (HTTP 204)")
                    self.fetchRuns { _ in }
                    completion(true, "已触发 \(tweak) 编译，稍后刷新状态")
                } else if status == 404 {
                    self.lastError = "workflow '\(self.workflowId)' 不存在 (请确认仓库里有 build-tweak.yml)"
                    completion(false, self.lastError)
                } else if status == 401 {
                    self.lastError = "Token 无 workflow 权限或已过期"
                    completion(false, self.lastError)
                } else {
                    self.lastError = "触发failed (HTTP \(status))"
                    completion(false, self.lastError)
                }
            }
        }.resume()
    }

    func fetchRuns(completion: ((Bool) -> Void)? = nil) {
        guard let token = activeToken else { completion?(false); return }
        var req = URLRequest(url: URL(string: "\(apiBase)/repos/\(repoOwner)/\(repoName)/actions/runs?per_page=10&event=workflow_dispatch")!, timeoutInterval: 30)
        setHTTPMethod("GET", on: &req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self = self else { completion?(false); return }
                if err != nil || data == nil { completion?(false); return }
                guard let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any],
                      let arr = json["workflow_runs"] as? [[String: Any]] else {
                    completion?(false)
                    return
                }
                self.runs = arr.compactMap { d in
                    guard let id = d["id"] as? Int else { return nil }
                    return GitHubRun(
                        id: id,
                        status: d["status"] as? String ?? "unknown",
                        conclusion: d["conclusion"] as? String,
                        createdAt: d["created_at"] as? String ?? "",
                        headBranch: d["head_branch"] as? String ?? "",
                        displayTitle: d["display_title"] as? String ?? "run"
                    )
                }
                completion?(true)
            }
        }.resume()
    }
}
