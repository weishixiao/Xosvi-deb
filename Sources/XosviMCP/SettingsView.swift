import SwiftUI
import UIKit

// MARK: - 设置项数据（列表/卡片双视图共用，永不脱节）

struct SettingsItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    var destination: AnyView?
    var action: (() -> Void)?
    var isOn: (() -> Bool)?
    var onToggle: ((Bool) -> Void)?
    /// v4.3.39：行尾红点（新版提醒等），闭包返回是否显示
    var redDot: (() -> Bool)?
}

struct SettingsGroup {
    let header: String
    var items: [SettingsItem]
}

struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    // v2.9.72：开发者模式开关，开启后显示高级选项
    // v6.0.28：默认开启，去掉开关UI
    @AppStorage("developer_mode") private var developerMode = true
    // v2.9.76：语言选择弹窗
    @State private var showLanguagePicker = false
    // v2.9.84：聊天框「在设置中管理模型」→ 打开设置并自动跳到模型 API 页
    @State private var jumpToModels = false
    // v4.4.16：底部"指令"胶囊 → 打开设置并自动跳到系统指令(SystemPromptsView)页
    @State private var jumpToSystemPrompts = false
    // v3.3.2：抓包 VPN 开关失败提示
    @State private var vpnToggleError = ""
    // v4.3.29：订阅更新管理器，副标题实时显示 检查中/下载进度/发现新版本
    @ObservedObject private var updateManager = UpdateManager.shared
    // v4.3.30：更新镜像源编辑器
    @State private var showMirrorEditor = false
    @State private var mirrorsText = ""
    // v6.2.1：重置所有数据确认弹窗
    @State private var showResetAlert = false

    var body: some View {
        // v2.9.247：GeometryReader 拿真实全屏尺寸——fullScreenCover+NavigationStack 组合下 List 高度被解析为内容高度(内容不满一屏时列表只占上半屏、下半空白),外层 frame 也无效;改用几何尺寸显式强制 List 与 NavigationStack 铺满全屏,所有机型一致
        GeometryReader { geo in
            CompatNav {
                listBody
                    .frame(minHeight: geo.size.height)
                    .navigationTitle(L10n.t("settings"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        // v2.9.241：全屏设置页左上角"完成"=关闭设置回聊天
                        Button(action: { presentationMode.wrappedValue.dismiss() }) {
                            Text(L10n.t("done"))
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                    // v2.9.245：移除右上角卡片/列表切换按钮——卡片模式在部分机型(iPhone XS等小屏)渲染不稳定(图标/文字显示不全/内容裁剪),统一为列表模式
                }
                // v2.9.234：跳转模型API页——iOS16 navigationDestination(修被弹回), iOS15 NavigationLink兜底
                // v4.4.16：追加"跳系统指令"跳转(底部"指令"胶囊)——与模型跳转对称的 iOS16/iOS15 双兜底
                .background(
                    Group {
                        if #available(iOS 16.0, *) {
                            EmptyView()
                        } else {
                            NavigationLink(destination: LiteLLMGatewayView(), isActive: $jumpToModels) { EmptyView() }.hidden()
                            NavigationLink(destination: SystemPromptsView(), isActive: $jumpToSystemPrompts) { EmptyView() }.hidden()
                        }
                    }
                )
            if #available(iOS 16.0, *) {
                Color.clear.navigationDestination(isPresented: $jumpToModels) { LiteLLMGatewayView() }
                Color.clear.navigationDestination(isPresented: $jumpToSystemPrompts) { SystemPromptsView() }
            }
        }
            .frame(width: geo.size.width, height: geo.size.height)   // NavigationStack 显式全屏
        }
        .navigationViewStyle(.stack)
        .onAppear {
            triggerProbe()   // v2.9.18：进入设置页自动探测一次，更新环境状态色
        }
        .onAppear {
            if AppUIState.shared.settingsJumpToModels {
                AppUIState.shared.settingsJumpToModels = false
                jumpToModels = true
            }
            // v4.4.16：底部"指令"胶囊 → 跳到系统指令页
            // v4.4.21：延迟一帧触发——iOS16 navigationDestination(isPresented:) 在设置页首帧出现时目标未注册,
            // 立即设 true 会被 SwiftUI 吞掉不跳(用户实测'点指令没真正跳到系统指令页'); 延迟到下一帧目标注册后再跳
            if AppUIState.shared.settingsJumpToSystemPrompts {
                AppUIState.shared.settingsJumpToSystemPrompts = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    jumpToSystemPrompts = true
                }
            }
        }
    }

    // MARK: - 数据源（两种视图共用）

    private func makeGroups() -> [SettingsGroup] {
        var groups: [SettingsGroup] = []

        // 模型
        groups.append(SettingsGroup(header: L10n.t("sec_models"), items: [
            // v7.6.3：模型入口换成 LiteLLM 风格网关（模型组 / 路由策略 / 虚拟密钥）
            SettingsItem(title: L10n.t("row_model_api"),
                         subtitle: "\(LiteLLMStore.shared.groups.count) 组 · \(LiteLLMStore.shared.entries.count) 部署",
                         icon: "rectangle.stack.badge.person.crop", color: .blue,
                         destination: AnyView(LiteLLMGatewayView())),
            // v6.9.10：删除"系统指令"设置入口——模式已由 AI 自动路由（见 SystemPrompts.routerPrompt）。
            // 仅移除入口，SystemPromptsView / 7 个模式的提示词内容全部保留，
            // 需要恢复时把本段加回即可。
            SettingsItem(title: L10n.t("row_dev_instructions"),
                         subtitle: devInstructionsSubtitle(),
                         icon: "doc.text.magnifyingglass", color: .orange,
                         destination: AnyView(DeveloperInstructionsView()))
        ]))

        // 网络与抓包（v3.3.1：独立分组，不依赖开发者模式——普通用户也能直接看到抓包入口）
        groups.append(SettingsGroup(header: "网络与抓包", items: [
            // v3.3.2：开关 + 点击进详情（Toggle 一键开/关，NavigationLink 进详情页）
            SettingsItem(title: "抓包 VPN",
                         subtitle: vpnActiveSubtitle(),
                         icon: "antenna.radiowaves.left.and.right", color: .tmCyan,
                         destination: AnyView(VpnCaptureView()),
                         isOn: { VpnManager.shared.vpnActive },
                         onToggle: { on in
                             VpnManager.shared.toggleVpn { err in
                                 if let e = err {
                                     DispatchQueue.main.async {
                                         vpnToggleError = e
                                     }
                                 }
                             }
                         }),
            SettingsItem(title: L10n.t("row_netlog"),
                         subtitle: NetworkLog.lastCompatNote ?? "中转站自适应降级记录",
                         icon: "network", color: .orange,
                         destination: AnyView(NetworkDebugView()))
        ]))

        // v7.6.5：线上编译 / GitHub 账号 / 下载管理已按用户要求整体移除

        // 环境（v6.6.19：环境变量）
        groups.append(SettingsGroup(header: "环境", items: [
            SettingsItem(title: "环境变量",
                         subtitle: "注入子进程与进程内 Python · \(EnvVars.current().count) 项",
                         icon: "key.fill", color: .gray,
                         destination: AnyView(EnvVarsView()))
        ]))

        // v7.10.0：远程控制 + AI 控制中心已按用户要求整块删除（含源码）
        // 开发者（v6.0.28：默认开启，去掉开关）
        var devItems: [SettingsItem] = [
                // v4.3.53：图标主题功能彻底移除（含 Resources 残留图标文件）。
                // 侧载环境下动态图标注册可能干扰 MobileIcons 图标缓存（分享面板崩溃嫌疑项）。
                SettingsItem(title: L10n.t("row_device_fake"),
                             subtitle: "伪装机型 · 注入生效",
                             icon: "iphone.gen3.radiowaves.left.and.right", color: .pink,
                             destination: AnyView(FakeDeviceView())),
                SettingsItem(title: L10n.t("row_tool_policy"),
                             subtitle: "工具权限 · 系统权限 · 自动化",
                             icon: "lock.shield.fill", color: .green,
                             destination: AnyView(ToolPermissionPoliciesView())),
                SettingsItem(title: L10n.t("row_transcripts"),
                             subtitle: "完整对话存档",
                             icon: "text.book.closed.fill", color: .tmBrown,
                             destination: AnyView(ConversationTranscriptView())),
                SettingsItem(title: "远程访问",
                             subtitle: "SSH 连接远程服务器 · 远程终端被控制",
                             icon: "terminal.fill", color: .teal,
                             destination: AnyView(RemoteAccessView())),
                // v7.14.0：jb-p1lot——越狱设备直控桥（宿主二进制 / 配对 / 发现）
                SettingsItem(title: "构建与注入",
                             subtitle: "jb-p1lot · 越狱设备配对 · tweak 闭环",
                             icon: "point.3.connected.trianglepath.dotted", color: .gray,
                             destination: AnyView(JBPlotSettingsView())),
                // v7.5.0：内置浏览器已删除；改为「联网搜索」（多服务商 + 全文读取）
                SettingsItem(title: "联网搜索",
                             subtitle: "服务商 / API Key / 自动读全文",
                             icon: "magnifyingglass", color: .gray,
                             destination: AnyView(WebSearchSettingsView())),
                // v7.11.0：控制台——把 control 的 10 个子命令做成可点操作
                SettingsItem(title: "控制台",
                             subtitle: "注入 · UI 树 · 截图 · 点按 · 滑动 · 输入 · 按键",
                             icon: "slider.horizontal.3", color: .gray,
                             destination: AnyView(ControlConsoleView())),
                // v7.10.0：技能回放（移植 ghost-in-the-droid 的 skills 思路）
                SettingsItem(title: "技能回放",
                             subtitle: "已知流程零 token 重放 · 界面扫描",
                             icon: "play.circle", color: .gray,
                             destination: AnyView(GhostSkillsView())),
                // v7.8.0：深度思考（方言 / 采样策略 / 回传 / token 预算）
                SettingsItem(title: "深度思考",
                             subtitle: "参数方言 · 采样策略 · token 预算",
                             icon: "brain", color: .gray,
                             destination: AnyView(ReasoningSettingsView())),
                // v7.6.0：环境（移植 Kelivo 的 Environment 页：环境预设 / 镜像 / 挂载 / 修复）
                SettingsItem(title: "环境",
                             subtitle: "Python · Node · Git · 镜像 · 挂载",
                             icon: "cube.box", color: .gray,
                             destination: AnyView(EnvironmentView())),
                // v7.5.0：工作区（移植 Kelivo workspace）
                SettingsItem(title: "工作区",
                             subtitle: "绑定目录 · 命令执行 · 文件读写",
                             icon: "folder", color: .gray,
                             destination: AnyView(WorkspaceSettingsView())),
                SettingsItem(title: L10n.t("row_agents"),
                             subtitle: "隔离指令 · 工作流",
                             icon: "person.3.fill", color: .indigo,
                             destination: AnyView(AgentsAndSkillsView())),
                SettingsItem(title: L10n.t("row_kb"),
                             subtitle: "文件导入 · 来源检索",
                             icon: "books.vertical.fill", color: .brown,
                             destination: AnyView(KnowledgeBaseView()))
            ]
            groups.append(SettingsGroup(header: "工具与管理", items: devItems))

        // 安全
        groups.append(SettingsGroup(header: L10n.t("sec_security"), items: [
            SettingsItem(title: L10n.t("row_audit"),
                         subtitle: "工具调用 · 成功/失败 · 导出给 AI 查看",
                         icon: "list.bullet.rectangle", color: .tmIndigo,
                         destination: AnyView(AuditLogView())),
            // v7.3.0：Alpine/iSH 引擎整体移除，「引擎开关」这一项也一并删除
            // v7.3.0：本项已从设置里删除——该行为恒为开启（见 SearchAlwaysOn 同款的做法），
            // 由 AI 自行判断何时需要引擎，用户无需干预。
            SettingsItem(title: "重置所有数据",
                         subtitle: "清空配置 · 会话 · 工作区 · Keychain（恢复到全新安装）",
                         icon: "arrow.counterclockwise.circle.fill", color: .red,
                         action: { showResetAlert = true }),
            SettingsItem(title: L10n.t("row_workspace"),
                         subtitle: "点开浏览目录 · 预览 · 复制路径 · 分享",
                         icon: "folder", color: .blue,
                         destination: AnyView(WorkspaceBrowserView())),
            // v7.4.1：清理中心（含系统清理 / App 清理）整块删除（用户要求）
            // v6.9.15：Coruna 安全盾 / Web 注入已按用户要求删除
        ]))

        // 关于
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        var aboutItems: [SettingsItem] = [
            SettingsItem(title: L10n.t("about_title"),
                         subtitle: "开源致谢 · 安全说明 · 免责声明",
                         icon: "person.crop.circle.fill", color: .blue,
                         destination: AnyView(AboutAuthorView())),
            SettingsItem(title: L10n.t("row_lang"),
                         subtitle: LanguageManager.shared.language.displayName,
                         icon: "globe", color: .purple,
                         action: { showLanguagePicker = true }),
            // v4.3.29：一键更新——单行点击即进入更新页面（里面包含检查更新和镜像源设置）
            // v4.3.39：发现新版时行尾显示红点提醒
            SettingsItem(title: L10n.t("row_check_update"),
                         subtitle: updateSubtitle(),
                         icon: "arrow.triangle.2.circlepath.circle.fill", color: .green,
                         destination: AnyView(UpdateView()),
                         redDot: { UpdateManager.shared.hasUpdateRedDot }),
            SettingsItem(title: L10n.t("version"),
                         subtitle: ver, icon: "number.circle.fill", color: .gray,
                         destination: nil)
        ]
        groups.append(SettingsGroup(header: L10n.t("sec_about"), items: aboutItems))

        return groups
    }

    // MARK: - 列表模式

    // v4.3.64：已移除 testShareSheet（系统分享面板在本设备侧载环境必崩，无诊断价值）

    private var listBody: some View {
        List {
            // v4.3.64：移除"测试系统分享面板（Debug）"——本设备侧载环境任何系统分享面板
            // 都崩（MobileIcons/CoreImage SIGSEGV，v4.3.43-63 全部真机证伪），
            // 该按钮只会闪退，无诊断价值。分享统一走 ShareCenter 自建菜单（存储到文件/拷贝）。
            ForEach(makeGroups(), id: \.header) { group in
                Section(header: SettingSectionHeader(title: group.header)) {
                    ForEach(group.items) { item in
                        listRow(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .deepseekList()
        .actionSheet(isPresented: $showLanguagePicker) {
            ActionSheet(
                title: Text(L10n.t("row_lang")),
                buttons: AppLanguage.allCases.map { lang in
                    .default(Text(lang.displayName)) {
                        LanguageManager.shared.language = lang
                    }
                } + [.cancel(Text(L10n.t("cancel")))]
            )
        }
        .alert("抓包 VPN", isPresented: Binding(
            get: { !vpnToggleError.isEmpty },
            set: { if !$0 { vpnToggleError = "" } }
        )) {
            Button("好", role: .cancel) { vpnToggleError = "" }
        } message: {
            Text(vpnToggleError)
        }
        // v6.2.1：重置所有数据——清空 UserDefaults 域 + Workspace + Keychain + 崩溃日志
        .alert("重置所有数据", isPresented: $showResetAlert) {
            Button("取消", role: .cancel) {}
            Button("确认重置", role: .destructive) {
                resetAllData()
            }
        } message: {
            Text("将清空：模型配置、API Key、会话记录、工作区文件、知识库。此操作不可撤销！")
        }
        // v4.3.30：更新镜像源编辑（GitHub 被墙时的备用通道，每行一个前缀，逗号分隔）
        .sheet(isPresented: $showMirrorEditor) {
            NavigationView {
                Form {
                    Section(footer: Text("GitHub 被墙（国内常见）时，自动按顺序尝试这些镜像前缀来检查与下载更新。每行一个，用逗号分隔；留空恢复默认（ghfast.top、gh-proxy.com）。")) {
                        TextEditor(text: $mirrorsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 110)
                    }
                }
                .navigationTitle("更新镜像源")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showMirrorEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            UpdateManager.shared.saveMirrors(mirrorsText)
                            showMirrorEditor = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func listRow(_ item: SettingsItem) -> some View {
        // 开关优先：Toggle 项同时带 destination 时用 NavigationLink 包 Toggle（如抓包 VPN 开关）
        if let isOn = item.isOn, let onToggle = item.onToggle {
            let toggle = Toggle(isOn: Binding(get: isOn, set: onToggle)) {
                SettingRowContent(item: item)
            }
            .accentColor(.primary)   // v7.1.1：开关也走黑白，不再用青色
            if let dest = item.destination {
                NavigationLink(destination: dest) { toggle }
            } else {
                toggle
            }
        } else if let dest = item.destination {
            NavigationLink(destination: dest) {
                SettingRowContent(item: item)
            }
        } else if let action = item.action {
            Button(action: action) {
                SettingRowContent(item: item)
            }
        } else {
            SettingRowContent(item: item)
        }
    }

    // MARK: - 动态值

    @State private var lastProbe: DeviceProbe.Report?

    private func envSubtitle() -> String {
        if let r = lastProbe {
            let failed = r.checks.filter { !$0.passed }.count
            return r.ready ? "就绪 · 可注入" : "需检查 \(failed) 项"
        }
        return "点击探测"
    }

    private func envIcon() -> String {
        if let r = lastProbe {
            return r.ready ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
        }
        return "shield.lefthalf.filled"
    }

    private func envColor() -> Color {
        if let r = lastProbe {
            return r.ready ? .green : .red
        }
        return .gray
    }

    // v2.9.144：探测含 spawnRoot/文件遍历，主线程同步会卡死被看门狗杀（表现为闪退）
    private func triggerProbe() {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = DeviceProbe.shared.run()
            DispatchQueue.main.async {
                self.lastProbe = r
            }
        }
    }

    private func modelProviderName() -> String {
        ModelStore.shared.configs.first(where: { $0.isDefault })?.provider ?? ModelStore.shared.configs.first?.provider ?? "未配置"
    }

    private func permissionCount() -> Int {
        7
    }

    private func devInstructionsSubtitle() -> String {
        let count = DeveloperInstructionStore.shared.list().count
        return "\(count) 条 · 长按设默认"
    }

    private func sshConfigSubtitle() -> String {
        let host = UserDefaults.standard.string(forKey: "ssh.host") ?? ""
        return host.isEmpty ? "未配置" : host
    }

    // v4.3.29：副标题实时反映更新状态（检查中/下载进度/发现新版本/错误/已是最新）
    // v4.3.30：已是最新时附带检查源（GitHub / jsDelivr / 镜像）
    private func updateSubtitle() -> String {
        let m = updateManager
        if m.isChecking {
            return "正在检查 GitHub 最新构建…"
        }
        if m.isDownloading {
            let pct = Int(m.downloadProgress * 100)
            return "正在下载 v\(m.latestVersion ?? "")… \(pct)%"
        }
        if m.updateAvailable, let v = m.latestVersion {
            return "发现新版本 v\(v) · 点此一键更新安装"
        }
        if let s = m.installMessage, !s.isEmpty {
            return s
        }
        if let e = m.errorMessage, !e.isEmpty {
            return e
        }
        if let s = m.lastSource {
            return "已是最新 · 检查源: \(s)"
        }
        return "已是最新"
    }

    // v4.3.30：镜像源副标题（显示当前生效的镜像，去协议前缀）
    private func mirrorSubtitle() -> String {
        let list = UpdateManager.shared.mirrors
            .map { $0.replacingOccurrences(of: "https://", with: "")
                      .replacingOccurrences(of: "http://", with: "")
                      .replacingOccurrences(of: "/", with: "") }
        return "GitHub 被墙时备用 · " + list.joined(separator: ", ")
    }

    // v3.3.2：抓包 VPN 开关副标题
    private func vpnActiveSubtitle() -> String {
        VpnManager.shared.vpnActive ? "运行中 · 点击右侧开关关闭" : "未运行 · 点击右侧开关开启"
    }

    /// v6.2.1：重置所有数据——恢复"全新安装"状态。
    /// 覆盖安装 (TrollStore 导入 tipa) 时 iOS 保留沙盒数据是标准行为，
    /// 用户若要彻底清空，从这里一键执行。清空范围：
    /// UserDefaults 域 / Workspace 目录(会话·知识库·项目·崩溃日志) / Keychain 全部项。
    private func resetAllData() {
        // 1. UserDefaults 本 App 域
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        UserDefaults.standard.synchronize()

        // 2. Workspace 目录（会话 conversations.json / 知识库 / 项目 / 崩溃日志 / shell-diag）
        try? FileManager.default.removeItem(at: Workspace.root)

        // 3. Keychain 全部项（本 App service 下的 token/apiKey）
        KeychainStore.shared.clearAll()

        // 4. 提示用户重启 App 让所有单例重建（数据已清空，内存中旧状态仅本次会话残留）
        let alert = UIAlertController(title: "已重置", message: "所有数据已清空。请完全退出 App 后重新打开，以加载全新状态。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in
            DispatchQueue.main.async {
                presentationMode.wrappedValue.dismiss()
            }
        })
        if let vc = ShareCenter.topViewController(), let view = vc.view {
            alert.popoverPresentationController?.sourceView = view
            alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY, width: 1, height: 1)
            vc.present(alert, animated: true)
        }
    }
}

/// 行内容（列表/卡片共用视觉）
struct SettingRowContent: View {
    let item: SettingsItem

    /// v7.1.1：DeepSeek 的设置项是纯线条图标、没有底板；原来的 xxx.fill 在这里会变成一坨黑块，
    /// 所以统一去掉 .fill 落到同名线条版。
    private var lineIcon: String {
        let raw = item.icon
        guard raw.hasSuffix(".fill") else { return raw }
        return String(raw.dropLast(5))
    }

    var body: some View {
        // v7.1.1（DeepSeek 风格）：彩色方块 + 白色重图标 → 黑白简洁版（裸线条图标）
        HStack(spacing: 12) {
            Image(systemName: lineIcon)
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(.primary)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                // v7.3.0：只保留主设置名，副标题说明小字不再显示（用户要求）
            }
            Spacer(minLength: 0)
            // v4.3.39：行尾红点提醒（新版更新等）——红点在行尾右侧，点击行即处理
            if let redDot = item.redDot, redDot() {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
            }
        }
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.system(.footnote, design: .monospaced))
        }
    }
}

// v6.0.28：更新页面（包含检查更新和更新镜像源设置）
struct UpdateView: View {
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var showMirrorEditor = false
    @State private var mirrorsText = ""
    
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
    
    private var updateSubtitle: String {
        if updateManager.isChecking { return "正在检查更新…" }
        if updateManager.downloadProgress > 0 { return "正在下载 v\(updateManager.latestVersion ?? "")… \(Int(updateManager.downloadProgress*100))%" }
        if updateManager.updateAvailable, let v = updateManager.latestVersion {
            return "发现新版本 v\(v) · 点下方按钮更新"
        }
        if let s = updateManager.installMessage, !s.isEmpty { return s }
        return "已是最新版本"
    }
    
    var body: some View {
        List {
            Section(header: Text("更新状态")) {
                HStack {
                    Text("当前版本")
                    Spacer()
                    Text(currentVersion)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("状态")
                    Spacer()
                    Text(updateSubtitle)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Button(action: { updateManager.updateNow(currentVersion: currentVersion) }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("立即检查更新")
                    }
                }
            }
            
            Section(header: Text("高级设置"), footer: Text("GitHub 被墙（国内常见）时，自动按顺序尝试这些镜像前缀来检查与下载更新。每行一个，用逗号分隔；留空恢复默认（ghfast.top、gh-proxy.com）。")) {
                Button(action: {
                    mirrorsText = UpdateManager.shared.mirrorsText
                    showMirrorEditor = true
                }) {
                    HStack {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundColor(.orange)
                        Text("更新镜像源")
                        Spacer()
                        Text(mirrorHost())
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("检查更新")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMirrorEditor) {
            NavigationView {
                Form {
                    Section(footer: Text("GitHub 被墙（国内常见）时，自动按顺序尝试这些镜像前缀来检查与下载更新。每行一个，用逗号分隔；留空恢复默认（ghfast.top、gh-proxy.com）。")) {
                        TextEditor(text: $mirrorsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 110)
                    }
                }
                .navigationTitle("更新镜像源")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showMirrorEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            UpdateManager.shared.saveMirrors(mirrorsText)
                            showMirrorEditor = false
                        }
                    }
                }
            }
        }
    }
    
    private func mirrorHost() -> String {
        let m = UpdateManager.shared.mirrorsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.isEmpty { return "默认（ghfast.top）" }
        let first = m.components(separatedBy: [",", "\n"]).first(where: { !$0.isEmpty }) ?? ""
        return first.isEmpty ? "默认" : first
    }
}

// v2.9.68：SSH 远程连接设置
struct SSHSettingsView: View {
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var user: String = ""
    @State private var password: String = ""
    @State private var keyPath: String = ""
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        Form {
            Section(header: Text(L10n.t("ui_137"))) {
                HStack {
                    Text(L10n.t("ui_20")).frame(width: 80, alignment: .leading)
                    TextField("如 192.168.1.100", text: $host)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                HStack {
                    Text(L10n.t("ui_119")).frame(width: 80, alignment: .leading)
                    TextField("22", text: $port)
                        .keyboardType(.numberPad)
                }
                HStack {
                    Text(L10n.t("ui_112")).frame(width: 80, alignment: .leading)
                    TextField("如 root", text: $user)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }

            Section(header: Text(L10n.t("ui_131"))) {
                HStack {
                    Text(L10n.t("ui_46")).frame(width: 80, alignment: .leading)
                    SecureField("密码", text: $password)
                }
                HStack {
                    Text(L10n.t("ui_117")).frame(width: 80, alignment: .leading)
                    TextField("可选，如 /var/mobile/.ssh/id_rsa", text: $keyPath)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }

            Section {
                Button("保存配置") {
                    let defaults = UserDefaults.standard
                    defaults.set(host, forKey: "ssh_host")
                    defaults.set(Int(port) ?? 22, forKey: "ssh_port")
                    defaults.set(user, forKey: "ssh_user")
                    defaults.set(password, forKey: "ssh_password")
                    defaults.set(keyPath, forKey: "ssh_key_path")
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(.blue)
            }

            Section(header: Text(L10n.t("ui_24"))) {
                Text(L10n.t("ui_140"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("SSH 远程连接")
        .onAppear {
            let defaults = UserDefaults.standard
            host = defaults.string(forKey: "ssh_host") ?? ""
            port = "\(defaults.integer(forKey: "ssh_port") == 0 ? 22 : defaults.integer(forKey: "ssh_port"))"
            user = defaults.string(forKey: "ssh_user") ?? ""
            password = defaults.string(forKey: "ssh_password") ?? ""
            keyPath = defaults.string(forKey: "ssh_key_path") ?? ""
        }
    }
}
