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
                .background(WindowAccessor { model.adopt($0) })
        }
        .defaultSize(width: 1200, height: 840)
        // 去掉标题栏：内容铺到窗口边缘，红绿灯浮在页面之上。
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

struct RootView: View {
    @ObservedObject var model: ShellModel

    var body: some View {
        Group {
            switch model.phase {
            case .ready(let url):
                WebPane(url: url, model: model)
                    .ignoresSafeArea()
                    // 左上角这一条：交通灯（原生，浮在页面之上）→ 拖拽区 → 原生侧栏开关。
                    // 开关按交通灯右侧对齐（灯占到 x≈81），web 端自己的折叠按钮已被隐藏。
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 0) {
                            DragStrip()
                                .frame(width: 86, height: 28)
                            SidebarToggle { model.toggleSidebar() }
                                .frame(width: 28, height: 28)
                        }
                        .padding(.top, 4)
                    }
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
