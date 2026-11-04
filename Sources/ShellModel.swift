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

    /// 侧栏当前宽度（由 web 端 ResizeObserver 上报，取 DOM 里最宽的那个 sidebarCol）。
    /// 原生按钮的位置依赖它：展开时贴着分割线，折叠后回交通灯旁。
    /// 默认 280 = 上游展开态的标准宽。
    @Published private(set) var sidebarWidth: CGFloat = 280

    /// 折叠态直接读 React 打在自己 frame 上的 `data-sidebar-collapsed`，
    /// 不信宽度阈值（DOM 里可能同时有展开列和 rail 两个节点）。
    @Published private(set) var sidebarCollapsed = false

    /// 首次上报 = 页面真的渲染出来了。在那之前顶部按钮整套不显示。
    @Published private(set) var webContentReady = false

    /// 页面当前的深色/浅色（跟着页面主题，不跟系统）。原生毛玻璃材质和启动界面都按它
    /// 取样式，否则系统亮色 + 页面暗色时：侧栏是一块亮的雾、启动时还白闪一下。
    /// 初值取上一次记住的主题 —— 内核起来那几秒（页面还没上报）也不至于用错颜色。
    @Published private(set) var pageDark: Bool

    /// 折叠/展开动画窗口。这 0.3s 里 web 那边一帧 JS 都不跑，按钮位置由这里自己补间：
    /// 玻璃效果（GlassEffectContainer）每帧重渲染一次很贵，逐帧喂宽度会把整段动画
    /// 拖到 40fps —— 这正是左侧栏"不如右侧栏顺"的主因。改用一条和 CSS 完全相同的
    /// 缓动曲线（0.3s / cubic-bezier(.4,0,.2,1)），整段只渲染一次。
    private var toggleAnimUntil: Date?
    /// 最近一次展开态的宽度（折叠时用它当展开目标）。
    private var lastExpandedWidth: CGFloat = 280

    private static let pageDarkKey = "pageDark"

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.pageDarkKey) as? Bool
        pageDark = stored
            ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// web 端已经把 theme 单独上报过来了（不依赖侧栏渲染，页面一挂就报）。
    /// 注意页面主题现在已经按系统外观强制同步（见注入脚本的 syncSystemTheme）。
    func reportTheme(dark: Bool) {
        guard pageDark != dark else { return }
        pageDark = dark
        UserDefaults.standard.set(dark, forKey: Self.pageDarkKey)
    }

    func beginToggle() {
        let target: CGFloat = sidebarCollapsed ? lastExpandedWidth : 56
        toggleAnimUntil = Date().addingTimeInterval(0.36)
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
            sidebarCollapsed = !sidebarCollapsed
            sidebarWidth = target
        }
    }

    /// web → 原生的上报入口（WKScriptMessageHandler 主线程回调）。
    ///
    /// 位置由宽度流驱动（每帧更新、天然跟手），这里只管两类"离散事件"：
    /// 首次上报（整套按钮淡入）、折叠态翻转（给加号的 transition 一个动画事务，
    /// 让它跟着折叠钮一起边滑边现/隐）。
    func reportSidebar(width: Double, collapsed: Bool) {
        // 动画窗口内一律不理：位置由 beginToggle 那条曲线负责，这里再插一脚只会打架。
        if let until = toggleAnimUntil {
            if Date() < until { return }
            toggleAnimUntil = nil
        }
        let next = CGFloat(width)
        if next >= 200 { lastExpandedWidth = next }
        let wasReady = webContentReady
        if !wasReady {
            webContentReady = true
            withAnimation(.easeOut(duration: 0.35)) {
                sidebarWidth = next
                sidebarCollapsed = collapsed
            }
        } else if collapsed != sidebarCollapsed {
            // 宽度现在是 web 那边一路流过来的（壳给 grid 列开了 280ms 过渡），
            // 位置直接跟每一帧走就行，别再包 withAnimation——包了反而比分割线慢半拍。
            // 只有加号的显隐需要补间：让它跟着这趟滑动淡入/淡出，而不是终点处弹一下。
            sidebarWidth = next
            withAnimation(.easeInOut(duration: 0.28)) {
                sidebarCollapsed = collapsed
            }
        } else {
            sidebarWidth = next
        }
        ShellLog.write("sidebar width: \(Int(width)) collapsed=\(collapsed)"
            + (wasReady ? "" : " first"))
    }

    private let runner = ServerRunner()
    private var booted = false
    private weak var webView: WKWebView?
    /// 关窗只是隐藏，所以窗口对象要留着，用来重新显示。
    weak var window: NSWindow?

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
                ShellLog.write("启动失败：\(failure.message)")
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

    /// 把 macOS 的系统内容底色推给页面：`NSColor.textBackgroundColor` 按当前外观
    /// 解析成 sRGB（暗色 #1E1E1E / 亮色 #FFFFFF），这是真正的系统色，
    /// 不是壳或 Harness 主题里写死的亮/暗值。
    func pushSystemContentColor() {
        guard let webView else { return }
        var color = NSColor.textBackgroundColor
        webView.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.textBackgroundColor
        }
        guard let srgb = color.usingColorSpace(.sRGB) else { return }
        let hex = String(
            format: "#%02x%02x%02x",
            Int(round(srgb.redComponent * 255)),
            Int(round(srgb.greenComponent * 255)),
            Int(round(srgb.blueComponent * 255)))
        ShellLog.write("system content color: \(hex)")
        webView.evaluateJavaScript(
            "window.__whalessContentBg && window.__whalessContentBg('" + hex + "')")
    }

    func reload() {
        webView?.reload()
    }

    // MARK: - 侧栏

    /// 新会话：点应用自己的「新会话」入口（先按 aria-label，再按文字兜底）。
    func newSession() {
        guard let webView else { return }
        webView.evaluateJavaScript("""
            (function () {
              var nodes = document.querySelectorAll('button,[role="button"],a');
              for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                var label = (el.getAttribute('aria-label') || '').trim();
                var text = (el.textContent || '').trim();
                if (label.indexOf('新会话') >= 0 || label.indexOf('New session') >= 0
                    || text.indexOf('新会话') === 0 || text.indexOf('New session') === 0) {
                  el.click();
                  return 'ok';
                }
              }
              return 'not-found';
            })()
            """) { value, error in
            let result = value as? String ?? error?.localizedDescription ?? "-"
            ShellLog.write("new session: \(result)")
        }
    }

    /// 原生按钮接管折叠：代 web 端那个（已被隐藏的）按钮点一下。
    ///
    /// 不能直接改宽度——主栏宽度是应用按"侧栏占多少"算出来的，壳只负责触发它的状态机。
    /// `visibility:hidden` 的元素依然能 `.click()`，所以按钮藏起来不影响这条路径。
    func toggleSidebar() {
        guard let webView else { return }
        // 先让原生按钮自己起跑（和 web 侧同一条曲线），再触发 web 的状态机。
        beginToggle()
        webView.evaluateJavaScript("""
            (function () {
              // 收起：begin() 先把当前这一帧冻成一份复制品（真身随即让位），
              // 这样 React 把内容换成图标版也看不见，滑出去的始终是同一张图。
              if (window.__whalessAnim) { window.__whalessAnim.begin(); }
              var side = document.querySelector('[class*="sidebarCol"]');
              var toggle = side && side.querySelector('[class*="toggle"]');
              if (!toggle) {
                if (window.__whalessAnim) { window.__whalessAnim.afterClick(); }
                return 'no-toggle';
              }
              toggle.click();
              // 同一帧内把位移摆到位并开始逐帧跟随主栏左缘。
              if (window.__whalessAnim) { window.__whalessAnim.afterClick(); }
              return 'ok';
            })()
            """) { value, error in
            let result = value as? String ?? error?.localizedDescription ?? "-"
            ShellLog.write("sidebar toggle: \(result)")
            // 折叠后确认三件事都到位：窄栏被整列藏掉、主栏顶到左边、
            // 页面标题行按 leading clearance 让开了玻璃按钮。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                webView.evaluateJavaScript("""
                    (function () {
                      var side = document.querySelector('[class*="sidebarCol"]');
                      var row = document.querySelector('[class*="titleRow"]');
                      function w(el) { return el ? Math.round(el.getBoundingClientRect().width) : '-'; }
                      return 'side=' + w(side)
                        + ' rail=' + (document.documentElement.classList.contains('whaless-rail') ? '1' : '0')
                        + ' titleRowPad=' + (row ? getComputedStyle(row).paddingLeft : '-');
                    })()
                    """) { v, _ in
                    ShellLog.write("rail: \(v as? String ?? "-")")
                }
            }
        }
    }

    func zoom(by delta: CGFloat) {
        guard let webView else { return }
        webView.pageZoom = min(max(webView.pageZoom + delta, 0.5), 2.0)
    }

    func resetZoom() {
        webView?.pageZoom = 1
    }

    var logPath: String { ShellLog.url.path }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    // MARK: - 窗口

    func adopt(_ window: NSWindow?) {
        guard let window else { return }
        self.window = window
        WindowKeeper.shared.attach(to: window)
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let target = window ?? NSApp.windows.first { $0.canBecomeMain }
        target?.makeKeyAndOrderFront(nil)
    }

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
