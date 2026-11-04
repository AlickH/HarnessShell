import SwiftUI
import WebKit

/// 壳的全部状态：找到服务前显示进度，找到之后把 URL 交给 WebPane。
///
/// 刻意不用 @MainActor 标注整个类：`@Published` 只在主线程写就够，
/// 这样 SwiftUI 的 App 初始化里能直接拿到单例，不会被隔离检查拦住。
final class ShellModel: ObservableObject {
    enum Phase: Equatable {
        case starting(String)
        case ready(URL)
        case failed(String)
    }

    static let shared = ShellModel()

    @Published private(set) var phase: Phase = .starting("正在查找 harness…")

    private let runner = ServerRunner()
    private var booted = false
    private weak var webView: WKWebView?

    func start() {
        guard !booted else { return }
        booted = true
        phase = .starting("正在启动 harness…")
        runner.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.phase = .ready(url)
            case .failure(let failure):
                self.phase = .failed(failure.message)
            }
        }
    }

    func retry() {
        booted = false
        start()
    }

    func shutdown() {
        runner.stop()
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func reload() {
        webView?.reload()
    }

    func zoom(by delta: CGFloat) {
        guard let webView else { return }
        webView.pageZoom = min(max(webView.pageZoom + delta, 0.5), 2.0)
    }

    func resetZoom() {
        webView?.pageZoom = 1
    }

    var logPath: String { ServerRunner.logURL.path }
}
