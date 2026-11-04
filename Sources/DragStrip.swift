import AppKit
import SwiftUI

/// 标题栏藏起来之后，最上面那 28pt 不再属于系统，窗口就拖不动了。
/// 这里盖一层透明区域，只负责"按住拖动窗口"，不拦页面里的其它交互。
struct DragStrip: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
