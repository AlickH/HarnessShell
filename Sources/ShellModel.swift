import AppKit
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

        if ProcessInfo.processInfo.environment["WHALESS_KERNEL_CHECK"] == "1" {
            KernelUpdate.check { result in
                switch result {
                case .success(let check):
                    ShellLog.write("kernel check: current=\(check.current ?? "-") latest=\(check.latest ?? "-") install=\(check.install.label)")
                case .failure(let message):
                    ShellLog.write("kernel check failed: \(message)")
                }
            }
        }

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

    var logPath: String { ShellLog.url.path }

    // MARK: - 内核

    func checkKernelUpdate() {
        NSApp.activate(ignoringOtherApps: true)
        ShellLog.write("检查内核更新…")
        KernelUpdate.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure):
                ShellLog.write("检查失败：\(failure.message)")
                let response = self.alert(title: "检查更新失败", message: failure.message, buttons: ["安装内核", "好"])
                if response == .alertFirstButtonReturn { self.installKernel() }
            case .success(let check):
                ShellLog.write("内核：current=\(check.current ?? "-") latest=\(check.latest ?? "-")")
                self.present(check)
            }
        }
    }

    private func present(_ check: KernelCheck) {
        let detail = """
            当前内核：\(check.current ?? "未知")
            npm 最新：\(check.latest ?? "未知")
            安装方式：\(check.install.label)
            \(check.install.hint)
            """

        guard check.isOutdated else {
            _ = alert(title: "已是最新", message: detail, buttons: ["好"])
            return
        }
        guard check.install.supportsUpgrade else {
            _ = alert(title: "有新版本", message: detail, buttons: ["好"])
            return
        }
        let response = alert(title: "发现新版本 \(check.latest ?? "")",
                             message: detail + "\n\n更新后需要重启 Whaless。",
                             buttons: ["更新", "稍后"])
        if response == .alertFirstButtonReturn { upgradeKernel() }
    }

    /// 没装内核（或用户主动要装）时也走这条。
    func installKernel() {
        NSApp.activate(ignoringOtherApps: true)
        let response = alert(title: "安装 npm 版内核",
                             message: "将执行：npm install -g \(KernelUpdate.packageName)@latest\n需要网络，可能要几十秒。",
                             buttons: ["安装", "取消"])
        guard response == .alertFirstButtonReturn else { return }

        if case .failed = phase {} else {
            phase = .starting("正在通过 npm 安装内核…")
        }
        KernelUpdate.installLatest { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let version):
                ShellLog.write("内核安装完成：\(version)")
                self.booted = false
                self.start()
            case .failure(let failure):
                ShellLog.write("内核安装失败：\(failure.message)")
                self.phase = .failed(failure.message)
            }
        }
    }

    func upgradeKernel() {
        KernelUpdate.installLatest { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let version):
                ShellLog.write("内核已更新到 \(version)")
                let response = self.alert(title: "更新完成",
                                          message: "现在是 \(version)。要立即重启 Whaless 吗？",
                                          buttons: ["重启", "稍后"])
                if response == .alertFirstButtonReturn { self.relaunch() }
            case .failure(let failure):
                ShellLog.write("内核更新失败：\(failure.message)")
                _ = self.alert(title: "更新失败", message: failure.message, buttons: ["好"])
            }
        }
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private func alert(title: String, message: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: button) }
        return alert.runModal()
    }
}
