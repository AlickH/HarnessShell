import AppKit
import SwiftUI

@main
struct WhalessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ShellModel.shared

    var body: some Scene {
        WindowGroup("Whaless") {
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window = NSApp.windows.first else { return }
            ShellLog.write("window: fullSize=\(window.styleMask.contains(.fullSizeContentView)) "
                + "transparentTitlebar=\(window.titlebarAppearsTransparent) "
                + "titleHidden=\(window.titleVisibility != .visible)")
        }
    }

    /// 关窗不退出：内核继续跑，Dock 图标点一下窗口就回来。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            ShellModel.shared.showWindow()
            ShellLog.write("window: 从 Dock 重新显示")
        }
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
                    // 红绿灯那一行现在是页面自己的背景，拖动窗口靠这层透明区域。
                    .overlay(alignment: .top) {
                        DragStrip()
                            .frame(height: 28)
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
