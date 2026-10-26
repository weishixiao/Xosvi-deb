import Foundation
import SwiftUI
import WebKit

// MARK: - v7.0.0 haxbrowser 工具（AI 思考 / 查问题时调用）
//
// 与旧的 13 个 browser.* 工具不同，这里只有**一个**大工具 + 子命令，
// 描述里写死了"什么时候该用它"，让模型在不确定 / 需要查资料时主动打开：
//   search  → 打开搜索结果页（默认百度，结果为空自动换必应/搜狗/360/Google/DDG）
//   open    → 打开指定网址
//   snapshot→ 读渲染后的正文 + 可点元素编号（AI 靠这个"看"页面）
//   text    → 只读正文（省 token）
//   click/type → 按编号或 CSS 选择器操作页面
//   eval    → 执行任意 JS（高级）
//   status/back/reload/close
final class HaxBrowserTool: MCPTool {
    let definition = ToolDefinition(
        name: "haxbrowser",
        summary: """
        Hax 浏览器：真实渲染的网页浏览器，AI 思考、查资料、核对事实时用它。 \
        Use for: 不确定答案要查证、需要看渲染后的网页（JS 页面 / 登录态 / 点链接 / 读正文）、搜索最新信息。 \
        Don't use for: 只要结果列表（用 web.search，更快）、抓单个静态页（用 web.fetch）。 \
        工作流：search 或 open → wait → snapshot（拿正文 + 元素编号）→ 需要的话 click/type 继续。 \
        Example: 用户问"TrollStore 最新版是多少" → haxbrowser {command:'search', query:'TrollStore 最新版本'} → snapshot 读结果。
        """,
        parameters: [
            "command": "search / open / snapshot / text / click / type / eval / wait / back / reload / status",
            "query": "For search: 搜索词",
            "engine": "For search: baidu(默认) / bing / sogou / so360 / google / duckduckgo；不填就百度，结果差自动换备用引擎",
            "url": "For open: 网址（不带 http 时自动补，非网址则当搜索词）",
            "idx": "For click/type: snapshot 返回的元素编号",
            "selector": "For click: CSS 选择器（比编号更稳，固定站点用）",
            "text": "For type: 要填入的文字",
            "js": "For eval: 要执行的 JavaScript",
            "seconds": "For wait: 最长等待秒数（默认 10）",
            "chars": "For text/snapshot: 正文最多返回多少字（默认 8000）"
        ],
        verified: false, category: "browser",
        uiSummary: "Hax 浏览器：搜索（百度优先）/ 打开网页 / 读正文 / 点按填表",
        prerequisites: []
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = (params["command"] as? String)?.lowercased(), !command.isEmpty else {
            throw MCPError.invalidParams("command required: search / open / snapshot / text / click / type / eval / wait / back / reload / status")
        }
        AuditLog.shared.log("haxbrowser", detail: command)
        HaxBrowser.markAIActive(true)

        switch command {
        case "search":   return try search(params)
        case "open":     return try openURL(params)
        case "snapshot": return try snapshot(params)
        case "text":     return text(params)
        case "click":    return try click(params)
        case "type":     return try type(params)
        case "eval":     return try eval(params)
        case "wait":     return wait(params)
        case "back":
            _ = HaxBrowser.sync { HaxBrowser.shared.goBack() }
            _ = HaxBrowser.waitUntilLoaded(maxSeconds: 8)
            return ["ok": true, "url": currentURL()]
        case "reload":
            _ = HaxBrowser.sync { HaxBrowser.shared.reload() }
            _ = HaxBrowser.waitUntilLoaded(maxSeconds: 10)
            return ["ok": true, "url": currentURL()]
        case "status":
            return status()
        default:
            throw MCPError.invalidParams("未知子命令：\(command)。可用：search / open / snapshot / text / click / type / eval / wait / back / reload / status")
        }
    }

    // MARK: 各子命令

    private func search(_ params: [String: Any]) throws -> [String: Any] {
        guard let q = params["query"] as? String, !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPError.invalidParams("query required")
        }
        let preferred: HaxSearchEngine? = (params["engine"] as? String)
            .flatMap { HaxSearchEngine(rawValue: $0.lowercased()) }
        // 先确保有 webView（用户可能还没打开过 Hax 页）
        let result = HaxBrowser.performSearch(q, engine: preferred, waitSeconds: 12)

        var out: [String: Any] = [
            "ok": result.ok,
            "engine": result.engine.displayName,
            "url": currentURL(),
            "title": currentTitle()
        ]
        if !result.ok {
            out["note"] = "搜索页没有解析到结果容器，正文可能仍可用——继续用 snapshot 查看。"
        }
        // 顺手把正文一起带回去，省一次调用
        let snap = HaxBrowser.snapshot()
        out["text"] = String(snap.text.prefix(4000))
        out["elements"] = snap.elements.prefix(20).map { ["idx": $0.idx, "label": $0.label, "href": $0.href ?? ""] }
        return out
    }

    /// v7.1.2：方法名不叫 open——会与 SwiftUI/UIApplication 的 open(_:) 重载产生歧义（CI 报 ambiguous use of open）
    private func openURL(_ params: [String: Any]) throws -> [String: Any] {
        guard let u = params["url"] as? String, !u.isEmpty else {
            throw MCPError.invalidParams("url required")
        }
        HaxBrowser.performLoad(u)
        let loaded = HaxBrowser.waitUntilLoaded(maxSeconds: 15)
        var out: [String: Any] = ["ok": loaded, "url": currentURL(), "title": currentTitle()]
        let lastErr: String? = HaxBrowser.sync(timeout: 5) { HaxBrowser.shared.lastError } ?? nil
        if let e: String = lastErr {
            out["error"] = e
        }
        out["text"] = String(HaxBrowser.readPageText(maxChars: 3000))
        return out
    }

    private func snapshot(_ params: [String: Any]) throws -> [String: Any] {
        let chars = min(max(params["chars"] as? Int ?? 8000, 500), 30000)
        let snap = HaxBrowser.snapshot()
        var out: [String: Any] = [
            "ok": true,
            "title": snap.title,
            "url": snap.url,
            "text": String(snap.text.prefix(chars)),
            "count": snap.elements.count
        ]
        out["elements"] = snap.elements.map { e -> [String: Any] in
            var d: [String: Any] = ["idx": e.idx, "tag": e.tag, "label": e.label]
            if !e.role.isEmpty { d["role"] = e.role }
            if let h = e.href { d["href"] = h }
            return d
        }
        return out
    }

    private func text(_ params: [String: Any]) -> [String: Any] {
        let chars = min(max(params["chars"] as? Int ?? 8000, 500), 30000)
        return [
            "ok": true,
            "title": currentTitle(),
            "url": currentURL(),
            "text": String(HaxBrowser.readPageText(maxChars: chars).prefix(chars))
        ]
    }

    private func click(_ params: [String: Any]) throws -> [String: Any] {
        if let sel = params["selector"] as? String, !sel.isEmpty {
            let r = HaxBrowser.clickSelector(sel)
            _ = HaxBrowser.waitUntilLoaded(maxSeconds: 8)
            return ["ok": r.contains("clicked"), "result": r, "url": currentURL()]
        }
        guard let idx = params["idx"] as? Int else {
            throw MCPError.invalidParams("idx 或 selector 必须给一个")
        }
        let r = HaxBrowser.click(idx: idx)
        // 点了链接会导航，等一下让页面稳住
        Thread.sleep(forTimeInterval: 0.4)
        _ = HaxBrowser.waitUntilLoaded(maxSeconds: 8)
        return ["ok": r.contains("clicked"), "result": r, "url": currentURL(), "title": currentTitle()]
    }

    private func type(_ params: [String: Any]) throws -> [String: Any] {
        guard let idx = params["idx"] as? Int else {
            throw MCPError.invalidParams("idx required")
        }
        guard let t = params["text"] as? String else {
            throw MCPError.invalidParams("text required")
        }
        let r = HaxBrowser.type(idx: idx, text: t)
        return ["ok": r.contains("typed"), "result": r]
    }

    private func eval(_ params: [String: Any]) throws -> [String: Any] {
        guard let js = params["js"] as? String, !js.isEmpty else {
            throw MCPError.invalidParams("js required")
        }
        let r = HaxBrowser.evalSync(js)
        return ["ok": true, "result": r.map { String(describing: $0) } ?? "nil"]
    }

    private func wait(_ params: [String: Any]) -> [String: Any] {
        let secs = min(max(params["seconds"] as? Int ?? 10, 1), 60)
        let ok = HaxBrowser.waitUntilLoaded(maxSeconds: Double(secs))
        return ["ok": ok, "url": currentURL(), "loaded": ok]
    }

    private func status() -> [String: Any] {
        let st = HaxBrowser.state()
        return [
            "url": st.url,
            "title": st.title,
            "loading": st.isLoading,
            "default_engine": st.engineName
        ]
    }

    private func currentURL() -> String { HaxBrowser.state().url }
    private func currentTitle() -> String { HaxBrowser.state().title }
}

// MARK: - v7.0.0 Hax 浏览器界面（嵌在 Hax 电脑页里，也可全屏弹出）

struct HaxBrowserView: View {
    @ObservedObject private var browser = HaxBrowser.shared
    /// 嵌入模式（Hax 电脑页里的那一块）不显示关闭按钮
    var embedded: Bool = true
    var onClose: (() -> Void)? = nil

    @State private var address: String = ""
    @State private var showEngineMenu = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if browser.isLoading {
                ProgressView(value: browser.progress)
                    .progressViewStyle(.linear)
                    .tint(DoubaoTheme.accent)
                    .frame(height: 2)
            } else {
                Divider().opacity(0.4)
            }
            WebViewHost(webView: browser.webView)
                .overlay(alignment: .center) {
                    if let err = browser.lastError, browser.currentURL.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 26))
                                .foregroundColor(.secondary)
                            Text(err)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    }
                }
            if embedded {
                Divider().opacity(0.4)
                bottomBar
            }
        }
        .background(DoubaoTheme.bg)
        .onAppear {
            address = browser.currentURL
            if browser.currentURL.isEmpty {
                // 第一次打开：直接停在百度首页，方便手动输入
                browser.load("https://www.baidu.com")
            }
        }
        .onChange(of: browser.currentURL) { newValue in
            if !addressFocused { address = newValue }
        }
    }

    // MARK: 顶部工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { browser.goBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
            }
            .disabled(!browser.canGoBack)
            .buttonStyle(PlainButtonStyle())

            Button { browser.goForward() } label: {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
            }
            .disabled(!browser.canGoForward)
            .buttonStyle(PlainButtonStyle())

            // 地址栏（输入非网址自动走搜索）
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundColor(browser.currentURL.hasPrefix("https") ? .green : .secondary)
                TextField("搜索或输入网址", text: $address)
                    .font(.system(size: 13))
                    .focused($addressFocused)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .submitLabel(.go)
                    .onSubmit {
                        browser.load(address)
                        addressFocused = false
                    }
                if !address.isEmpty {
                    Button { address = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(DoubaoTheme.card))
            .overlay(Capsule().stroke(Color(UIColor.separator).opacity(0.4), lineWidth: 0.7))

            // 搜索引擎切换（百度为默认）
            Menu {
                ForEach(HaxSearchEngine.fallbackOrder) { e in
                    Button {
                        browser.engine = e
                    } label: {
                        Label(e.displayName + (e == browser.engine ? "（默认）" : ""),
                              systemImage: e == browser.engine ? "checkmark" : "circle")
                    }
                }
                Divider()
                Toggle("请求桌面版页面", isOn: Binding(
                    get: { browser.desktopMode },
                    set: { browser.desktopMode = $0 }
                ))
            } label: {
                Text(browser.engine.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DoubaoTheme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Capsule().fill(DoubaoTheme.accent.opacity(0.12)))
            }

            if !embedded, let onClose = onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: 底部（搜索框 + 快捷引擎）

    private var bottomBar: some View {
        HStack(spacing: 8) {
            ForEach([HaxSearchEngine.baidu, .bing, .sogou, .google]) { e in
                Button {
                    browser.engine = e
                    if !address.isEmpty, address.hasPrefix("http") {
                        // 把当前网址当搜索词不合适，这里只切默认引擎
                    }
                } label: {
                    Text(e.displayName)
                        .font(.system(size: 12, weight: e == browser.engine ? .semibold : .regular))
                        .foregroundColor(e == browser.engine ? DoubaoTheme.accent : DoubaoTheme.subText)
                }
                .buttonStyle(PlainButtonStyle())
            }
            Spacer()
            Button { browser.reload() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(PlainButtonStyle())
            if browser.aiActive {
                Text("AI 正在浏览")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DoubaoTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}

/// 把已有的 WKWebView 塞进 SwiftUI（复用同一个实例，AI 和用户看到的是同一个页面）
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 全屏 Hax 浏览器页（Hax 电脑 → 打开 Hax 浏览器）

struct HaxBrowserFullView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HaxBrowserView(embedded: false, onClose: { dismiss() })
            .navigationTitle("Hax 浏览器")
            .navigationBarTitleDisplayMode(.inline)
    }
}
