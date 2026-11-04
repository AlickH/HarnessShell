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
                    // 右侧栏全屏（浏览器/终端占满窗口）时，左侧这些壳自己的按钮
                    // 不该再压在内容上面。
                    TopButtons(model: model)
                        .opacity(model.pageRightFullscreen ? 0 : 1)
                        .allowsHitTesting(!model.pageRightFullscreen)
                }
                .overlay(alignment: .topLeading) {
                    NewSessionCapsule(model: model)
                        .opacity(model.pageRightFullscreen ? 0 : 1)
                        .allowsHitTesting(!model.pageRightFullscreen)
                }
                .overlay(alignment: .topTrailing) {
                    RightButtonsRow(model: model)
                }
                .overlay(alignment: .topLeading) {
                    SessionHeaderButtons(model: model)
                        .opacity(model.pageRightFullscreen ? 0 : 1)
                        .allowsHitTesting(!model.pageRightFullscreen)
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
                            .contentShape(Circle())
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
                                .contentShape(Circle())
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
/// 「开在应用里」是分两半的胶囊：左半是默认 app 图标（点它直接打开），
/// 右半是箭头（点它弹系统菜单）；「…」是圆钮，点了也弹系统菜单。
private struct SessionHeaderButtons: View {
    @ObservedObject var model: ShellModel

    private let size: CGFloat = 36
    private let chevronWidth: CGFloat = 24
    private let spacing: CGFloat = 8

    private var targetWidth: CGFloat {
        model.sessionSplit ? size + chevronWidth : size
    }

    private var rowWidth: CGFloat { targetWidth + spacing + size }

    private func menuButton(symbol: String, help: String, menu: String) -> some View {
        Button {
            model.showSystemMenu(menu)
        } label: {
            Image(systemName: symbol)
                .frame(width: size, height: size)
                .font(.system(size: 16, weight: .medium))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }

    var body: some View {
        if let right = model.sessionContentRight,
           model.sessionMoreRect != nil || model.sessionTargetRect != nil {
            // 内容列右缘贴着窗口右边时（右侧栏收起），要给右上角那颗开关留一格。
            let adjacentToWindow = model.pageWidth > 0
                && model.pageWidth - right < size + spacing + 4
            let trailingReserve = adjacentToWindow ? size + spacing : 0
            HStack(spacing: spacing) {
                if model.sessionTargetRect != nil {
                    HStack(spacing: 0) {
                        Button {
                            model.openInDefaultApp()
                        } label: {
                            Group {
                                if let icon = model.openInAppIcon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 18, height: 18)
                                } else {
                                    Image(systemName: "arrow.up.forward.app")
                                        .font(.system(size: 16, weight: .medium))
                                }
                            }
                            .frame(width: size, height: size)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("在默认应用中打开")

                        if model.sessionSplit {
                            Button {
                                model.showSystemMenu("apps")
                            } label: {
                                Image(systemName: "chevron.down")
                                    .frame(width: chevronWidth, height: size)
                                    .font(.system(size: 10, weight: .semibold))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("选择应用")
                        }
                    }
                    .glassEffect(.regular.interactive(), in: Capsule())
                }

                if model.sessionMoreRect != nil {
                    menuButton(symbol: "ellipsis", help: "更多操作", menu: "more")
                }
            }
            .offset(x: right - 12 - trailingReserve - rowWidth, y: 12)
            .animation(.easeInOut(duration: 0.3), value: right)
            .animation(.easeInOut(duration: 0.3), value: trailingReserve)
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
                .contentShape(Circle())
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
                        .contentShape(Circle())
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
        GeometryReader { geo in
            content(width: geo.size.width)
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
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
                // 内核起来到页面真正渲染出来之间，WebView 是空白的：
                // 这段时间继续盖着启动界面（转菊花），等页面第一次上报再淡出。
                .overlay {
                    if !model.webContentReady {
                        StatusView(title: "正在启动 Harness",
                                   detail: "正在准备界面…",
                                   showsSpinner: true,
                                   logPath: nil,
                                   retry: nil,
                                   install: nil,
                                   availableWidth: width)
                            .background(Color(nsColor: .textBackgroundColor))
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: model.webContentReady)
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

/// 品牌 wordmark：SVG 里填的是 `var(--dsw-alias-label-primary)` 这类变量，
/// 直接当图片加载变量不会解析 —— 读出来按当前外观替换成实际色值再加载。
func brandWordmark(dark: Bool) -> NSImage? {
    guard let url = Bundle.main.url(forResource: "welcome-brand", withExtension: "svg"),
          var text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let primary = dark ? "#ffffff" : "#0f1115"
    let inverted = dark ? "#0f1115" : "#ffffff"
    text = text.replacingOccurrences(of: "var(--dsw-alias-label-primary-inverted)",
                                     with: inverted)
    text = text.replacingOccurrences(of: "var(--dsw-alias-label-primary)", with: primary)
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("whaless-brand-\(dark ? "dark" : "light").svg")
    try? text.write(to: tmp, atomically: true, encoding: .utf8)
    return NSImage(contentsOf: tmp)
}

struct StatusView: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let detail: String
    let showsSpinner: Bool
    let logPath: String?
    let retry: (() -> Void)?
    let install: (() -> Void)?

    /// 启动时轮播的提示，一条一条淡入淡出，直到界面加载出来。
    @State private var tipIndex = 0
    private let tips = [
        "正在启动 Harness 内核并加载插件…",
        "侧栏的分割线可以拖动，调整到你觉得合适的宽度",
        "右侧栏能放文件、终端和浏览器，⌘T 直接开新标签",
        "会话里的内容支持 Markdown、代码块和公式渲染",
        "启动一次之后就快了，内核会缓存已加载的插件",
    ]
    private let tipTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var availableWidth: CGFloat = 1200

    var body: some View {
        let wide = availableWidth >= 900
        let logoWidth = min(max(availableWidth * 0.46, 360), 720)
        return content(wide: wide, logoWidth: logoWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(wide: Bool, logoWidth: CGFloat) -> some View {
        VStack(spacing: wide ? 22 : 16) {
            // 品牌 wordmark（从桌面端 welcome 窗口抽出来的同一份 SVG）。
            if let brand = brandWordmark(dark: colorScheme == .dark) {
                Image(nsImage: brand)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: logoWidth, height: logoWidth * 40 / 472)
                    .padding(.bottom, 6)
            }
            if showsSpinner {
                ProgressView()
                    .controlSize(wide ? .regular : .small)
            }
            Text(title)
                .font(wide ? .title3 : .headline)
            if showsSpinner {
                Text(tips[tipIndex % tips.count])
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .id(tipIndex)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: tipIndex)
                    .onReceive(tipTimer) { _ in tipIndex += 1 }
            } else {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
            }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
