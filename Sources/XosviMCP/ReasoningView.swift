import SwiftUI
import UIKit

// MARK: - v7.7.0 深度思考渲染（对齐 Kelivo 的 reasoning 呈现）
//
// 之前：纯 Text + 固定高度内部滚动，长思考内容既不好读、也不像代码。
// 现在：
//   · 折叠态 = preview：最多 100pt，上下渐变遮罩，暗示"还有更多"
//   · 展开态 = 全量渲染，Markdown 风格：普通段落 + 黑底代码块 + 行内代码
//   · 流式时也走同一套渲染
//   · 点标题栏切换；展开后可复制全文

struct ReasoningBlock: View {
    let text: String
    let isStreaming: Bool
    @Binding var expanded: Bool

    /// preview 态高度上限（Kelivo 用 100）
    private let previewHeight: CGFloat = 100

    private var headerText: String {
        if isStreaming { return "思考中…" }
        return "已深度思考 \(text.count) 字"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                    Text(headerText)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    if expanded {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            content
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var content: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(isStreaming ? "…" : "（无思考内容）")
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
        } else if expanded {
            ScrollView(.vertical, showsIndicators: true) {
                ReasoningRichText(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        } else {
            // preview：截断 + 上下渐变
            ScrollView(.vertical, showsIndicators: false) {
                ReasoningRichText(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: previewHeight)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .white, location: 0.14),
                        .init(color: .white, location: 0.72),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
        }
    }
}

// MARK: - 富文本思考内容（段落 + 行内代码 + 黑底代码块）

struct ReasoningRichText: View {
    let text: String

    var body: some View {
        let blocks = MessageBlockParser.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                switch block.kind {
                case .text(let t):
                    Text(inline(t))
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let lang, let body):
                    CodeBlockView(lang: lang, code: body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 行内：`code` 等宽 + 灰底
    private func inline(_ s: String) -> AttributedString {
        var out = AttributedString()
        var rest = s[s.startIndex...]
        while let tick = rest.firstIndex(of: "`") {
            let after = rest.index(after: tick)
            guard let end = rest[after...].firstIndex(of: "`") else { break }
            if tick > rest.startIndex {
                out += AttributedString(String(rest[rest.startIndex..<tick]))
            }
            let code = String(rest[after..<end])
            var c = AttributedString(code)
            c.font = .system(size: 12, design: .monospaced)
            c.backgroundColor = Color(UIColor.tertiarySystemFill)
            out += c
            rest = rest[rest.index(after: end)...]
        }
        if !rest.isEmpty { out += AttributedString(String(rest)) }
        return out
    }
}
