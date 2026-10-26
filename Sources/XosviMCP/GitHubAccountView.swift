import SwiftUI
import SafariServices
import UIKit

/// GitHub 账号 + 线上编译设置页（v2.9.5）
/// 任何人的 GitHub 账号都可登录/切换，用该账号在云端 Actions 编译 tweak。
/// 注意：仅使用 iOS 14 可用 API。
struct GitHubAccountView: View {
    @StateObject private var store = GitHubAccountStore.shared
    @State private var showAdd = false
    @State private var tweakName = "CompileProbe"
    @State private var busyMessage: String?
    @State private var toast: String?

    var body: some View {
        List {
            currentAccountSection
            savedAccountsSection
            buildSection
            runsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("GitHub 账号")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            AddGitHubAccountView()
        }
        .onAppear {
            store.fetchRuns { _ in }
        }
        .onChange(of: store.lastError) { err in
            if let err = err { toast = err }
        }
        .onChange(of: toast) { msg in
            if msg != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation { toast = nil }
                }
            }
        }
        // busy overlay（iOS14 兼容：无 alignment 参数）
        .overlay(busyOverlay)
        .overlay(bottomToast, alignment: .bottom)
    }

    @ViewBuilder private var currentAccountSection: some View {
        Section(header: SettingSectionHeader(title: "当前账号")) {
            if let acct = store.activeAccount {
                HStack(spacing: 12) {
                    AvatarView(login: acct.login, url: acct.avatarURL)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(acct.name ?? acct.login).font(.headline)
                        Text("@\(acct.login)").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if store.isVerifying {
                        ProgressView().scaleEffect(0.8)
                    }
                }
                .padding(.vertical, 4)
            } else {
                HStack {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundColor(.secondary)
                    Text(L10n.t("ui_98")).foregroundColor(.secondary)
                    Spacer()
                }
            }

            SettingRowButton(
                title: store.activeAccount == nil ? "登录 GitHub 账号" : "添加 / 切换账号",
                subtitle: "使用 Personal Access Token（PAT）",
                icon: "person.badge.plus",
                color: .blue
            ) { showAdd = true }
        }
    }

    @ViewBuilder private var savedAccountsSection: some View {
        if !store.accounts.isEmpty {
            Section(header: SettingSectionHeader(title: "已保存账号（点击切换 · 长按删除）")) {
                ForEach(store.accounts) { acct in
                    accountRow(acct)
                }
            }
        }
    }

    private func accountRow(_ acct: GitHubAccount) -> some View {
        Button {
            store.switchTo(acct.login)
            toast = "已切换为 @\(acct.login)"
        } label: {
            HStack(spacing: 12) {
                AvatarView(login: acct.login, url: acct.avatarURL)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(acct.name ?? acct.login).font(.body)
                    Text("@\(acct.login)").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if store.activeLogin == acct.login {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                } else {
                    Image(systemName: "person.circle").foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button {
                store.remove(acct.login)
                toast = "已删除 @\(acct.login)"
            } label: {
                Label("删除账号", systemImage: "trash")
            }
        }
    }

    @ViewBuilder private var buildSection: some View {
        Section(header: SettingSectionHeader(title: "线上编译（GitHub Actions）")) {
            TextField("tweak 目录名（如 CompileProbe）", text: $tweakName)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .font(.system(.body, design: .monospaced))

            SettingRowButton(
                title: "触发线上编译",
                subtitle: store.activeAccount == nil ? "请先登录账号" : "\(store.repoOwner)/\(store.repoName) · workflow=\(store.workflowId)",
                icon: "hammer.fill",
                color: .orange
            ) {
                guard store.activeAccount != nil else {
                    toast = "请先登录 GitHub 账号"; return
                }
                busyMessage = "正在触发 \(tweakName) 编译…"
                store.triggerBuild(tweak: tweakName) { ok, msg in
                    busyMessage = nil
                    toast = ok ? msg : (msg ?? "触发失败")
                    if ok { store.fetchRuns { _ in } }
                }
            }
            .disabled(store.activeAccount == nil || store.isTriggering)

            if store.isTriggering {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text(L10n.t("ui_130")).font(.caption).foregroundColor(.secondary)
                }
            }

            NavigationLink(destination: GitHubRepoSettingsView()) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.blue)
                            .frame(width: 34, height: 34)
                        Image(systemName: "server.rack")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("ui_23")).font(.body)
                        Text("\(store.repoOwner)/\(store.repoName) · \(store.workflowId) · \(store.branch)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var runsSection: some View {
        Section(header: SettingSectionHeader(title: "最近编译记录")) {
            if store.runs.isEmpty {
                HStack {
                    Text(L10n.t("ui_92")).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("刷新") {
                        store.fetchRuns { _ in }
                    }
                    .font(.caption)
                }
            } else {
                ForEach(store.runs) { run in
                    HStack {
                        Text(run.statusText).font(.body)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(run.displayTitle).font(.caption).lineLimit(1)
                            Text("#\(run.id) · \(shortTime(run.createdAt))").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                Button("刷新状态") {
                    store.fetchRuns { _ in }
                }
                .font(.footnote)
                .foregroundColor(.blue)
            }
        }
    }

    @ViewBuilder private var busyOverlay: some View {
        if let msg = busyMessage {
            VStack(spacing: 10) {
                ProgressView()
                Text(msg).font(.caption).foregroundColor(.secondary)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground).opacity(0.95)))
            .shadow(radius: 8)
        }
    }

    @ViewBuilder private var bottomToast: some View {
        if let msg = toast {
            Text(msg)
                .font(.footnote)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color(.systemGray5)))
                .padding(.bottom, 8)
        }
    }

    private func shortTime(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: d)
    }
}

// MARK: - 头像（首字母兜底，避免额外网络图片依赖）

struct AvatarView: View {
    let login: String
    let url: String?

    var body: some View {
        ZStack {
            Circle().fill(avatarColor(login))
            Text(String(login.prefix(1)).uppercased())
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private func avatarColor(_ s: String) -> Color {
        let hue = Double(abs(s.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }
}

// MARK: - 添加账号（PAT 登录）

struct AddGitHubAccountView: View {
    // v6.9.7：改用 @Environment(\.dismiss)。旧的 presentationMode 在本视图既被 sheet
    // 弹出、内部又弹出 Safari sheet 的双层呈现下语义混乱，导致登录完成后关不掉本页。
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = GitHubAccountStore.shared
    @State private var token = ""
    @State private var errorMsg: String?
    @State private var loading = false
    // Device Flow 状态
    @State private var deviceCode: GitHubAccountStore.DeviceCode?
    @State private var deviceStep = 0        // 0 未开始 / 1 等待授权 / 2 完成
    @State private var safariURL: URL?
    @State private var showSafari = false
    @State private var copied = false   // 验证码已自动复制

    var body: some View {
        // v6.9.7：本视图由 .sheet 弹出，内容必须自带 NavigationView，
        // 否则 .navigationTitle / .toolbar 不生效（"手动登录"按钮看不见，"返回"也没有）。
        NavigationView {
            Form {
                webLoginSection
                patLoginSection
            }
            .navigationTitle("登录 GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // v6.9.7：补"取消"出口。本页由 sheet 弹出，没有导航返回按钮，
                // 旧实现只能靠下滑手势退出——授权页卡住时用户会以为无法返回。
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if loading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("手动登录") {
                            login()
                        }
                        .disabled(token.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showSafari, onDismiss: {
                // v6.9.7：任何关闭路径（完成按钮/下滑手势/授权成功）都复位状态，
                // 否则下次点"打开授权页"因 showSafari 已 true 而无反应。
                safariURL = nil
                // v6.6.19：用户从授权页返回 = 大概率刚点完 Authorize。
                // 旧实现只关页面不校验，得等下一次轮询（最长 interval 5s，
                // 网络抖动时还会一直静默重试）——体感就是"登录后永远回不来"。
                if store.isDevicePolling { store.checkNow() }
            }) {
                if let url = safariURL {
                    // v6.9.11：去掉 .ignoresSafeArea()——它会把 SFSafariViewController
                    // 自带的"完成/关闭"按钮顶到安全区外，用户看不到返回入口，
                    // 表现为"授权后无法返回"。改为标准内嵌，保留系统关闭按钮。
                    SafariWebView(url: url) {
                        showSafari = false
                    }
                } else {
                    // 兜底：safariURL 为空时给一个可关闭的提示，而不是弹空白页
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("授权链接无效")
                            .font(.headline)
                        Text("请返回后重新点击「在浏览器中登录」")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Button("关闭") { showSafari = false }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
            .onChange(of: store.activeAccount?.login) { _ in
                // v2.9.110：兜底——轮询成功落库（activeAccount 变化）时若还停在等待页，补一次成功反馈
                if deviceStep == 1, store.activeAccount != nil {
                    deviceStep = 2
                    showSafari = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder private var webLoginSection: some View {
        Section(header: SettingSectionHeader(title: "网页登录（推荐）"),
                footer: Text(L10n.t("ui_142"))) {
            if deviceStep == 0 {
                SettingRowButton(
                    title: "在浏览器中登录",
                    subtitle: store.clientID.isEmpty ? "✅ 使用内置默认 Client ID（可直接登录）" : "Client ID: \(store.clientID)",
                    icon: "safari.fill",
                    color: .black
                ) {
                    startDeviceFlow()
                }
            } else if deviceStep == 1, let dc = deviceCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("ui_71")).font(.footnote).foregroundColor(.secondary)
                    HStack {
                        Text(dc.user_code)
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                        Spacer()
                        Button(action: { copyCode(dc.user_code) }) {
                            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                .foregroundColor(copied ? .green : .blue)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    Text(L10n.t("ui_43"))
                        .font(.caption).foregroundColor(.secondary)
                    SettingRowButton(
                        title: "再次打开授权页",
                        subtitle: dc.verification_uri,
                        icon: "safari",
                        color: .blue
                    ) {
                        openVerification(dc.verification_uri)
                    }
                    if store.isDevicePolling {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text(L10n.t("ui_120")).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    // v6.4.3：已授权却一直等不到结果时（自动轮询因网络抖动静默重试），
                    // 提供手动立即检查 + 把真实原因显示出来。
                    SettingRowButton(
                        title: "我已授权 · 立即检查",
                        subtitle: "网页上已点 Authorize 后用它直接确认",
                        icon: "checkmark.shield",
                        color: .green
                    ) {
                        store.checkNow()
                    }
                    if let st = store.deviceFlowState, !st.isEmpty, st.contains("失败") || st.contains("确认") {
                        Text(st).font(.caption).foregroundColor(.orange)
                    }
                    // v6.6.19：把最近一次真实错误显示出来。
                    // 旧界面只在 deviceFlowState 含"失败/确认"时显示，而
                    // finishLoginWith 失败（如 api.github.com 被墙、HTTP 403）
                    // 只写 lastError，用户看到的就是"一直转圈、没有原因"。
                    if let err = store.lastError, !err.isEmpty {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                    if let err = store.lastError, err.contains("device_flow_disabled") || err.contains("incorrect_client_credentials") {
                        Text("该 OAuth App 未开启 Device Flow。请在下方改用 Personal Access Token 登录。")
                            .font(.caption).foregroundColor(.orange)
                    }
                    // v6.9.11：授权页关不掉时的逃生口——停止轮询并回到上一步
                    if store.isDevicePolling {
                        Button {
                            store.cancelDevicePolling()
                            showSafari = false
                            deviceStep = 0
                            deviceCode = nil
                        } label: {
                            Label("取消等待，返回上一步", systemImage: "arrow.uturn.backward")
                        }
                        .foregroundColor(.secondary)
                    }
                }
            } else {
                Text(L10n.t("ui_113")).font(.footnote).foregroundColor(.green)
            }
        }
    }

    @ViewBuilder private var patLoginSection: some View {
        Section(header: SettingSectionHeader(title: "手动 Token（备选）"),
                footer: Text(L10n.t("ui_10"))) {
            SecureField("ghp_…", text: $token)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if let err = errorMsg {
                Text(err).font(.caption).foregroundColor(.red)
            }
        }
    }

    // MARK: - Device Flow

    private func startDeviceFlow() {
        errorMsg = nil
        deviceStep = 0
        store.startDeviceFlow { code, err in
            if let code = code {
                self.deviceCode = code
                self.deviceStep = 1
                // 自动复制验证码到剪贴板（GitHub 授权页可自动识别/粘贴，gh CLI 同款）
                UIPasteboard.general.string = code.user_code
                self.copied = true
                // 自动开始轮询 + 打开授权页
                self.openVerification(code.verification_uri)
                store.pollDeviceToken(deviceCode: code) { ok, msg in
                    if ok {
                        // v2.9.110：授权成功必须反馈——显示成功、自动关浏览器、返回账号页
                        deviceStep = 2
                        showSafari = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            dismiss()
                        }
                    } else {
                        errorMsg = msg ?? "授权失败"
                        deviceStep = 0
                        showSafari = false   // 失败也自动关掉浏览器
                    }
                }
            } else {
                errorMsg = err ?? "设备码获取失败"
            }
        }
    }

    private func copyCode(_ code: String) {
        UIPasteboard.general.string = code
        copied = true
    }

    private func openVerification(_ uri: String) {
        if let url = URL(string: uri) {
            safariURL = url
            showSafari = true
        }
    }

    private func login() {
        loading = true
        errorMsg = nil
        store.verifyAndLogin(token: token.trimmingCharacters(in: .whitespacesAndNewlines)) { ok, msg in
            loading = false
            if ok {
                dismiss()
            } else {
                errorMsg = msg
            }
        }
    }
}

// MARK: - 内置 Safari（Device Flow 授权页）

/// v6.9.7：修复"登录验证页打不开/回不来"。
/// 旧实现有三个问题：
///   1. SFSafariViewController 未设 delegate —— 用户点"完成"后 SwiftUI 完全不知情，
///      showSafari 永远停在 true，再次点"打开授权页"无反应（sheet 已在却没变化）。
///   2. sheet 内容为空时（safariURL 为 nil）会弹一个空白页，看起来就是"无法返回"。
///   3. 授权页在 sheet 内，没有"取消"出口，用户只能靠系统手势，容易被误认为卡死。
struct SafariWebView: UIViewControllerRepresentable {
    let url: URL
    /// 用户点了"完成"/"取消"时回调，用来复位 showSafari
    var onDismiss: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.delegate = context.coordinator
        // 授权页需要输入验证码，读 cookie/站点数据用于 GitHub 已登录态复用
        vc.dismissButtonStyle = .close
        vc.preferredControlTintColor = .systemBlue
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // 不需要在这里重新加载：SwiftUI 在 url 变化时会重建 SafariWebView
        // （sheet 内容按 id 刷新），手工 loadViewIfNeeded 反而可能把用户
        // 正在浏览的授权页重置掉。
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDismiss: (() -> Void)?
        init(onDismiss: (() -> Void)?) { self.onDismiss = onDismiss }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDismiss?()
        }
    }
}

// MARK: - 仓库与 workflow 设置

struct GitHubRepoSettingsView: View {
    @StateObject private var store = GitHubAccountStore.shared
    @State private var saved = false

    var body: some View {
        Form {
            Section(header: SettingSectionHeader(title: "OAuth App（网页登录用）"),
                    footer: Text(L10n.t("ui_53"))) {
                TextField("OAuth App Client ID", text: $store.clientID)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))
                Button("恢复默认 Client ID（清空自定义值）") {
                    store.restoreDefaultClientID()
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        saved = false
                    }
                }
            }

            Section(header: SettingSectionHeader(title: "目标仓库"),
                    footer: Text(L10n.t("ui_122"))) {
                TextField("仓库 Owner（用户名）", text: $store.repoOwner)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("仓库名", text: $store.repoName)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("workflow 文件名", text: $store.workflowId)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("分支", text: $store.branch)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            Section {
                Button("保存") {
                    store.persistNow()
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        saved = false
                    }
                }
                if saved {
                    Text(store.clientID.isEmpty ? "已保存 ✓ 已恢复内置默认 Client ID，可直接登录" : "已保存 ✓")
                        .font(.footnote).foregroundColor(.green)
                }
            }
        }
        .navigationTitle("仓库设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
