import AppKit
import SwiftUI

/// 关窗口时不真的关，只把它藏起来。
///
/// 直接让它关掉的话 SwiftUI 会把窗口连同 WKWebView 一起销毁，再打开就是一次全新加载
/// （两秒白屏 + 丢滚动位置）。这里拦在 `windowShouldClose` 上改成 `orderOut`。
///
/// 注意不能用 `window.delegate = self` 直接顶掉原代理：SwiftUI 靠它管场景生命周期，
/// 被挤掉之后窗口一隐藏就以为场景结束了，重新显示时会重建整棵视图、网页重新加载。
/// 所以只实现 `windowShouldClose`，剩下全部通过 `forwardingTarget` 转给原代理。
final class WindowKeeper: NSObject, NSWindowDelegate {
    static let shared = WindowKeeper()

    private weak var original: NSWindowDelegate?

    func attach(to window: NSWindow) {
        guard window.delegate !== self else { return }
        original = window.delegate
        window.delegate = self
        // 只要一个窗口：既不许合并成标签页，也不参与窗口状态恢复（否则重启会多开）。
        window.tabbingMode = .disallowed
        // 工具栏那一行不显示窗口标题，只留我们的按钮
        window.titleVisibility = .hidden
        window.isRestorable = false

    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        ShellLog.write("window: 关闭请求 → 只隐藏，进程与内核继续")
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return original?.responds(to: selector) ?? false
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original, original.responds(to: selector) { return original }
        return nil
    }
}

/// 拿到 SwiftUI 创建的 NSWindow，好挂上代理 / 供「显示窗口」用。
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
