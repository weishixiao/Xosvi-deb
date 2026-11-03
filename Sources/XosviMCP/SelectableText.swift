import SwiftUI
import UIKit

/// v4.4.21：可划词选择的只读富文本视图——用 UITextView 原生长按选字/拖手柄划词/复制菜单。
/// iOS 15 的 SwiftUI `textSelection(.enabled)` 长按只能直接全选、没有划词手柄，无法选词/选句；
/// UITextView 是 UIKit 原生文本选择，任意 iOS 版本都稳定支持长按放大镜定位 + 拖手柄划词 + 复制/朗读。
///
/// v8.6：`[cite:sN]` 引用角标点击 —— CitationRenderer 在角标字符上挂 `.citationURL` 自定义属性，
/// 这里加一个 tap 手势做字符命中测试：点中角标 → 回调 URL → 上层确认后用系统浏览器打开。
/// 不用 `.link` 属性：isSelectable 的 UITextView 里 link 需要 delegate 才能拦，且会和长按划词
/// 手势互相抢，行为不可控；自定义属性 + 命中测试只影响角标那几个字符，其余手势不变。
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString
    var textColor: UIColor = .label
    var fontSize: CGFloat = 17
    /// v8.6：点击引用角标回调（nil 表示不接收点击，保持纯选择行为）
    var onTapCitation: ((URL) -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textColor = textColor
        tv.font = .systemFont(ofSize: fontSize)
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        // 允许文字区仍可长按选择，但不让滚动
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        if onTapCitation != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleTap(_:)))
            // 不抢 UITextView 自带的长按/双击选择手势
            tap.cancelsTouchesInView = false
            tap.delegate = context.coordinator
            tv.addGestureRecognizer(tap)
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.onTap = onTapCitation
        tv.textColor = textColor
        tv.font = .systemFont(ofSize: fontSize)
        tv.attributedText = attributed
        tv.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTapCitation) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: ((URL) -> Void)?

        init(onTap: ((URL) -> Void)?) {
            self.onTap = onTap
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let tv = g.view as? UITextView else { return }
            guard let handler = onTap else { return }
            guard let attributed = tv.attributedText, attributed.length > 0 else { return }
            // 有选区时不拦截——用户是在选字，不是在点角标
            if tv.selectedRange.length > 0 { return }

            let point = g.location(in: tv)
            // 用 UITextInput 的字符位置 API（TextKit 1/2 都成立，不依赖 layoutManager）
            guard let pos = tv.closestPosition(to: point) else { return }
            let index = tv.offset(from: tv.beginningOfDocument, to: pos)
            guard index >= 0, index < attributed.length else { return }

            // 只认「该字符本身占的矩形」——点在行尾留白/卡片空白处不触发。
            // firstRect 返回屏幕坐标，先转回视图坐标；TextKit2 下偶尔拿不到，拿不到就只做属性判定。
            if let end = tv.position(from: pos, offset: 1),
               let range = tv.textRange(from: pos, to: end) {
                let screenRect = tv.firstRect(for: range)          // 屏幕坐标
                let windowRect = tv.window?.convert(screenRect, from: nil) ?? screenRect
                let localRect = tv.convert(windowRect, from: nil)  // → textView 坐标
                guard localRect.insetBy(dx: -6, dy: -8).contains(point) else { return }
            }

            let attrs = attributed.attributes(at: index, effectiveRange: nil)
            guard let url = attrs[.citationURL] as? URL else { return }
            handler(url)
        }

        /// 与 UITextView 自己的长按/选择手势共存
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    // v4.5.0：sizeThatFits(proposal:) 是 iOS16+ 的 UIViewRepresentable 协议方法，
    // iOS15 编译会报 ProposedViewSize unavailable —— 用 @available 限定，
    // iOS15 靠 UITextView intrinsicContentSize（updateUIView 已 invalidate）自适应高度
    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let maxWidth = proposal.width ?? (UIScreen.main.bounds.width - 40)
        // v8.6：宽度贴合内容——先量不换行时的自然宽度，再与上限取小，
        // 短消息的气泡不会被 UITextView 默认的「撑满」拉成一条长卡片。
        let natural = uiView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: .greatestFiniteMagnitude)).width
        let wrapped = uiView.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(natural), maxWidth), height: wrapped.height)
    }
}
