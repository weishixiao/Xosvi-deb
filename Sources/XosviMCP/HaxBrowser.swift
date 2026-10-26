import Foundation
import WebKit
import Combine
import SwiftUI

// MARK: - v7.0.0 Hax 浏览器（HaxBrowser）
//
// 从零重写的内置浏览器，取代 v2.9.37 那套 FloatingBrowser / BrowserManager / WebBrowserTools。
//
// 设计目标：
//   1. AI 思考/查资料时主动调用它——`haxbrowser` 工具（百度搜索为默认引擎、Bing/Sogou/Google 备用）
//   2. 用户能直接看见 AI 在页面上做什么——嵌在「Hax 电脑」页里，也可以全屏弹出
//   3. 只有一份 WKWebView：UI 和 MCP 工具共用同一实例，不存在"AI 开了个看不见的浏览器"
//
// 与"网页抓取"的分工：
//   - 结构化网页抓取（批量、多引擎、出结果列表）仍走 `web.search` / `web.fetch`（URLSession，快、省内存）
//   - 需要**真实渲染**的页面（JS 渲染、登录态、点链接、填表单、读渲染后的正文）走这里的浏览器
//
// 线程模型：WKWebView 只能在主线程用；MCP 工具在后台线程被调用，
// 所以所有交互都 `主线程执行 + 信号量等结果`（带超时，不会把工具卡死）。

// MARK: - 搜索引擎

/// 搜索引擎。百度是默认，其余为备用/后缀切换。
enum HaxSearchEngine: String, CaseIterable, Identifiable {
    case baidu, bing, sogou, so360, google, duckduckgo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .baidu: return "百度"
        case .bing: return "必应"
        case .sogou: return "搜狗"
        case .so360: return "360"
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        }
    }

    /// 备用顺序：百度 → 必应 → 搜狗 → 360 → Google → DuckDuckGo
    static var fallbackOrder: [HaxSearchEngine] {
        [.baidu, .bing, .sogou, .so360, .google, .duckduckgo]
    }

    func url(for query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let s: String
        switch self {
        case .baidu:       s = "https://www.baidu.com/s?ie=utf-8&wd=\(q)"
        case .bing:        s = "https://cn.bing.com/search?q=\(q)"
        case .sogou:       s = "https://www.sogou.com/web?query=\(q)"
        case .so360:       s = "https://www.so.com/s?q=\(q)"
        case .google:      s = "https://www.google.com/search?q=\(q)"
        case .duckduckgo:  s = "https://duckduckgo.com/?q=\(q)"
        }
        return URL(string: s)
    }

    /// 结果页的就绪判断选择器（DOM 里出现这个才算搜索结果加载完）
    var resultsReadySelector: String {
        switch self {
        case .baidu:      return "#content_left .result, #content_left .c-container"
        case .bing:       return "#b_results .b_algo"
        case .sogou:      return ".vrwrap, .results .rb"
        case .so360:      return ".result, .res-list"
        case .google:     return "#search .g, #rso"
        case .duckduckgo: return ".result, article"
        }
    }
}

// MARK: - 页面快照

/// AI 看页面用的结构化快照：正文 + 可点/可填元素（带编号）
struct HaxPageSnapshot {
    var title: String
    var url: String
    var text: String
    /// 编号 → 元素描述，AI 用 idx 去点/填
    var elements: [HaxPageElement]

    struct HaxPageElement {
        var idx: Int
        var tag: String
        var role: String
        var label: String
        var href: String?
    }

    var summary: String {
        var lines = ["标题：\(title)", "网址：\(url)", "正文长度：\(text.count) 字"]
        if !elements.isEmpty {
            lines.append("可交互元素：")
            for e in elements {
                let tail = e.href.map { " → \($0)" } ?? ""
                lines.append("  [\(e.idx)] \(e.tag)\(e.role.isEmpty ? "" : "(\(e.role))") \(e.label)\(tail)")
            }
        }
        lines.append("")
        lines.append("正文：")
        lines.append(String(text.prefix(6000)))
        return lines.joined(separator: "\n")
    }
}

// MARK: - 浏览器主体

@MainActor
final class HaxBrowser: NSObject, ObservableObject {

    static let shared = HaxBrowser()

    // UI 状态
    @Published var currentURL: String = ""
    @Published var pageTitle: String = ""
    @Published var isLoading: Bool = false
    @Published var progress: Double = 0
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var lastError: String? = nil
    /// 最近一次搜索用的引擎（UI 上显示）
    @Published var lastEngine: HaxSearchEngine? = nil
    /// AI 调用时外部可观察（用来在 Hax 页顶部提示"AI 正在浏览"）
    @Published var aiActive: Bool = false

    /// 默认搜索引擎（默认百度，持久化到 UserDefaults）
    var engine: HaxSearchEngine {
        get { HaxSearchEngine(rawValue: UserDefaults.standard.string(forKey: "haxbrowser.engine") ?? "") ?? .baidu }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "haxbrowser.engine")
            objectWillChange.send()
        }
    }

    /// 请求桌面版站点（很多搜索结果页移动版结构不稳，默认桌面版）
    var desktopMode: Bool {
        get {
            if UserDefaults.standard.object(forKey: "haxbrowser.desktop") == nil { return true }
            return UserDefaults.standard.bool(forKey: "haxbrowser.desktop")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "haxbrowser.desktop")
            applyUserAgent()
            objectWillChange.send()
        }
    }

    private(set) lazy var webView: WKWebView = makeWebView()
    private var observations: [NSKeyValueObservation] = []
    private var navContinuations: [UUID: () -> Void] = [:]

    private override init() {
        super.init()
        _ = webView   // 预热（首次比较慢，提前创建）
    }

    // MARK: WebView 构建

    private func makeWebView() -> WKWebView {
        let cfg = WKWebpagePreferences()
        cfg.allowsContentJavaScript = true
        let conf = WKWebViewConfiguration()
        conf.defaultWebpagePreferences = cfg
        // 与浏览器 UI 共用一个进程池，减少内存
        conf.processPool = WKProcessPool()
        conf.preferences.javaScriptCanOpenWindowsAutomatically = false

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: conf)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.customUserAgent = Self.desktopUserAgent
        wv.isOpaque = false
        wv.backgroundColor = .clear

        observations = [
            wv.observe(\.url, options: [.new]) { [weak self] wv, _ in
                guard let self else { return }
                let u = wv.url?.absoluteString ?? ""
                DispatchQueue.main.async {
                    if self.currentURL != u { self.currentURL = u }
                    if wv.title != self.pageTitle { self.pageTitle = wv.title ?? "" }
                }
            },
            wv.observe(\.title, options: [.new]) { [weak self] wv, _ in
                guard let self else { return }
                let t = wv.title ?? ""
                DispatchQueue.main.async { if self.pageTitle != t { self.pageTitle = t } }
            },
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                let p = wv.estimatedProgress
                DispatchQueue.main.async { self?.progress = p }
            },
            wv.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.canGoBack = wv.canGoBack }
            },
            wv.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.canGoForward = wv.canGoForward }
            },
            wv.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.isLoading = wv.isLoading }
            }
        ]
        return wv
    }

    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"

    func applyUserAgent() {
        webView.customUserAgent = desktopMode ? Self.desktopUserAgent : Self.mobileUserAgent
    }

    // MARK: 导航

    func load(_ urlString: String) {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return }
        if !s.contains("://") {
            // 不像是网址 → 当搜索词处理（体验接近浏览器地址栏）
            s = looksLikeURL(s) ? "https://" + s : "https://www.baidu.com/s?ie=utf-8&wd=\(s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s)"
        }
        guard let u = URL(string: s) else { lastError = "网址无效：\(urlString)"; return }
        lastError = nil
        let req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        webView.load(req)
    }

    private func looksLikeURL(_ s: String) -> Bool {
        if s.contains(" ") { return false }
        return s.contains(".") && (s.range(of: "^[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$", options: .regularExpression) != nil)
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    func clearCookies() {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: types, modifiedSince: .distantPast) {}
    }

    // MARK: 同步封装（给后台线程的 MCP 工具用）

    /// 主线程执行并同步等待结果（超时返回 nil，避免工具挂死）
    static func sync<T>(timeout: TimeInterval = 20, _ work: @escaping @MainActor () -> T) -> T? {
        if Thread.isMainThread {
            // 主线程上不能同步等待自己 → 直接执行
            return MainActor.assumeIsolated { work() } as T?
        }
        let sem = DispatchSemaphore(value: 0)
        var result: T?
        DispatchQueue.main.async {
            let r = work()
            result = r
            sem.signal()
        }
        return sem.wait(timeout: .now() + timeout) == .success ? result : nil
    }

    /// 等待页面加载完成（loading 变 false）
    static func waitUntilLoaded(maxSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(maxSeconds)
        while Date() < deadline {
            let loading = HaxBrowser.sync { HaxBrowser.shared.webView.isLoading } ?? false
            let progress = HaxBrowser.sync { HaxBrowser.shared.webView.estimatedProgress } ?? 1
            if !loading && progress >= 0.99 { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// 执行 JS 并同步取回 JSON 结果
    static func evalSync(_ js: String, timeout: TimeInterval = 15) -> Any? {
        let sem = DispatchSemaphore(value: 0)
        var out: Any?
        DispatchQueue.main.async {
            HaxBrowser.shared.webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    Log.browser("eval error: \(error.localizedDescription)")
                }
                out = result
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + timeout)
        return out
    }

    /// 执行 JS 字符串结果
    static func evalStringSync(_ js: String, timeout: TimeInterval = 15) -> String {
        guard let v = evalSync(js, timeout: timeout) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    // MARK: 线程安全快照（给后台线程的 MCP 工具用，跨 actor 读不到属性）

    /// 只读状态快照——工具在后台线程安全取用
    struct PublicState {
        var url: String
        var title: String
        var isLoading: Bool
        var engineName: String
    }

    nonisolated static func state() -> PublicState {
        let box = Box<PublicState>(PublicState(url: "", title: "", isLoading: false, engineName: "百度"))
        DispatchQueue.main.sync {
            let b = HaxBrowser.shared
            box.value = PublicState(url: b.webView.url?.absoluteString ?? b.currentURL,
                                    title: b.webView.title ?? b.pageTitle,
                                    isLoading: b.webView.isLoading,
                                    engineName: b.engine.displayName)
        }
        return box.value
    }

    /// 后台线程入口：切到主线程执行搜索并同步等结果
    nonisolated static func performSearch(_ query: String, engine preferred: HaxSearchEngine?,
                                          waitSeconds: Double) -> (engine: HaxSearchEngine, ok: Bool) {
        let box = Box<(engine: HaxSearchEngine, ok: Bool)>((preferred ?? .baidu, false))
        DispatchQueue.main.sync {
            box.value = HaxBrowser.shared.search(query, engine: preferred, waitSeconds: waitSeconds)
        }
        return box.value
    }

    /// 后台线程入口：打开网址
    nonisolated static func performLoad(_ url: String) {
        DispatchQueue.main.sync { HaxBrowser.shared.load(url) }
    }

    /// 后台线程入口：标记 AI 正在浏览
    nonisolated static func markAIActive(_ on: Bool) {
        DispatchQueue.main.async { HaxBrowser.shared.aiActive = on }
    }

    // MARK: 页面读取

    /// 读取渲染后的正文（去脚本/样式/导航栏）
    static func readPageText(maxChars: Int = 12000) -> String {
        let js = """
        (function(){
          var junk = 'script,style,noscript,nav,footer,header,aside,iframe,svg,form[style*="display:none"]';
          var c = document.body ? document.body.cloneNode(true) : null;
          if (!c) return '';
          c.querySelectorAll(junk).forEach(function(n){ n.remove(); });
          var t = (c.innerText || c.textContent || '');
          t = t.replace(/\\n{3,}/g, '\\n\\n').replace(/[ \\t]{2,}/g, ' ');
          return t.trim().slice(0, \(maxChars));
        })()
        """
        return evalStringSync(js)
    }

    /// 可交互元素编号表（链接 / 按钮 / 输入框），AI 用 idx 点击或填字
    static func interactiveElements(limit: Int = 60) -> [HaxPageSnapshot.HaxPageElement] {
        let js = """
        (function(){
          var out = [];
          var sel = 'a[href], button, input, textarea, [role=button], [onclick], select';
          var nodes = document.querySelectorAll(sel);
          var i = 0;
          for (var k = 0; k < nodes.length && out.length < \(limit); k++) {
            var n = nodes[k];
            var r = n.getBoundingClientRect();
            var st = window.getComputedStyle(n);
            if (r.width < 4 || r.height < 4) continue;
            if (st.visibility === 'hidden' || st.display === 'none' || st.opacity === '0') continue;
            var label = (n.innerText || n.value || n.getAttribute('aria-label') || n.getAttribute('placeholder') || n.title || '');
            label = label.replace(/\\s+/g, ' ').trim().slice(0, 60);
            if (!label) continue;
            out.push({
              idx: i++,
              tag: n.tagName.toLowerCase(),
              role: (n.getAttribute('type') || n.getAttribute('role') || ''),
              label: label,
              href: n.tagName === 'A' ? (n.href || '').slice(0, 200) : ''
            });
            n.setAttribute('data-haxb-idx', String(i - 1));
          }
          return JSON.stringify(out);
        })()
        """
        guard let raw = evalSync(js) as? String,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let idx = d["idx"] as? Int else { return nil }
            return HaxPageSnapshot.HaxPageElement(
                idx: idx,
                tag: d["tag"] as? String ?? "",
                role: d["role"] as? String ?? "",
                label: d["label"] as? String ?? "",
                href: (d["href"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    static func snapshot() -> HaxPageSnapshot {
        let title = sync { HaxBrowser.shared.webView.title ?? "" } ?? ""
        let url = sync { HaxBrowser.shared.webView.url?.absoluteString ?? "" } ?? ""
        let elements = interactiveElements()
        let raw = readPageText()
        // 正文太长时，优先保留搜索结果区域（省 token 又准）
        var text = raw
        if raw.count > 6000 {
            let focused = evalStringSync("""
            (function(){
              var zone = document.querySelector('#content_left, #b_results, #search, #rso, .results');
              var t = zone ? (zone.innerText || '') : '';
              return t.replace(/\\n{3,}/g,'\\n\\n').trim().slice(0, 6000);
            })()
            """)
            if focused.count > 400 { text = focused }
        }
        return HaxPageSnapshot(title: title, url: url, text: text, elements: elements)
    }

    /// 点击编号元素
    static func click(idx: Int) -> String {
        let js = """
        (function(){
          var n = document.querySelector('[data-haxb-idx="\(idx)"]');
          if (!n) return 'not_found';
          n.scrollIntoView({block:'center'});
          n.click();
          return 'clicked:' + (n.innerText || n.tagName).slice(0,40);
        })()
        """
        let r = evalStringSync(js)
        return r.isEmpty ? "not_found" : r
    }

    /// 往编号元素填字（输入框 / textarea / 搜索框）
    static func type(idx: Int, text: String) -> String {
        let escaped = jsonEscape(text)
        let js = """
        (function(){
          var n = document.querySelector('[data-haxb-idx="\(idx)"]');
          if (!n) return 'not_found';
          n.focus();
          var proto = n.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) setter.set.call(n, "\(escaped)");
          else n.value = "\(escaped)";
          n.dispatchEvent(new Event('input', {bubbles:true}));
          n.dispatchEvent(new Event('change', {bubbles:true}));
          return 'typed';
        })()
        """
        let r = evalStringSync(js)
        return r.isEmpty ? "failed" : r
    }

    /// 在页面上按 CSS 选择器点击（比编号更稳，适合固定站点）
    static func clickSelector(_ selector: String) -> String {
        let js = """
        (function(){
          var n = document.querySelector("\(jsonEscape(selector))");
          if (!n) return 'not_found';
          n.scrollIntoView({block:'center'});
          n.click();
          return 'clicked';
        })()
        """
        let r = evalStringSync(js)
        return r.isEmpty ? "not_found" : r
    }

    /// JSON 字符串转义（防止把引号/换行塞进 JS 字面量）
    static func jsonEscape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    // MARK: 搜索（百度优先 + 自动回退）

    /// 打开搜索结果页：先用指定/默认引擎，页面没出结果就按备用顺序换引擎。
    /// - Returns: (最终引擎, 是否拿到结果)
    @discardableResult
    func search(_ query: String, engine preferred: HaxSearchEngine? = nil,
                waitSeconds: Double = 12) -> (engine: HaxSearchEngine, ok: Bool) {
        var order: [HaxSearchEngine] = [preferred ?? engine]
        for e in HaxSearchEngine.fallbackOrder where !order.contains(e) { order.append(e) }
        for e in order {
            guard let u = e.url(for: query) else { continue }
            lastEngine = e
            let req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            webView.load(req)
            _ = HaxBrowser.waitUntilLoaded(maxSeconds: waitSeconds)
            // 结果页就绪判断：出现结果容器 或 正文里已经有明显关键词
            let hit = HaxBrowser.evalStringSync("document.querySelectorAll(\"\(e.resultsReadySelector)\").length").isEmpty ? false : true
            let bodyLen = HaxBrowser.readPageText(maxChars: 4000).count
            if hit || bodyLen > 800 {
                return (e, hit || bodyLen > 800)
            }
            Log.browser("\(e.displayName) 结果为空，换下一个引擎")
        }
        return (lastEngine ?? .baidu, false)
    }
}

// MARK: - WKNavigationDelegate

extension HaxBrowser: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        lastError = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        // -999 是"被新导航取消"，不是错误
        if (error as NSError).code != -999 { lastError = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url?.absoluteString ?? currentURL
        pageTitle = webView.title ?? ""
    }

    // 新窗口 / target=_blank 一律在当前页面打开
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url,
           let scheme = u.scheme?.lowercased(),
           !["http", "https", "about", "file", "data"].contains(scheme) {
            // tel: / mailto: / alipay: 等交给系统
            UIApplication.shared.open(u, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

extension HaxBrowser: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let u = navigationAction.request.url {
            webView.load(URLRequest(url: u))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

/// 可变盒子：跨线程传递结果用（iOS15 没有 Mutex，用简单类代替）
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - 轻量日志

enum Log {
    static func browser(_ msg: String) {
        #if DEBUG
        print("[HaxBrowser] \(msg)")
        #endif
    }
}
