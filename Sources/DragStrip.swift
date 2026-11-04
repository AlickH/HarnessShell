import AppKit
import SwiftUI

/// 标题栏藏起来之后，最上面那 28pt 不再属于系统，窗口就拖不动了。
///
/// 这层只盖左上角一小块（交通灯所在的位置），不能横跨整条——否则页面顶栏的按钮
/// 正好落在里面，点击会被这层吃掉，表现就是"按钮点不动"。
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
