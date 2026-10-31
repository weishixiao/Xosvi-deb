import Foundation

// MARK: - v7.5.0 网页全文读取（移植自 Kelivo 的 WebFetchCapable）
//
// 目标：搜索完能把命中页面的**正文**读回来给模型，而不是只有一行摘要。
//
// 三级回退（与 Kelivo 的思路一致，但按本项目的「无浏览器」前提调整）：
//   ① 服务商自带的读页接口（Tavily extract / Jina Reader / 秘塔 / Firecrawl / 博查 / Exa）
//      —— 走同一份 Key 和额度，成功率最高
//   ② 公共 Jina Reader（r.jina.ai）—— 免费无需 Key，能把 JS 渲染的页面转成 Markdown
//   ③ 本地直连抓取 + 原生正文抽取 —— 最快、无需网络代理，但**读不了 JS 渲染的页面**，
//      遇到反爬（Cloudflare 挑战页、需要登录、纯前端渲染）会拿到空壳 HTML
//
// 能力边界（会原样写进工具返回，避免 AI 误判为"页面没内容"）：
//   本地抓取无法处理需要 JavaScript 渲染或有反爬限制的页面。
//   这类页面需要先在设置里给搜索服务商填 Key（走它的 reader），或接受只拿到静态 HTML。

struct WebPage {
    var url: String
    var title: String
    var content: String
    var via: String          // 实际用的通道：provider / jina / local
    var truncated: Bool = false
    /// v7.16.11：被反爬/人机验证拦截——content 是错误说明，不是页面正文，**不要喂给模型当资料**
    var blocked: Bool = false
}

enum WebFetchService {

    /// 单页最多返回多少字符（Kelivo 用 100000，这里按上下文预算收到 60000）
    static let maxChars = 60000

    static func fetch(url: String, preferProvider: SearchProvider? = nil) -> WebPage {
        // ① 服务商专属 reader
        if let p = preferProvider ?? providerWithFetch() {
            if let page = providerFetch(p, url: url) { return page }
        }
        // ② 公共 Jina Reader（能读 JS 渲染页）
        if let page = jinaReader(url: url) { return page }
        // ③ 本地直连 + 原生抽取
        return localFetch(url: url)
    }

    /// 找一个既配置了 Key 又支持读页的服务商（按用户默认服务商优先）
    private static func providerWithFetch() -> SearchProvider? {
        let s = SearchSettings.shared
        let order: [SearchProvider] = [s.defaultProvider] + s.usableProviders()
        for p in order where p.supportsFetch {
            if !s.config(for: p).primaryKey.isEmpty { return p }
        }
        return nil
    }

    // MARK: ① 服务商 reader

    private static func providerFetch(_ p: SearchProvider, url: String) -> WebPage? {
        let key = SearchSettings.shared.nextKey(for: p)
        guard !key.isEmpty else { return nil }

        switch p {
        case .tavily:
            let (json, _) = WebSearchService.postJSON(
                "https://api.tavily.com/extract",
                body: ["urls": [url]],
                headers: ["Authorization": "Bearer \(key)"])
            guard let d = json as? [String: Any],
                  let arr = d["results"] as? [[String: Any]],
                  let first = arr.first,
                  let content = first["raw_content"] as? String, !content.isEmpty else { return nil }
            return clip(WebPage(url: url, title: (first["title"] as? String) ?? "", content: content, via: "Tavily"))

        case .jina:
            var headers = ["Accept": "text/plain"]
            headers["Authorization"] = "Bearer \(key)"
            let (text, _) = WebSearchService.getText("https://r.jina.ai/\(url)", headers: headers)
            guard let t = text, t.count > 80 else { return nil }
            return clip(WebPage(url: url, title: firstHeading(t), content: t, via: "Jina"))

        case .metaso:
            let (json, _) = WebSearchService.postJSON(
                "https://metaso.cn/api/v1/reader",
                body: ["url": url],
                headers: ["Authorization": "Bearer \(key)"])
            guard let d = json as? [String: Any],
                  let content = (d["content"] as? String) ?? (d["data"] as? [String: Any])?["content"] as? String,
                  !content.isEmpty else { return nil }
            return clip(WebPage(url: url, title: firstHeading(content), content: content, via: "秘塔"))

        case .firecrawl:
            let (json, _) = WebSearchService.postJSON(
                "https://api.firecrawl.dev/v1/scrape",
                body: ["url": url, "formats": ["markdown"]],
                headers: ["Authorization": "Bearer \(key)"])
            guard let d = json as? [String: Any],
                  let data = d["data"] as? [String: Any],
                  let md = data["markdown"] as? String, !md.isEmpty else { return nil }
            return clip(WebPage(url: url, title: (data["metadata"] as? [String: Any])?["title"] as? String ?? firstHeading(md),
                                content: md, via: "Firecrawl"))

        case .bocha:
            // 博查没有独立 reader，借用它的网页解析接口
            let (json, _) = WebSearchService.postJSON(
                "https://api.bochaai.com/v1/web-search",
                body: ["query": url, "count": 1, "summary": true],
                headers: ["Authorization": "Bearer \(key)"])
            guard let d = json as? [String: Any],
                  let data = d["data"] as? [String: Any],
                  let web = data["webPages"] as? [String: Any],
                  let arr = web["value"] as? [[String: Any]],
                  let first = arr.first,
                  let sum = first["summary"] as? String, sum.count > 80 else { return nil }
            return clip(WebPage(url: url, title: (first["name"] as? String) ?? "", content: sum, via: "博查"))

        case .exa:
            let (json, _) = WebSearchService.postJSON(
                "https://api.exa.ai/contents",
                body: ["urls": [url], "text": ["maxCharacters": maxChars]],
                headers: ["x-api-key": key])
            guard let d = json as? [String: Any],
                  let arr = d["results"] as? [[String: Any]],
                  let first = arr.first,
                  let text = first["text"] as? String, !text.isEmpty else { return nil }
            return clip(WebPage(url: url, title: (first["title"] as? String) ?? "", content: text, via: "Exa"))

        default:
            return nil
        }
    }

    // MARK: ② 公共 Jina Reader

    private static func jinaReader(url: String) -> WebPage? {
        let (text, code) = WebSearchService.getText("https://r.jina.ai/\(url)",
                                                   headers: ["Accept": "text/plain"])
        guard let t = text, t.count > 120 else { return nil }
        // 明显是错误页就放弃
        if t.contains("Error 4") && t.count < 400 { return nil }
        _ = code
        return clip(WebPage(url: url, title: firstHeading(t), content: t, via: "Jina Reader"))
    }

    // MARK: ③ 本地直连

    private static func localFetch(url: String) -> WebPage {
        let (html, err) = WebSearchService.getText(url)
        guard let h = html, !h.isEmpty else {
            return WebPage(url: url, title: "", content: "抓取失败：\(err)", via: "local")
        }
        let title = h.firstCapture(pattern: "<title[^>]*>([\\s\\S]*?)</title>")?.stripHTMLTags() ?? ""
        let text = HTMLText.extract(h, maxChars: maxChars)

        // v7.16.11：反爬/人机验证页——抓到的是验证脚本或"请稍候"，不是正文。
        // 以前只按"正文不足 200 字"兜底，长度够的挑战页会当成正常内容喂给模型。
        if let reason = HTMLText.challengeReason(html: h, text: text) {
            return WebPage(url: url, title: title,
                           content: "BLOCKED_BY_CHALLENGE：\(reason)。该页面需要浏览器验证或登录，抓回来的不是正文，已停止解析。",
                           via: "local", blocked: true)
        }

        // 空壳判定：JS 渲染 / 反爬的典型特征
        if text.count < 200 {
            let shell = """
            只拿到 \(h.count) 字节静态 HTML，正文不足 200 字——这个页面很可能依赖 JavaScript 渲染，
            或者有反爬限制（Cloudflare 挑战 / 需要登录）。

            本地抓取无法处理需要 JavaScript 渲染或有反爬限制的页面。
            可以这样解决：①在设置 → 联网搜索里给支持读页的服务商（Tavily / Jina / 秘塔 / Firecrawl）填 API Key，
            会自动走它的 reader；②或换一个提供同样内容的静态站点/文档页。
            """
            return WebPage(url: url, title: title, content: shell, via: "local")
        }
        return clip(WebPage(url: url, title: title, content: text, via: "local"))
    }

    // MARK: 工具

    private static func clip(_ p: WebPage) -> WebPage {
        guard p.content.count > maxChars else { return p }
        var out = p
        out.content = String(p.content.prefix(maxChars)) + "\n\n…（正文过长，已截断到 \(maxChars) 字）"
        out.truncated = true
        return out
    }

    private static func firstHeading(_ md: String) -> String {
        for line in md.components(separatedBy: "\n") where line.hasPrefix("# ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }
}

// MARK: - 原生 HTML → 正文（替代浏览器/阅读模式）

enum HTMLText {
    /// 去脚本/样式/导航，抽 <article>/<main> 优先，退化为全文
    static func extract(_ html: String, maxChars: Int) -> String {
        var s = html
        for junk in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>",
                     "<noscript[\\s\\S]*?</noscript>", "<svg[\\s\\S]*?</svg>",
                     "<nav[\\s\\S]*?</nav>", "<footer[\\s\\S]*?</footer>",
                     "<header[\\s\\S]*?</header>", "<aside[\\s\\S]*?</aside>",
                     "<!--[\\s\\S]*?-->"] {
            s = s.replacingOccurrences(of: junk, with: " ", options: .regularExpression)
        }
        // v7.16.11：常见遮挡/横幅容器（cookie、同意弹窗、订阅栏）。只按窄名单删，避免误伤正文。
        for noise in ["cookie", "consent", "gdpr", "newsletter", "subscribe-popup",
                      "modal-backdrop", "announcement-bar"] {
            let pattern = "<div[^>]+(class|id)=\"[^\"]*" + noise + "[^\"]*\"[\\s\\S]*?</div>"
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // 优先正文容器
        if let art = s.firstCapture(pattern: "<article[^>]*>([\\s\\S]*?)</article>"),
           art.stripHTMLTags().count > 200 {
            s = art
        } else if let main = s.firstCapture(pattern: "<main[^>]*>([\\s\\S]*?)</main>"),
                  main.stripHTMLTags().count > 200 {
            s = main
        }
        var text = s.stripHTMLTags()
        text = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n[ \\t]*\\n[ \\t]*\\n+", with: "\n\n", options: .regularExpression)
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxChars))
    }

    /// v7.16.11：疑似提示注入特征。命中只做标注，绝不执行——网页文字永远是资料。
    static func looksInjected(_ text: String) -> Bool {
        let t = text.lowercased()
        let pats = ["ignore previous", "ignore all previous", "disregard the above",
                    "ignore the above", "system prompt", "you are now",
                    "忽略之前", "忽略上面", "忽略以上", "你现在是", "从现在开始你"]
        return pats.contains { t.contains($0) }
    }

    /// v7.16.11：识别 Cloudflare / 人机验证 / 限流页。命中就返回原因（给上层直接报错，不要当正文）。
    static func challengeReason(html: String, text: String) -> String? {
        let hay = (String(html.prefix(20000)) + "\n" + String(text.prefix(4000))).lowercased()
        let markers: [(String, String)] = [
            ("cf-browser-verification", "Cloudflare 浏览器验证"),
            ("challenge-platform", "Cloudflare 挑战页"),
            ("just a moment", "Cloudflare 挑战页"),
            ("verify you are human", "人机验证"),
            ("checking your browser", "浏览器验证中"),
            ("attention required", "Cloudflare 拦截"),
            ("enable javascript and cookies to continue", "需要 JS + Cookie 才能继续"),
            ("请验证您是真人", "人机验证"),
            ("人机验证", "人机验证"),
            ("访问过于频繁", "限流"),
            ("captcha", "验证码")
        ]
        for (k, v) in markers where hay.contains(k) { return v }
        return nil
    }
}
