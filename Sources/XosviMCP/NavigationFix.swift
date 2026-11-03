import UIKit

// MARK: - v8.4：恢复系统侧滑返回手势
//
// 设置二级页/自定义返回按钮的页面用了 navigationBarBackButtonHidden(true)（或自定义
// 返回按钮）时，iOS 会同时禁用 interactivePopGestureRecognizer——这是 UIKit 的既定行为。
// 这里给 UINavigationController 重新挂上代理（全项目生效，放一次即可）。
//
// 注意：gestureRecognizerShouldBegin 里只在栈深 >1 时接管——根视图接管会让首次侧滑
// 动画卡死；shouldRecognizeSimultaneously 返回 false 与列表左滑删除互斥，防手势打架。

extension UINavigationController: UIGestureRecognizerDelegate {
    open override func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        interactivePopGestureRecognizer?.isEnabled = true
    }

    public func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1          // 只有一层时别接管，避免动画卡死
    }

    public func gestureRecognizer(_ g: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false                              // 与列表横滑（左滑删除）互斥，防手势打架
    }
}
