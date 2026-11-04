import AppKit
import SwiftUI

/// 标题栏里的原生侧栏开关。
///
/// web 端自己的折叠按钮已被隐藏，点这个按钮时用 JS 代它 `.click()`，
/// 让应用走它自己的状态机（主栏宽度是它算的，壳不碰这些数字）。
///
/// 用 NSButton 而不是 SwiftUI Button：这台机器的 SwiftUI 宏插件坏了（`@State` 展开失败，
/// `swift-plugin-server produced malformed response`），而 hover 高亮本来 NSButton 更好写。
struct SidebarToggle: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = HoverButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "侧栏")
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "收起 / 展开侧边栏"
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func fire() {
            action()
        }
    }

    /// 鼠标悬停时给一层淡背景，跟标题栏里其它图标的手感一致。
    final class HoverButton: NSButton {
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }

        override func mouseExited(with event: NSEvent) {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
