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
    /// 交通灯各自的原位（每次布局后要把它们重新挪回去）。
    private var baseFrames: [Int: NSRect] = [:]

    func attach(to window: NSWindow) {
        guard window.delegate !== self else { return }
        original = window.delegate
        window.delegate = self
        // 只要一个窗口：既不许合并成标签页，也不参与窗口状态恢复（否则重启会多开）。
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.isRestorable = false
        // 无标题栏由 .windowStyle(.hiddenTitleBar) 处理，这里不再重复改 styleMask。

        nudgeTrafficLights(in: window)
        // 窗口尺寸一变，titlebar 会重新布局，按钮又回到默认位置，所以要再挪一次。
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.nudgeTrafficLights(in: window)
            }
        }
    }

    /// 把左上角三个按钮往右下挪到系统 app 的标准位置，别紧贴着圆角。
    ///
    /// `close.superview` 就是 `NSTitlebarView` 本身，挪它会把整条 titlebar 一起挪走，
    /// 所以只能逐个按钮改 frame。AppKit 每次重新布局都会把它们放回去，因此先记下原位，
    /// 之后都按"原位 + 偏移"重设，避免反复累加。
    func nudgeTrafficLights(in window: NSWindow) {
        let dx: CGFloat = 8
        let down: CGFloat = 12

        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            let key = Int(buttonType.rawValue)
            if baseFrames[key] == nil {
                baseFrames[key] = button.frame
            }
            guard let base = baseFrames[key] else { continue }
            // 坐标系可能是翻转的（y 向下增），按 isFlipped 决定"往下"是加还是减。
            let dy = button.superview?.isFlipped == true ? down : -down
            let target = NSRect(x: base.origin.x + dx, y: base.origin.y + dy, width: base.width, height: base.height)
            if button.frame != target {
                button.frame = target
            }
        }
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
