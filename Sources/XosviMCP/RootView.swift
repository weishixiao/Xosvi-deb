import SwiftUI
import UIKit

final class AppUIState: ObservableObject {
    static let shared = AppUIState()
    @Published var drawerOpen = false
    @Published var settingsPresented = false
    @Published var settingsJumpToModels = false
    // v4.4.16：底部"指令"胶囊 → 打开设置并跳到系统指令(SystemPromptsView)页
    @Published var settingsJumpToSystemPrompts = false
    @Published var controlPresented = false
    @Published var macroPresented = false
    // v3.0.76：输入框上方快捷标签
    @Published var quickTerminalPresented = false
    @Published var quickToolsPresented = false
    @Published var quickSkillsPresented = false
    @Published var quickFilesPresented = false
    /// v7.0.0：Hax 浏览器（全屏弹出；旧 FloatingBrowser 已删除）
    @Published var quickHaxBrowserPresented = false
}

struct RootView: View {
    @ObservedObject private var ui = AppUIState.shared
    @ObservedObject private var lang = LanguageManager.shared   // v2.9.76：语言切换全局刷新
    // v2.9.78：首次启动引导；v2.9.83：改为按版本展示——每次安装新版本/覆盖老版本都重新展现引导页
    @State private var showOnboarding = RootView.onboardingNeeded()
    // v2.9.126：深链导入确认页（xosvi://import?...）
    @ObservedObject private var pendingImport = PendingImport.shared
    @State private var importResult: String?
    // v4.3.44：QuickLook 分享中间层状态（侧载环境分享面板安全路径）
    @ObservedObject private var shareCenter = ShareCenter.shared

    private static func onboardingNeeded() -> Bool {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return UserDefaults.standard.string(forKey: "xosvi.onboarding_last_version") != v
    }

    private func markOnboardingDone() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        UserDefaults.standard.set(v, forKey: "xosvi.onboarding_last_version")
    }

    var body: some View {
        ZStack {
            ChatRootView()
                .disabled(ui.drawerOpen)

            if ui.drawerOpen {
                Color.black
                    .opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { ui.drawerOpen = false } }
            }

            GeometryReader { geo in
                HStack(spacing: 0) {
                    ConversationDrawerView()
                        .frame(width: drawerWidth(for: geo))
                        .offset(x: ui.drawerOpen ? 0 : -drawerWidth(for: geo))
                        .animation(.easeInOut)
                        .edgesIgnoringSafeArea(.vertical)
                        .allowsHitTesting(ui.drawerOpen)
                    Spacer()
                }
            }
        }
        // v7.0.0：旧悬浮浏览器（FloatingBrowserOverlay）已删除，改为 Hax 浏览器全屏页
        .fullScreenCover(isPresented: Binding(
            get: { ui.quickHaxBrowserPresented },
            set: { ui.quickHaxBrowserPresented = $0 }
        )) {
            CompatNav {
                HaxBrowserView(embedded: false, onClose: { ui.quickHaxBrowserPresented = false })
                    .navigationTitle("Hax 浏览器")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        // v2.9.76：设置改全屏（去掉 sheet 半屏 + 顶部 grabber），子页面头部对齐
        .fullScreenCover(isPresented: Binding(
            get: { ui.settingsPresented },
            set: { ui.settingsPresented = $0 }
        )) {
            SettingsView()
        }
        // v2.9.78：引导页（v2.9.83：每个新版本展示一次）
        .fullScreenCover(isPresented: $showOnboarding, onDismiss: {
            markOnboardingDone()
        }) {
            OnboardingView {
                markOnboardingDone()
                showOnboarding = false
            }
        }
        // v2.9.139：AI 控制中心（控制任意 App 时的计划/进度/日志/结果页）
        .fullScreenCover(isPresented: Binding(
            get: { ui.controlPresented },
            set: { ui.controlPresented = $0 }
        )) {
            ControlCenterView()
        }
        // v2.9.142：宏管理页（聊天输入框「🎬 宏」入口）
        .fullScreenCover(isPresented: Binding(
            get: { ui.macroPresented },
            set: { ui.macroPresented = $0 }
        )) {
            MacroView()
        }
        // v2.9.76：语言切换后全局重建视图
        .id(lang.language.rawValue)
        // v2.9.126：深链导入确认页——暂存配置后弹窗，确认才写入
        .onReceive(NotificationCenter.default.publisher(for: PendingImport.didStageNotification)) { note in
            if let result = note.userInfo?["result"] as? String {
                importResult = result == "imported" ? "已导入并切换" : "重复配置，未导入"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { importResult = nil }
            }
        }
        .alert(isPresented: Binding(
            get: { pendingImport.staged != nil },
            set: { if !$0 { pendingImport.cancel() } }
        )) {
            if let cfg = pendingImport.staged {
                return Alert(
                    title: Text(L10n.t("ui_49")),
                    message: Text(L10n.t("ui_170", cfg.name, cfg.model, cfg.baseURL)),
                    primaryButton: .default(Text(L10n.t("ui_48")), action: { pendingImport.confirm() }),
                    secondaryButton: .cancel(Text(L10n.t("ui_40")), action: { pendingImport.cancel() })
                )
            }
            return Alert(title: Text(""), dismissButton: .default(Text("OK")))
        }
        .overlay(Group {
            if let result = importResult {
                Text(result)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.85))
                    .cornerRadius(10)
                    .padding(.bottom, 120)
                    .transition(.opacity)
            }
        }, alignment: .bottom)
        // v4.3.44：剪贴板/写入提示（分享降级或失败时的用户反馈）
        .overlay(alignment: .bottom) {
            if let notice = shareCenter.clipboardNotice {
                Text(notice)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.85))
                    .cornerRadius(10)
                    .padding(.bottom, 100)
                    .transition(.opacity)
            }
        }
    }

    private func drawerWidth(for geo: GeometryProxy) -> CGFloat {
        min(geo.size.width * 0.78, 320)
    }
}

struct ConversationDrawerView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var ui = AppUIState.shared
    @ObservedObject private var probe = DeviceProbe.shared
    @State private var searchText = ""
    // v6.9.11：侧滑删除——记录当前滑开的会话 id 与位移（同一时间只允许一行滑开）。
    // 会话列表用 ScrollView+LazyVStack 而非 List（为去掉行间分隔线），
    // List 的 .swipeActions 用不了，只能自己做手势。
    // 注意：这些状态必须在 ConversationDrawerView 内——会话列表属于本视图，
    // 放到 RootView 里会 cannot find in scope。
    @State private var swipedId: UUID?
    @State private var swipeOffset: CGFloat = 0
    // v2.9.166：deviceReady 改为计算属性直接读 DeviceProbe.shared.lastReport——
    // 旧版 @State 只在 onAppear 读一次：用户点开检测页跑完（全绿）返回后，
    // 左下角仍是旧感叹号，这就是"环境通过了还显示感叹号"的根因。
    // @ObservedObject 观察 lastReport @Published，检测页/启动检测完成自动同步。
    private var deviceReady: Bool? { probe.lastReport?.ready }

    private var filtered: [ChatConversation] {
        if searchText.isEmpty { return store.conversations }
        return store.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.messages.contains { $0.content.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            // v7.2.1：去掉"N 个本机对话"计数条（DeepSeek 抽屉里没这行）
            conversationList
            bottomWorkbench
        }
        .background(Color(.systemBackground))
        .onAppear(perform: refreshReadiness)
    }

    private var header: some View {
        // v6.9.18：左上角的功能键图标 +「对话」标题用户要求删除（新建 / 关闭仍留在右侧）
        HStack(spacing: 10) {
            Spacer()
            // v6.2.7：抽屉头部新建会话入口（配合 ChatView 边缘侧滑手势，
            // 侧滑开抽屉即可一键新建，解决"侧滑无法打开添加新对话页"）
            // v6.9.12：新建后发通知，ChatRootView 会切到聊天页
            Button(action: {
                withAnimation { ui.drawerOpen = false }
                store.newConversation()
                NotificationCenter.default.post(name: .tmNewConversation, object: nil)
            }) {
                // v7.2.1（DeepSeek）：蓝色实心方块 → 黑色细线图标，与整体黑白一致
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.primary)
            }
            // v6.6.8：抽屉头部设置齿轮用户要求删除（改为会话页侧滑直达抽屉）
            Button(action: { withAnimation { ui.drawerOpen = false } }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topSafeArea + 8)
        .padding(.bottom, 12)
    }

    /// v2.9.12：状态栏安全区高度（抽屉 ignoredSafeArea 后需手动避让系统时间）
    private var topSafeArea: CGFloat {
        UIApplication.shared.windows.first?.safeAreaInsets.top ?? 0
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14))
            TextField(L10n.t("drawer_search"), text: $searchText)
                .font(.subheadline)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // v7.2.1（DeepSeek）：灰底圆角矩形，不再用蓝色描边提示聚焦
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 16)
    }

    private var countLabel: some View {
        HStack {
            Text(L10n.t("drawer_count").replacingOccurrences(of: "{n}", with: "\(store.conversations.count)"))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var conversationList: some View {
        // 用 ScrollView + LazyVStack 替代 List，去掉行间分隔线（v2.9.9）
        // v2.9.10：选中行加渐变圆角卡片
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(filtered) { conv in
                    // v6.9.11：侧滑删除（自行实现——会话列表是 ScrollView+LazyVStack，非 List）
                    swipableRow(conv)
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private func deleteSingle(_ id: UUID) {
        guard let idx = store.conversations.firstIndex(where: { $0.id == id }) else { return }
        store.delete(at: IndexSet(integer: idx))
        if swipedId == id { swipedId = nil; swipeOffset = 0 }
    }

    // MARK: - v6.9.11 侧滑删除行

    /// 会话列表用的是 ScrollView+LazyVStack（为去掉 List 的分隔线），
    /// `.swipeActions` 只对 List 生效，所以这里自己做左滑：
    /// - 左滑超过阈值 → 停靠到露出删除按钮的位置
    /// - 再左滑一点或点删除按钮 → 删除
    /// - 右滑或点其他行 → 收回
    /// 同一时刻只允许一行滑开（swipedId 全局唯一）。
    private let swipeReveal: CGFloat = 76    // 删除按钮露出宽度
    private let swipeCommit: CGFloat = 132   // 超过则直接触发删除

    @ViewBuilder
    private func swipableRow(_ conv: ChatConversation) -> some View {
        let isOpen = swipedId == conv.id
        let offset = isOpen ? swipeOffset : 0

        ZStack(alignment: .trailing) {
            // 底层：删除按钮
            Button {
                withAnimation(.easeOut(duration: 0.18)) { deleteSingle(conv.id) }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash.fill").font(.system(size: 15, weight: .semibold))
                    Text(L10n.t("drawer_delete")).font(.system(size: 10))
                }
                .foregroundColor(.white)
                .frame(width: swipeReveal)
                .frame(maxHeight: .infinity)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .opacity(offset < -8 ? 1 : 0)
            .allowsHitTesting(offset < -8)

            // 上层：会话行，可左右拖
            Button(action: {
                // 已滑开时点击先收回，不切换会话
                if isOpen {
                    withAnimation(.easeOut(duration: 0.2)) { swipedId = nil; swipeOffset = 0 }
                } else {
                    store.select(conv.id)
                    withAnimation { ui.drawerOpen = false }
                }
            }) {
                conversationRow(conv)
                    .background(
                        Group {
                            if store.selectedId == conv.id {
                                // v7.2.1（DeepSeek）：选中行是浅灰底，不再是蓝色渐变
                                Color(UIColor { $0.userInterfaceStyle == .dark
                                    ? UIColor(white: 0.18, alpha: 1)
                                    : UIColor(white: 0.96, alpha: 1) })
                            } else {
                                Color(.systemBackground)
                            }
                        }
                    )
                    .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
            .offset(x: offset)
            .highPriorityGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        // 只响应水平拖，且左滑为主；右滑用于收回已滑开的行
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        let base: CGFloat = isOpen ? -swipeReveal : 0
                        // 越界阻尼：最多滑到 swipeCommit*1.3
                        var t = base + value.translation.width
                        t = min(0, max(t, -swipeCommit * 1.3))
                        swipedId = conv.id
                        swipeOffset = t
                    }
                    .onEnded { value in
                        let final = swipeOffset
                        if final < -swipeCommit {
                            withAnimation(.easeOut(duration: 0.18)) { deleteSingle(conv.id) }
                        } else if final < -swipeReveal * 0.5 {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                swipedId = conv.id
                                swipeOffset = -swipeReveal
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                swipedId = nil
                                swipeOffset = 0
                            }
                        }
                    }
            )
            .contextMenu {
                // iOS14 兼容：不用 Button(role:)
                Button(action: { deleteSingle(conv.id) }) {
                    Label(L10n.t("drawer_delete"), systemImage: "trash")
                }
            }
        }
        .clipped()
    }

    /// v7.2.1（DeepSeek 风格）：去掉蓝色方形气泡图标和"日期时间"副标题，
    /// 改成 标题 + 最后一条消息摘要 + 右侧相对时间，与对话列表页保持一致。
    private func conversationRow(_ conv: ChatConversation) -> some View {
        let isSel = store.selectedId == conv.id
        let last = conv.messages.last { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let preview = (last?.content ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(conv.title)
                    .font(.system(size: 15, weight: isSel ? .semibold : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(preview.isEmpty ? "空对话" : preview)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(ConversationRow.shortTime(conv.updatedAt))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.85))
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { filtered[$0].id }
        let idxSet = IndexSet(store.conversations.enumerated().compactMap { ids.contains($0.element.id) ? $0.offset : nil })
        store.delete(at: idxSet)
    }

    private var deviceReadinessBar: some View {
        // 已并入 bottomWorkbench 精简入口（v2.9.9），此实现保留备用
        EmptyView()
    }

    private var readinessText: String {
        if let ready = deviceReady { return ready ? L10n.t("drawer_ready") : L10n.t("drawer_env_limited") }
        return L10n.t("drawer_probe")
    }

    /// v2.9.166：环境未就绪时显示首个失败项简短原因（如"Entitlements 未生效"），
    /// 而不是笼统感叹号——用户要求"不打X✔只做简单提醒"。
    private var failureHint: String {
        if deviceReady == true { return L10n.t("drawer_ready_short") }
        if let report = probe.lastReport {
            for c in report.checks where !c.passed && !c.infoOnly {
                return c.label
            }
        }
        return "检测环境"
    }

    private func refreshReadiness() {
        // 轻量读取缓存报告，避免每次打开抽屉都全量扫描
        // （@ObservedObject 已自动同步，此方法仅用于首次出现时兜底）
        _ = probe.lastReport?.ready
    }

    private var bottomWorkbench: some View {
        // v6.6.7：删除本机环境入口卡片；设置齿轮移到此界面左边（用户要求）
        HStack(spacing: 12) {
            Button(action: {
                withAnimation { ui.drawerOpen = false }
                ui.settingsPresented = true
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 52, height: 52)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)
                    .contentShape(Rectangle())
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 24)
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}
