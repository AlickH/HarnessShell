import AppKit
import SwiftUI

@main
struct WhalessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ShellModel.shared

    var body: some Scene {
        // 用 Window 而不是 WindowGroup：WindowGroup 每次"重新打开"都会新建一个窗口，
        // 系统再把它们合并成标签页。Window 本来就是单实例场景，不会多开。
        Window("Whaless", id: "main") {
            RootView(model: model)
                .frame(minWidth: 760, minHeight: 500)
                .onAppear { model.start() }
                .overlay(alignment: .topLeading) {
                    TopButtons(model: model)
                }
                .overlay(alignment: .topLeading) {
                    NewSessionCapsule(model: model)
                }
                .overlay(alignment: .topTrailing) {
                    RightButtonsRow(model: model)
                }
                .overlay(alignment: .topLeading) {
                    SessionHeaderButtons(model: model)
                }
                // 必须放在 overlay 之后：让整棵视图（含 overlay）都忽略标题栏安全区，
                // 这样 overlay 的 topLeading 才锚定到窗口绝对顶部，跟交通灯同一行。
                .ignoresSafeArea()
                // 不钉窗口外观：页面主题按系统外观强制同步（注入脚本里做），
                // 交通灯、玻璃按钮、毛玻璃材质都跟着系统亮暗走。
                .background(WindowAccessor { model.adopt($0) })
        }
        .defaultSize(width: 1200, height: 840)
        // .hiddenTitleBar 是 SwiftUI 官方的无标题栏方式：标题栏隐藏、内容铺满、
        // 交通灯浮在内容上。这比事后改 styleMask 可靠得多。
        .windowStyle(.hiddenTitleBar)
        MenuBarExtra {
            Text(model.isReady ? "内核运行中" : "正在启动…")
            Divider()
            Button("显示窗口") { model.showWindow() }
            Button("检查内核更新…") { model.checkKernelUpdate() }
            Button("打开日志") { NSWorkspace.shared.open(URL(fileURLWithPath: model.logPath)) }
            Divider()
            Button("退出 Whaless") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: model.isReady ? "water.waves" : "water.waves.and.arrow.down")
        }
        .commands {
            // 单页应用不需要「新建窗口」
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("重新载入") { model.reload() }
                    .keyboardShortcut("r")
                Button("实际大小") { model.resetZoom() }
                    .keyboardShortcut("0")
                Divider()
                Button("放大") { model.zoom(by: 0.1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("缩小") { model.zoom(by: -0.1) }
                    .keyboardShortcut("-")
            }
            // 兜底入口：万一面上的按钮被什么挡住，这里也能切。
            CommandGroup(after: .sidebar) {
                Button("切换侧边栏") { model.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
            }
            CommandMenu("内核") {
                Button("检查内核更新…") { model.checkKernelUpdate() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("安装 / 重装 npm 版内核…") { model.installKernel() }
                Divider()
                Button("打开日志") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: model.logPath))
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 这一版只要一个窗口：关掉系统的窗口标签页功能。
    /// 必须在窗口创建之前设，放到 didFinishLaunching 就晚了。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window = NSApp.windows.first else { return }
            let items = window.toolbar?.items.map { item -> String in
                guard let view = item.view else { return "no-view" }
                let f = view.convert(view.bounds, to: nil)   // 窗口坐标系（底原点）
                let top = window.frame.height - f.maxY
                return "x=\(Int(f.minX)) top=\(Int(top)) \(Int(f.width))x\(Int(f.height))"
            }.joined(separator: " | ") ?? "-"
            ShellLog.write("toolbar: exists=\(window.toolbar != nil) items=[\(items)]")
            if let close = window.standardWindowButton(.closeButton) {
                let inWindow = close.convert(close.bounds, to: nil)
                let bar = window.contentLayoutRect
                ShellLog.write("geo: win=\(Int(window.frame.height))x\(Int(window.frame.width))"
                    + " content=\(Int(bar.height))x\(Int(bar.width))"
                    + " close=\(Int(inWindow.minX)),\(Int(window.frame.height - inWindow.maxY))"
                    + " \(Int(inWindow.width))x\(Int(inWindow.height))")
            }
            ShellLog.write("window: tabs=\(window.tabbingMode == .disallowed ? "off" : "on") "
                + "fullSize=\(window.styleMask.contains(.fullSizeContentView)) "
                + "transparentTitlebar=\(window.titlebarAppearsTransparent) "
                + "titleHidden=\(window.titleVisibility != .visible)")
        }
    }

    /// 关窗不退出：内核继续跑，Dock 图标点一下窗口就回来。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点 Dock 图标时自己把窗口拿出来，返回 false 阻止 AppKit 按默认行为再开一个——
    /// 那样会多出一个 WindowGroup 窗口，被系统合并成标签页。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            ShellModel.shared.showWindow()
        }
        ShellLog.write("window: reopen flag=\(flag) tabs=\(ShellModel.shared.window?.tabbedWindows?.count ?? 0)")
        return true
    }

    /// 退出时收掉子进程，否则它会继续占着端口，下次启动就"看起来打不开"。
    func applicationWillTerminate(_ notification: Notification) {
        ShellModel.shared.shutdown()
    }
}

/// 顶部那排液态玻璃按钮。
///
/// 位置**完全由流式上报的侧栏宽度驱动**，不做自己的补间动画：
/// `max(92, 宽 - 40)`——展开时紧贴分割线左侧（按钮右缘离线 8px），折叠时分割线
/// 一路收到 56，按钮跟着滑到 92（交通灯旁）就停。按钮和分割线天然同步，
/// 不会出现"侧栏收完了按钮才跳过去"。
///
/// 加号只在折叠后出现（展开时侧栏自己有「新会话」）；它的淡入淡出由
/// `reportSidebar` 里翻转那一刻的 `withAnimation` 提供动画事务，所以是
/// **跟着折叠钮一起边滑边现**，而不是在终点原地弹出。
///
/// 首次上报到来之前整套按钮不显示——页面还没渲染时顶上飘两个玻璃圆很突兀。
private struct TopButtons: View {
    @ObservedObject var model: ShellModel

    private var leading: CGFloat { max(88, model.sidebarWidth - 44) }

    var body: some View {
        if model.webContentReady {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        model.toggleSidebar()
                    } label: {
                        Image(systemName: "sidebar.left")
                            .frame(width: 36, height: 36)
                            .font(.system(size: 16, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .help("收起 / 展开侧边栏")

                    // 用 `if` 而不是 `.opacity`：玻璃由 GlassEffectContainer 统一渲染，
                    // opacity 只作用于按钮内容，那层玻璃还会留在原地。
                    if model.sidebarCollapsed {
                        Button {
                            model.newSession()
                        } label: {
                            Image(systemName: "plus.message")
                                .frame(width: 36, height: 36)
                                .font(.system(size: 16, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .help("新会话")
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                }
            }
            .padding(.top, 12)
            .padding(.leading, leading)
            .transition(.opacity)
        }
    }
}

/// 侧栏毛玻璃的底：窗口透明后，这层把窗口背后的东西模糊进来。
/// 材质外观不钉死，跟着窗口/系统外观走。
private final class BackdropEffectView: NSVisualEffectView {
    /// 外观一变就通知壳去把系统内容色重新推给页面（系统色是随外观解析的）。
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

private struct VibrancyBackdrop: NSViewRepresentable {
    let onAppearanceChange: () -> Void

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = BackdropEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.onAppearanceChange = onAppearanceChange
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        (view as? BackdropEffectView)?.onAppearanceChange = onAppearanceChange
    }
}

/// 会话页内容区右上角的两颗（开在应用里 / 更多操作）：
/// 挂在**内容区**层级 —— 右边对齐内容列的右边缘，右侧栏打开时跟着内容列一起左移。
/// 和右上角那排同样 36pt、间距 8；两颗都是菜单按钮，点了弹系统菜单。
private struct SessionHeaderButtons: View {
    @ObservedObject var model: ShellModel

    private let size: CGFloat = 36
    private let spacing: CGFloat = 8

    private func button(symbol: String, help: String, menu: String) -> some View {
        Button {
            model.showSystemMenu(menu)
        } label: {
            Image(systemName: symbol)
                .frame(width: size, height: size)
                .font(.system(size: 16, weight: .medium))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }

    var body: some View {
        if let right = model.sessionContentRight,
           model.sessionMoreRect != nil || model.sessionTargetRect != nil {
            HStack(spacing: spacing) {
                if model.sessionTargetRect != nil {
                    button(symbol: "arrow.up.forward.app",
                           help: "在应用中打开", menu: "apps")
                }
                if model.sessionMoreRect != nil {
                    button(symbol: "ellipsis", help: "更多操作", menu: "more")
                }
            }
            .offset(x: right - 12 - size * 2 - spacing, y: 12)
        }
    }
}

/// 侧栏顶部的「新会话」：原生液态玻璃胶囊，盖在网页那颗（已隐藏）的位置上。
/// 宽度跟着侧栏宽度实时变，收放动画期间交给快照显示，自己先退场。
private struct NewSessionCapsule: View {
    @ObservedObject var model: ShellModel

    var body: some View {
        if let top = model.newSessionTop,
           !model.sidebarAnimating,
           model.sidebarWidth >= 200 {
            let width = max(120, model.sidebarWidth - 24)
            Button {
                model.clickPageButton("newSession")
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16, weight: .medium))
                    Text("新会话")
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(width: width, height: model.newSessionHeight)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .offset(x: 12, y: top)
            .allowsHitTesting(true)
        }
    }
}

/// 右上角这一排：右侧栏开关（32pt，和左上角那颗对称）+ 面板里的全屏 / 分栏（28pt）。
/// 位置全部由这里排，不跟网页坐标走 —— 三个按钮同高、间距均匀，开合不叠也不跳。
private struct RightButtonsRow: View {
    @ObservedObject var model: ShellModel

    private func chromeButton(_ id: String, symbol: String, help: String,
                              enabled: Bool,
                              action: (() -> Void)? = nil) -> some View {
        Button {
            if let action { action() } else { model.clickPageButton(id) }
        } label: {
            Image(systemName: symbol)
                .frame(width: 36, height: 36)
                .font(.system(size: 16, weight: .medium))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
        .opacity(model.pageRightOpen ? (enabled ? 1 : 0.4) : 0)
        .disabled(!model.pageRightOpen || !enabled)
    }

    var body: some View {
        if model.webContentReady {
            HStack(spacing: 8) {
                if model.pageRightSplit {
                    chromeButton("split", symbol: "rectangle.split.2x1", help: "分栏",
                                 enabled: model.pageRightSplitEnabled)
                }
                if model.pageRightMode {
                    chromeButton(
                        "mode",
                        symbol: model.pageRightFullscreen
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right",
                        help: model.pageRightFullscreen ? "退出全屏" : "全屏",
                        enabled: true)
                }
                Button {
                    model.toggleRightSidebar()
                } label: {
                    Image(systemName: "sidebar.right")
                        .frame(width: 36, height: 36)
                        .font(.system(size: 16, weight: .medium))
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .help(model.pageRightOpen ? "收起右侧栏" : "展开右侧栏")
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
            .animation(.easeInOut(duration: 0.18), value: model.pageRightOpen)
        }
    }
}

struct RootView: View {    @ObservedObject var model: ShellModel

    var body: some View {
        Group {
            switch model.phase {
            case .ready(let url):
                // 侧栏毛玻璃：原生材质垫在 WebPane 底下，页面把 frame/侧栏画成透明
                // （见 WebPane 注入的 CSS），主栏仍是实色 —— 只有侧栏区域能透出这层，
                // 等价于官方桌面端的 `vibrancy: "sidebar"`。
                ZStack {
                    VibrancyBackdrop(onAppearanceChange: {
                        model.pushSystemContentColor()
                    })
                    WebPane(url: url, model: model)
                }
                .ignoresSafeArea()
            case .starting(let detail):
                StatusView(title: "正在启动 Harness",
                           detail: detail,
                           showsSpinner: true,
                           logPath: nil,
                           retry: nil,
                           install: nil)
            case .failed(let message):
                StatusView(title: "没能连上 Harness",
                           detail: message,
                           showsSpinner: false,
                           logPath: model.logPath,
                           retry: { model.retry() },
                           install: { model.installKernel() })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 启动/失败界面仍是实色底；进入页面后背景交给底下的原生材质透。
        // 启动页用系统内容色，跟着 macOS 外观走。
        .background(model.isReady ? Color.clear : Color(nsColor: .textBackgroundColor))
    }
}

struct StatusView: View {
    let title: String
    let detail: String
    let showsSpinner: Bool
    let logPath: String?
    let retry: (() -> Void)?
    let install: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
            }
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 460)

            HStack(spacing: 10) {
                if let install {
                    Button("安装 npm 版内核", action: install)
                        .keyboardShortcut(.defaultAction)
                }
                if let retry {
                    Button("重试", action: retry)
                }
                if let logPath {
                    Button("打开日志") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(40)
    }
}
