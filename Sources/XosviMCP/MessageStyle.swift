import SwiftUI
import UIKit

// MARK: - v7.4.1 AI Agent 调试会话风格：消息区组件
//
// 设计目标（用户要求）：干净、简约、不要多余装饰。
//   · 普通文本 → 纯文本块，无彩色气泡
//   · 代码 → **黑色代码预览块**（浅色模式也是黑底），带语言标签 + 复制
//   · 工具调用 → 圆角卡片：图标 + 名称 + 运行耗时，状态用极简符号表达
//
// 所有颜色走中性灰阶 + 语义色（红=出错），不再用蓝/青色做装饰。

// MARK: - 文本分块（普通文本 / 代码块）

struct MessageBlock: Identifiable {
    enum Kind {
        case text(String)
        case code(lang: String, body: String)
    }
    let id = UUID()
    var kind: Kind
}

enum MessageBlockParser {
    /// 按 ``` 围栏切分。未闭合的围栏（流式输出中途）按普通文本处理，避免闪烁。
    // v7.9.12：按原文缓存——同一段文本在多次 body 重算里会被反复解析（列表越大越明显）
    private static var parseCache: [String: [MessageBlock]] = [:]
    private static let parseLock = NSLock()

    static func parse(_ raw: String) -> [MessageBlock] {
        parseLock.lock()
        if let hit = parseCache[raw] {
            parseLock.unlock()
            return hit
        }
        parseLock.unlock()
        let result = parseUncached(raw)
        parseLock.lock()
        if parseCache.count > 200 { parseCache.removeAll(keepingCapacity: true) }
        parseCache[raw] = result
        parseLock.unlock()
        return result
    }

    private static func parseUncached(_ raw: String) -> [MessageBlock] {
        guard raw.contains("```") else { return [MessageBlock(kind: .text(raw))] }
        var blocks: [MessageBlock] = []
        var buffer: [String] = []
        var inCode = false
        var lang = ""

        func flushText() {
            let t = buffer.joined(separator: "\n")
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(MessageBlock(kind: .text(t))) }
            buffer.removeAll()
        }

        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(MessageBlock(kind: .code(lang: lang, body: buffer.joined(separator: "\n"))))
                    buffer.removeAll()
                    inCode = false
                    lang = ""
                } else {
                    flushText()
                    inCode = true
                    lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else {
                buffer.append(line)
            }
        }
        // 收尾：未闭合的代码块按普通文本处理（流式中途）
        if inCode {
            blocks.append(MessageBlock(kind: .text(buffer.joined(separator: "\n"))))
        } else {
            flushText()
        }
        return blocks
    }
}

// MARK: - 代码预览块（黑底）

// MARK: - v8：[cite:sN] 引用角标（web.search 结果引用）

/// web.search 结果带稳定 id（s1, s2, ...），模型在句末写 [cite:sN]；
/// 这里把标记替换成彩色角标：命中本轮结果的蓝标，未命中的灰标。
/// 走 NSAttributedString（与 v4.5.0 富文本路径一致，SwiftUI AttributedString 桥接会丢样式）。
enum CitationRenderer {
    private static let pattern = #"\[cite:(s\d+)\]"#

    /// 在粗体/代码解析结果之上替换 [cite:sN]；urls 来自本轮 web.search 工具消息的 citedURLs
    static func apply(to attributed: NSAttributedString, urls: [String: String]) -> NSAttributedString {
        guard attributed.string.contains("[cite:") else { return attributed }
        let ns = attributed.string as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributed }
        let matches = regex.matches(in: attributed.string, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return attributed }
        let out = NSMutableAttributedString(attributedString: attributed)
        for m in matches.reversed() {
            let id = ns.substring(with: m.range(at: 1))
            let hit = urls[id] != nil
            let marker = NSMutableAttributedString(string: " \(id) ")
            marker.addAttributes([
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: hit ? UIColor.white : UIColor.secondaryLabel,
                .backgroundColor: hit ? UIColor.systemBlue : UIColor.systemGray5
            ], range: NSRange(location: 0, length: marker.length))
            out.replaceCharacters(in: m.range, with: marker)
        }
        return out
    }

    /// 从消息流收集本轮可引用的 id→url：从当前 assistant 消息向前扫到上一条 user 消息为止，
    /// 合并所有 tool 消息的 citedURLs（按会话轮次累积——第 2 轮仍可引用第 1 轮搜到的 sN）
    static func collectURLs(around message: ChatMessage, in messages: [ChatMessage]) -> [String: String] {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return [:] }
        var urls: [String: String] = [:]
        for m in messages[...idx].reversed() {
            if m.role == "user" { break }
            if let c = m.citedURLs { urls.merge(c) { _, new in new } }
        }
        return urls
    }
}

struct CodeBlockView: View {
    var lang: String
    var code: String
    @State private var copied = false

    private var displayLang: String {
        let l = lang.trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? "code" : l
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：语言标签 + 复制
            HStack(spacing: 6) {
                Text(displayLang.lowercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(white: 0.62))
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = code
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation { copied = false }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(Color(white: 0.62))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 6)

            // 代码正文：黑底、等宽、横向可滚
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(Color(white: 0.90))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(white: 0.10))     // 浅色/深色模式都是近黑，和 DeepSeek 的代码块一致
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
        )
    }
}

// MARK: - 工具调用卡片（圆角 + 图标 + 名称 + 耗时）

/// 工具名 → SF Symbol（中性线条图标，不用彩色）
func toolSymbol(_ name: String) -> String {
    let n = name.lowercased()
    if n.hasPrefix("shell") { return "terminal" }
    if n.hasPrefix("web") { return "globe" }
    if n.hasPrefix("workspace") { return "folder" }
    if n.hasPrefix("subagent") { return "person.2" }
    if n.hasPrefix("file") || n.hasPrefix("artifact") { return "doc" }
    if n.hasPrefix("db") { return "cylinder.split.1x2" }
    if n.hasPrefix("app") { return "square.grid.2x2" }
    if n.hasPrefix("inject") { return "syringe" }
    if n.hasPrefix("control") { return "cursorarrow.click" }
    if n.hasPrefix("memory") { return "memorychip" }
    if n.hasPrefix("network") || n.hasPrefix("vpn") { return "antenna.radiowaves.left.and.right" }
    if n.hasPrefix("device") { return "iphone" }
    if n.hasPrefix("package") { return "shippingbox" }
    if n.hasPrefix("macho") || n.hasPrefix("disasm") { return "cpu" }
    if n.hasPrefix("skills") || n.hasPrefix("knowledge") { return "book" }
    if n.hasPrefix("diagnose") || n.hasPrefix("verify") { return "stethoscope" }
    return "wrench.and.screwdriver"
}

struct ToolCallCard: View {
    var name: String
    var args: String?
    var duration: Double?
    var isRunning: Bool
    var isError: Bool
    /// 展开后的结果区（由调用方传入，可为空）
    var expanded: Bool = false
    var onTap: (() -> Void)? = nil

    private var subtitle: String? {
        guard let a = args, !a.isEmpty else { return nil }
        // 单行化，太长截断（完整内容展开后可看）
        let one = a.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return one.count > 120 ? String(one.prefix(120)) + "…" : one
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: toolSymbol(name))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let s = subtitle {
                        Text(s)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 6)

                // 状态 + 耗时（极简：只有转圈 / ✓ / ✗ 加时间）
                HStack(spacing: 5) {
                    if isRunning {
                        ProgressView().scaleEffect(0.62)
                    } else if isError {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.red)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    if let d = duration {
                        Text(String(format: "%.1fs", d))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DoubaoTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(UIColor.separator).opacity(0.55), lineWidth: 0.7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
    }
}
