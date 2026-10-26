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
    nonisolated static func sync<T>(timeout: TimeInterval = 20, _ work: @escaping @MainActor () -> T) -> T? {
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
    nonisolated static func waitUntilLoaded(maxSeconds: Double) -> Bool {
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
    nonisolated static func evalSync(_ js: String, timeout: TimeInterval = 15) -> Any? {
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
    nonisolated static func evalStringSync(_ js: String, timeout: TimeInterval = 15) -> String {
        guard let v = evalSync(js, timeout: timeout) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    // MARK: 线程安全快照（给后台线程的 MCP 工具用，跨 actor 读不到属性）

    /// 主线程上 `DispatchQueue.main.sync` 会死锁（不能等自己）。
    /// 本方法的调用方都是 MCP 工具（后台线程），所以正常情况走 sync；
    /// 极端情况（有人从主线程调）退化成异步执行并返回 nil 兜底值，绝不卡死 UI。
    nonisolated private static func onMainSync<T>(_ work: @escaping @MainActor () -> T) -> T? {
        if Thread.isMainThread {
            // 不在主线程上等待自身：异步执行，返回 nil 表示"本次没取到"
            DispatchQueue.main.async { _ = work() }
            return nil
        }
        let box = Box<T?>(nil)
        DispatchQueue.main.sync {
            box.value = work()
        }
        return box.value
    }

    /// 只读状态快照——工具在后台线程安全取用
    struct PublicState {
        var url: String
        var title: String
        var isLoading: Bool
        var engineName: String
        /// v7.4.1：默认引擎本身（回退顺序的起点）
        var engineKind: HaxSearchEngine = .baidu
    }

    nonisolated static func state() -> PublicState {
        return onMainSync {
            let b = HaxBrowser.shared
            let kind = b.engine
            return PublicState(url: b.webView.url?.absoluteString ?? b.currentURL,
                               title: b.webView.title ?? b.pageTitle,
                               isLoading: b.webView.isLoading,
                               engineName: kind.displayName,
                               engineKind: kind)
        } ?? PublicState(url: "", title: "", isLoading: false, engineName: "百度", engineKind: .baidu)
    }

    /// 后台线程入口：**加载在主线程、等待在调用线程**——否则 waitUntilLoaded 里的
    /// `DispatchQueue.main.async + semaphore` 会和自己所在的主线程互相等待（死锁，表现为"搜索没用"）。
    /// v7.4.1：同时修正结果判定——原来用 `evalStringSync(...).isEmpty` 判断，
    /// querySelectorAll 返回 "0" 也"非空"，等于永远判定成功，回退逻辑从来没生效过。
    nonisolated static func performSearch(_ query: String, engine preferred: HaxSearchEngine?,
                                          waitSeconds: Double) -> (engine: HaxSearchEngine, ok: Bool) {
        let primary = preferred ?? state().engineKind
        var order: [HaxSearchEngine] = [primary]
        for e in HaxSearchEngine.fallbackOrder where !order.contains(e) { order.append(e) }

        var lastTried: HaxSearchEngine = primary
        for e in order {
            guard let u = e.url(for: query) else { continue }
            lastTried = e
            // ① 主线程：记录引擎并发起导航
            _ = onMainSync { () -> Bool in
                HaxBrowser.shared.lastEngine = e
                HaxBrowser.shared.lastError = nil
                HaxBrowser.shared.webView.load(
                    URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
                return true
            }
            // ② 回调用线程等待（这里绝不能在主线程上同步等待）
            let loaded = waitUntilLoaded(maxSeconds: waitSeconds)
            // ③ 判定：结果容器数量 > 0，或正文够长（有些引擎结果容器 class 会变）
            let sel = jsonEscape(e.resultsReadySelector)
            let countStr = evalStringSync("document.querySelectorAll(\"\(sel)\").length")
            let count = Int(countStr.trimmingCharacters(in: .whitespaces)) ?? 0
            let bodyLen = readPageText(maxChars: 4000).count
            Log.browser("\(e.displayName) loaded=\(loaded) results=\(count) body=\(bodyLen)")
            if count > 0 || bodyLen > 800 {
                return (e, true)
            }
        }
        return (lastTried, false)
    }

    /// 后台线程入口：打开网址
    nonisolated static func performLoad(_ url: String) {
        onMainSync { HaxBrowser.shared.load(url) }
    }

    /// 后台线程入口：标记 AI 正在浏览
    nonisolated static func markAIActive(_ on: Bool) {
        DispatchQueue.main.async { HaxBrowser.shared.aiActive = on }
    }

    // MARK: 页面读取

    /// 读取渲染后的正文（去脚本/样式/导航栏）
    nonisolated static func readPageText(maxChars: Int = 12000) -> String {
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
    nonisolated static func interactiveElements(limit: Int = 60) -> [HaxPageSnapshot.HaxPageElement] {
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

    nonisolated static func snapshot() -> HaxPageSnapshot {
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
    nonisolated static func click(idx: Int) -> String {
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
    nonisolated static func type(idx: Int, text: String) -> String {
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
    nonisolated static func clickSelector(_ selector: String) -> String {
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
    nonisolated static func jsonEscape(_ s: String) -> String {
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

    // MARK: 搜索
    // v7.4.1：原来这里的 @MainActor search() 已删除——它在主线程上等自己必然死锁。
    // 所有搜索走上面的 nonisolated performSearch（加载在主线程、等待在调用线程）。

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
    nonisolated static func browser(_ msg: String) {
        #if DEBUG
        print("[HaxBrowser] \(msg)")
        #endif
    }
}
