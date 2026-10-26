import SwiftUI
import UIKit

// MARK: - v7.6.0 工具结果半屏面板
//
// 用户要求：工具输出改成「打开半屏」查看，取消原来的气泡内折叠展开。
// 结构：
//   拖动条 → 标题（工具名）+ 状态/耗时/字符数 → 参数区 → 输出区（黑底等宽）→ 相关文件
// 操作：复制 / 分享 / 关闭
struct ToolResultSheet: View {
    let message: ChatMessage
    @Environment(\.presentationMode) private var presentationMode

    @State private var copied = false

    private var title: String {
        let n = message.toolName?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? "工具结果" : n
    }

    private var statusText: String {
        if message.isRunning { return "执行中" }
        return message.isError ? "出错" : "完成"
    }

    private var statusColor: Color {
        if message.isRunning { return .blue }
        return message.isError ? .red : .green
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(UIColor.tertiaryLabel))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 12)

            header
            Divider().opacity(0.4)
            content
        }
        .background(Color(.systemBackground))
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusText)
                    if let d = message.toolDuration {
                        Text(String(format: "· %.1fs", d))
                    }
                    Text("· \(message.content.count) 字符")
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: {
                UIPasteboard.general.string = message.content
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            }) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(UIColor.secondarySystemBackground)))
            }
            .buttonStyle(PlainButtonStyle())

            SharePresenter.toolbarShare(text: message.content)

            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color(UIColor.secondarySystemBackground)))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let args = message.toolArgs,
                   !args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    section("参数") {
                        Text(args)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(UIColor.secondarySystemBackground)))
                    }
                }

                section("输出") {
                    Text(message.content.isEmpty ? "（无输出）" : message.content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black))
                }

                let files = FilePathExtractor.extractFiles(from: message.content)
                if !files.isEmpty {
                    section("相关文件") {
                        VStack(spacing: 6) {
                            ForEach(files, id: \.self) { url in
                                FileCardRow(url: url)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            content()
        }
    }
}
