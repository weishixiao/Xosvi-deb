import SwiftUI

// v2.9.77：统一页面美化组件库
// 所有设置子页面共用：PageHeader（图标+标题+副标题）+ CardBox（圆角卡片）+ 段落标题
//
// v7.4.1（DeepSeek 黑白风）：原来这里是「彩色渐变方块 + 白色粗图标 + 彩色投影」，
// 整页五颜六色。现在统一成中性：裸露线条图标、白/深灰卡片、细描边、无投影。
// `colors` / `iconColor` 参数保留只为兼容既有调用点，实际不再影响渲染。

struct PageHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    var colors: [Color] = []        // 已废弃：保留签名兼容，不再使用
    var iconColor: Color = .white   // 已废弃：同上

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.primary)
                .frame(width: 34, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

struct CardBox<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // v7.4.1：去掉液态玻璃/阴影，改成白（深色为近黑）卡片 + 细描边
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DoubaoTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(UIColor.separator).opacity(0.45), lineWidth: 0.7)
            )
            .padding(.horizontal, 16)
    }
}

struct CardSectionHeader: View {
    let icon: String
    let title: String
    var color: Color = .primary   // 已废弃：统一用主文字色

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

struct PageContainer<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                content
            }
            .padding(.vertical, 16)
        }
        .background(DoubaoTheme.bg)
    }
}
