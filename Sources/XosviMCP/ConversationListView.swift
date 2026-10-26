
import SwiftUI

// MARK: - v6.9.12 豆包风格对话列表（历史会话页）
//
// v6.9.14：整体改为 DeepSeek 风格——白/深中性底、无彩色头像、标题+预览+相对时间，
// 分组标签是 DeepSeek 那种「今天 / 更早」灰字。原始豆包版设计说明保留如下：
//
// 设计对齐豆包 App 的「对话」页：
// - 大标题「对话」+ 顶部右侧 ＋（新建会话）
// - 胶囊搜索框（改在深色卡片里展开，见 ConversationListBody.findActive）
// - 会话行：彩色渐变圆形头像（气泡图标）+ 单行标题 + 「整理成表格」「独立图片显示」这类浅色标签
// - 列表底色 #F5F5F7，行间只留细内边距，不加分隔线
// - 选中行：白底 + 轻微阴影（豆包用极浅的高亮，这里兼顾深色模式）
// - 左滑删除 / 长按菜单（重命名、置顶、删除）
//
// 说明：本文件只负责「列表页」；聊天页与抽屉壳在 ChatView / RootView 里。

// MARK: - 主题

enum DoubaoTheme {
    // v6.9.14（DeepSeek）：底色就是系统底色——浅色纯白、深色近黑，不再用豆包的 #F5F5F7 灰底
    static let bg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.09, alpha: 1)
        : .white })
    // 卡片/输入框底：浅色白（靠描边区分）、深色略亮一档
    static let card = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.15, alpha: 1)
        : .white })
    static let rowSelected = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.18, alpha: 1)
        : UIColor(white: 0.96, alpha: 1) })
    static let hairline = Color.primary.opacity(0.06)
    static let subText = Color.secondary
    static let accent = Color(red: 0.30, green: 0.42, blue: 0.96)   // DeepSeek 蓝

    /// 会话头像配色（按标题哈希稳定取色，豆包就是这么一排彩色圆）
    static let avatars: [(Color, Color)] = [
        (Color(red: 0.42, green: 0.66, blue: 1.00), Color(red: 0.63, green: 0.87, blue: 1.00)), // 蓝
        (Color(red: 0.78, green: 0.58, blue: 1.00), Color(red: 0.94, green: 0.68, blue: 1.00)), // 紫
        (Color(red: 1.00, green: 0.62, blue: 0.72), Color(red: 1.00, green: 0.80, blue: 0.78)), // 粉
        (Color(red: 1.00, green: 0.76, blue: 0.42), Color(red: 1.00, green: 0.89, blue: 0.60)), // 橙
        (Color(red: 0.40, green: 0.84, blue: 0.68), Color(red: 0.66, green: 0.95, blue: 0.78)), // 绿
        (Color(red: 0.56, green: 0.72, blue: 1.00), Color(red: 0.80, green: 0.83, blue: 1.00)), // 靛
    ]

    static func avatarColors(for key: String) -> (Color, Color) {
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return avatars[Int(h % UInt64(avatars.count))]
    }

    /// 会话行右侧的浅色标签（豆包那种灰色小胶囊）
    struct TagSpec: Hashable {
        let text: String
    }

    static func tags(for conv: ChatConversation) -> [TagSpec] {
        var out: [TagSpec] = []
        let msgs = conv.messages
        if msgs.contains(where: { !($0.toolName ?? "").isEmpty }) {
            out.append(TagSpec(text: "工具调用"))
        }
        if msgs.contains(where: { !($0.imageDataURLs ?? []).isEmpty }) {
            out.append(TagSpec(text: "图片"))
        }
        if msgs.contains(where: { ($0.thinking ?? "").isEmpty == false }) {
            out.append(TagSpec(text: "深度思考"))
        }
        let charCount = msgs.reduce(0) { $0 + $1.content.count }
        if charCount > 1500 { out.append(TagSpec(text: "长对话")) }
        if out.isEmpty, msgs.count <= 2 { out.append(TagSpec(text: "新对话")) }
        return Array(out.prefix(2))
    }
}

// MARK: - v7.4.0 设置二级页统一样式（DeepSeek 黑白简洁）

/// 所有「设置 → 某功能」的二级页面统一套这个：
/// - 底色跟主界面一致（浅色白 / 深色近黑），不再是系统分组灰
/// - 强调色统一 DeepSeek 蓝，不再让各页自己用 .blue/.green 拼色
/// - 列表行背景用卡片色，分隔线压得很淡
extension View {
    func deepseekPage() -> some View {
        self
            .tint(DoubaoTheme.accent)
            .background(DoubaoTheme.bg.ignoresSafeArea())
    }

    /// 二级页里的分组列表（scrollContentBackground 需 iOS16+，低版本忽略）
    @ViewBuilder
    func deepseekList() -> some View {
        if #available(iOS 16.0, *) {
            self
                .scrollContentBackground(.hidden)
                .background(DoubaoTheme.bg)
                .listRowBackground(DoubaoTheme.card)
        } else {
            self
        }
    }
}

// MARK: - 列表页

struct ConversationListView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var lang = LanguageManager.shared

    var onOpen: (UUID) -> Void
    var onClose: () -> Void

    @State private var searchText = ""
    @State private var renamingId: UUID?
    @State private var renameText = ""
    @State private var confirmDeleteIds: Set<UUID> = []
    @State private var showDeleteAlert = false

    private var filtered: [ChatConversation] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return store.conversations }
        return store.conversations.filter { conv in
            conv.title.localizedCaseInsensitiveContains(q)
                || conv.messages.contains { $0.content.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ConversationListBody(
                conversations: filtered,
                selectedId: store.selectedId,
                searchText: $searchText,
                onOpen: onOpen,
                onRename: { conv in
                    renameText = conv.title
                    renamingId = conv.id
                },
                onDelete: { conv in
                    confirmDeleteIds = [conv.id]
                    showDeleteAlert = true
                }
            )
        }
        .background(DoubaoTheme.bg.ignoresSafeArea())
        .alert(isPresented: $showDeleteAlert) {
            Alert(
                title: Text("删除对话"),
                message: Text("删除后不可恢复，确定删除 \(confirmDeleteIds.count) 个对话？"),
                primaryButton: .destructive(Text("删除")) {
                    store.deleteConversations(ids: confirmDeleteIds)
                    confirmDeleteIds = []
                },
                secondaryButton: .cancel(Text("取消")) { confirmDeleteIds = [] }
            )
        }
        .sheet(item: Binding(
            get: { renamingId.map { IdentifiedUUID(id: $0) } },
            set: { if $0 == nil { renamingId = nil } }
        )) { item in
            RenameSheet(initialTitle: renameText, onDone: { newTitle in
                store.rename(item.id, to: newTitle)
                renamingId = nil
            }, onCancel: {
                renamingId = nil
            })
        }
    }

    // MARK: 头部

    private var header: some View {
        // v6.9.14（DeepSeek）：扁平行——左「‹ 对话」、右「＋新建」，不要大标题和浮动圆按钮
        HStack(alignment: .center, spacing: 8) {
            Button(action: onClose) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("对话")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundColor(.primary)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            Button {
                store.newConversation()
                if let id = store.selectedId { onOpen(id) }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

private struct IdentifiedUUID: Identifiable {
    let id: UUID
}

/// 列表主体（抽屉里复用：不带返回按钮，只留搜索 + 列表）
struct ConversationListBody: View {
    // v7.1.2：原先这里直接用 `store`，但本结构没有该属性（CI 报 cannot find 'store'）
    @ObservedObject private var store = ConversationStore.shared
    var conversations: [ChatConversation]
    var selectedId: UUID?
    @Binding var searchText: String
    var onOpen: (UUID) -> Void
    var onRename: (ChatConversation) -> Void
    var onDelete: (ChatConversation) -> Void

    @State private var swipedId: UUID?
    @State private var swipeOffset: CGFloat = 0
    @State private var archiveExpanded = true
    @State private var oldGroupExpanded = false

    private let revealWidth: CGFloat = 84
    private let commitWidth: CGFloat = 150

    private var recent: [ChatConversation] {
        conversations.filter { isToday($0.updatedAt) || isYesterday($0.updatedAt) }
    }
    private var older: [ChatConversation] {
        conversations.filter { !(isToday($0.updatedAt) || isYesterday($0.updatedAt)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            ScrollView {
                LazyVStack(spacing: 0) {
                    taskPanel
                    if recent.isEmpty && older.isEmpty {
                        emptyHint
                    }
                    section("今天", count: recent.count, expanded: $archiveExpanded,
                            list: recent, isGroup150: false)
                    if !older.isEmpty {
                        section("更早", count: older.count, expanded: $oldGroupExpanded,
                                list: older, isGroup150: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: 搜索

    /// 豆包「任务卡片」式的运行中提示：有会话正在跑时置顶一条，点开直达
    @ViewBuilder
    private var taskPanel: some View {
        let anyRunning = store.isLoading
        if anyRunning, let cur = conversations.first(where: { $0.id == store.selectedId && !$0.messages.isEmpty }) {
            Button {
                onOpen(cur.id)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(DoubaoTheme.accent.opacity(0.12)).frame(width: 36, height: 36)
                        Image(systemName: "waveform")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(DoubaoTheme.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.runningTool.map { "正在执行：\($0)" } ?? store.statusText ?? "正在处理")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(cur.title)
                            .font(.system(size: 12))
                            .foregroundColor(DoubaoTheme.subText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DoubaoTheme.subText.opacity(0.6))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DoubaoTheme.card))
                .padding(.top, 6)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(DoubaoTheme.subText)
            TextField("搜索对话", text: $searchText)
                .font(.system(size: 15))
                .accentColor(DoubaoTheme.accent)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(DoubaoTheme.subText.opacity(0.7))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        // v6.9.14（DeepSeek）：搜索框是灰底圆角矩形
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(UIColor.secondarySystemBackground)))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: 分组

    @ViewBuilder
    private func section(_ title: String, count: Int, expanded: Binding<Bool>,
                         list: [ChatConversation], isGroup150: Bool) -> some View {
        if !list.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DoubaoTheme.subText)
                    Text("\(count)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DoubaoTheme.subText.opacity(0.8))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(DoubaoTheme.subText.opacity(0.7))
                        .rotationEffect(.degrees(expanded.wrappedValue ? 0 : -90))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 6)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            .buttonStyle(PlainButtonStyle())

            if expanded.wrappedValue {
                ForEach(list) { conv in
                    swipableRow(conv)
                        .padding(.vertical, 1)
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(DoubaoTheme.subText.opacity(0.5))
            Text(searchText.isEmpty ? "还没有对话" : "没有找到相关对话")
                .font(.system(size: 14))
                .foregroundColor(DoubaoTheme.subText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: 行（含左滑删除）

    @ViewBuilder
    private func swipableRow(_ conv: ChatConversation) -> some View {
        let isOpen = swipedId == conv.id
        let offset = isOpen ? swipeOffset : 0

        ZStack(alignment: .trailing) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { onDelete(conv) }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash.fill").font(.system(size: 15, weight: .semibold))
                    Text("删除").font(.system(size: 10))
                }
                .foregroundColor(.white)
                .frame(width: revealWidth)
                .frame(maxHeight: .infinity)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .opacity(offset < -8 ? 1 : 0)
            .allowsHitTesting(offset < -8)

            ConversationRow(
                conv: conv,
                selected: selectedId == conv.id
            )
            .offset(x: offset)
            .highPriorityGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        let base: CGFloat = isOpen ? -revealWidth : 0
                        var t = base + value.translation.width
                        t = min(0, max(t, -commitWidth * 1.2))
                        swipedId = conv.id
                        swipeOffset = t
                    }
                    .onEnded { _ in
                        let final = swipeOffset
                        if final < -commitWidth {
                            withAnimation(.easeOut(duration: 0.18)) {
                                swipedId = nil; swipeOffset = 0
                            }
                            onDelete(conv)
                        } else if final < -revealWidth * 0.5 {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                swipedId = conv.id
                                swipeOffset = -revealWidth
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                swipedId = nil; swipeOffset = 0
                            }
                        }
                    }
            )
            .onTapGesture {
                if isOpen {
                    withAnimation(.easeOut(duration: 0.2)) { swipedId = nil; swipeOffset = 0 }
                } else {
                    onOpen(conv.id)
                }
            }
            .contextMenu {
                Button { onRename(conv) } label: { Label("重命名", systemImage: "pencil") }
                Button { onDelete(conv) } label: { Label("删除", systemImage: "trash") }
            }
        }
        .clipped()
    }

    // MARK: 时间工具

    private func isToday(_ d: Date) -> Bool { Calendar.current.isDateInToday(d) }
    private func isYesterday(_ d: Date) -> Bool { Calendar.current.isDateInYesterday(d) }
}

// MARK: - 单行

struct ConversationRow: View {
    let conv: ChatConversation
    let selected: Bool

    private var preview: String {
        // DeepSeek 每行第二行是最后一条消息的摘要
        let last = conv.messages.last(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let text = (last?.content ?? conv.messages.last?.content ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "空对话" : text
    }

    var body: some View {
        // v6.9.14（DeepSeek）：无头像、无彩色标签——标题一行 + 消息摘要一行 + 右侧相对时间
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(conv.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(preview)
                    .font(.system(size: 13))
                    .foregroundColor(DoubaoTheme.subText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Text(Self.shortTime(conv.updatedAt))
                .font(.system(size: 12))
                .foregroundColor(DoubaoTheme.subText.opacity(0.85))
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? DoubaoTheme.rowSelected : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func shortTime(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: d)
        }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M/d" : "yy/M/d"
        return f.string(from: d)
    }
}

// MARK: - 重命名弹窗

struct RenameSheet: View {
    @State private var title: String
    var onDone: (String) -> Void
    var onCancel: () -> Void

    init(initialTitle: String, onDone: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _title = State(initialValue: initialTitle)
        self.onDone = onDone
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名对话")
                .font(.system(size: 18, weight: .semibold))
            TextField("对话标题", text: $title)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            HStack(spacing: 12) {
                Button("取消") { onCancel() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
                Button("保存") { onDone(title) }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundColor(.white)
                    .background(RoundedRectangle(cornerRadius: 12).fill(DoubaoTheme.accent))
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.system(size: 15, weight: .medium))
            .buttonStyle(PlainButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}
