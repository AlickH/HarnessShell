import AppKit
import SwiftUI
import WebKit

/// WKWebView 承载 harness 的 web UI，并把浏览器"白给"的那几件事补回来：
/// 文件选择、下载、外链、JS 对话框、关闭前确认。
struct WebPane: NSViewRepresentable {
    let url: URL
    let model: ShellModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, origin: url)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        configuration.userContentController.addUserScript(Self.sidebarScript())

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .windowBackgroundColor
        if #available(macOS 13.3, *) {
            webView.isInspectable = true   // Safari 的「开发」菜单里能挂上检查器
        }

        context.coordinator.webView = webView
        model.attach(webView)
        ShellLog.write("load \(ShellLog.redact(url))")
        // 先清 cookie 再加载：每次启动端口都变（--port 0），上一次实例留下的
        // 会话 cookie 会被先送到新端口上，服务端判它无效 → 页面停在 401。
        Self.clearCookies(of: webView) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    /// 清空 WKWebView 的 cookie 后再加载带令牌的地址。
    private static func clearCookies(of webView: WKWebView, then load: @escaping () -> Void) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            guard !cookies.isEmpty else {
                DispatchQueue.main.async(execute: load)
                return
            }
            ShellLog.write("清理 \(cookies.count) 个旧 cookie")
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                store.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main, execute: load)
        }
    }

    /// 让页面自己避开窗口左上角的三个按钮，同时让左右两栏的背景一直铺到窗口顶端。
    ///
    /// 关键是**把内距加在两栏自己身上**（`sidebarCol` / `centerCol`），而不是它们的
    /// 共同祖先：背景会覆盖 padding 盒，于是侧栏的灰底、主区的白底都能延伸到红绿灯
    /// 那一行，只有内容整体下移——看起来就像页面本来就长这样，而不是有一条标题栏。
    ///
    /// 类名带 CSS Modules 的哈希前缀（`pI_x6G_sidebarCol`），所以按后缀匹配；
    /// 万一将来改了名，退回到给 `#root` 加内距（会露出 body 底色，但至少不会压住按钮）。
    /// 页面这一侧只剩两件事：把 web 自己的折叠按钮藏起来、折叠后别让那条窄栏露出来。
    /// 展开/收起由标题栏的 SwiftUI 工具栏按钮触发（它 JS `.click()` 这个隐藏按钮）。
    /// 标题栏是原生的，内容不再压到交通灯下面，所以不需要任何 padding 补偿。
    private static func sidebarScript() -> WKUserScript {
        let source = """
        (function () {
          function sidebar() { return document.querySelector('[class*="sidebarCol"]'); }

          function injectStyle() {
            if (document.getElementById('whaless-style')) { return; }
            var style = document.createElement('style');
            style.id = 'whaless-style';
            // visibility 而不是 display：元素还在 DOM 里，JS .click() 照样触发它的事件
            style.textContent = '[class*="sidebarCol"] [class*="toggle"]{visibility:hidden !important}';
            (document.head || document.documentElement).appendChild(style);
          }

          function apply() {
            injectStyle();
            var side = sidebar();
            if (!side) { return; }
            var width = side.getBoundingClientRect().width;
            if (width > 0 && width < 200) {
              // 折叠态：应用把它收成 56px 窄条，主栏宽度按这 56px 算的，占位不能动，
              // 只让这条窄栏看不见。
              side.style.setProperty('visibility', 'hidden', 'important');
              side.style.setProperty('background', 'transparent', 'important');
              document.documentElement.classList.add('whaless-rail');
              return;
            }
            side.style.removeProperty('visibility');
            side.style.removeProperty('background');
            document.documentElement.classList.remove('whaless-rail');
          }

          var scheduled = false;
          function schedule() {
            if (scheduled) { return; }
            scheduled = true;
            setTimeout(function () { scheduled = false; apply(); }, 50);
          }

          apply();
          document.addEventListener('DOMContentLoaded', apply);
          window.addEventListener('load', apply);
          new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
          setInterval(apply, 600);
        })();
        """

        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        private let model: ShellModel
        private let origin: URL
        weak var webView: WKWebView?
        private var provisionalRetries = 0

        init(model: ShellModel, origin: URL) {
            self.model = model
            self.origin = origin
        }

        private func isLocal(_ url: URL) -> Bool {
            guard let host = url.host else { return false }
            return host == "127.0.0.1" || host == "localhost"
        }

        // MARK: - 导航：外链交给系统浏览器

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let clicked = navigationAction.navigationType == .linkActivated
            let wantsWindow = navigationAction.targetFrame == nil

            if clicked, !isLocal(url) {
                // 消息里的外链：用默认浏览器打开，不在壳里劫持
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            if clicked, wantsWindow {
                webView.load(URLRequest(url: url))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if isLocal(url) {
                    webView.load(URLRequest(url: url))
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            provisionalRetries = 0
            ShellLog.write("didFinish \(webView.url.map(ShellLog.redact) ?? "-")")
            // 白屏排查：把页面标题和首屏文字记下来，能立刻区分"没加载"和"加载了但渲染空"。
            for delay in [0.0, 6.0, 14.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    webView.evaluateJavaScript("""
                        (function () {
                          var side = document.querySelector('[class*="sidebarCol"]');
                          var m = document.querySelector('[class*="centerCol"]');
                          function w(el) { return el ? Math.round(el.getBoundingClientRect().width) : '-'; }
                          return 'side=' + w(side) + ' center=' + w(m)
                            + ' rail=' + (document.documentElement.classList.contains('whaless-rail') ? '1' : '0');
                        })()
                        """) { value, _ in
                        let text = (value as? String ?? "-").replacingOccurrences(of: "\n", with: " ")
                        ShellLog.write("rendered(+\(Int(delay))s) \(text)")
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // 服务刚起来时可能还没开始监听，退避重试几次就够了。
            ShellLog.write("didFailProvisional \((error as NSError).code) \(error.localizedDescription)")
            guard (error as NSError).domain == NSURLErrorDomain, provisionalRetries < 3 else { return }
            provisionalRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                webView.reload()
            }
        }

        // MARK: - 文件上传

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }

        // MARK: - 下载

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.canCreateDirectories = true
            completionHandler(panel.runModal() == .OK ? panel.url : nil)
        }

        func downloadDidFinish(_ download: WKDownload) {}

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            NSSound.beep()
        }

        // MARK: - JS 对话框

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = NSAlert()
            alert.messageText = "Harness"
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            alert.runModal()
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = "Harness"
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            alert.addButton(withTitle: "取消")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let alert = NSAlert()
            alert.messageText = "Harness"
            alert.informativeText = prompt
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field
            alert.addButton(withTitle: "好")
            alert.addButton(withTitle: "取消")
            completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
        }

        /// pdf / terminal 插件用它拦"确定要离开吗"，不实现的话这个确认会静默消失。
        func webView(_ webView: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = "离开这个页面？"
            alert.informativeText = message
            alert.addButton(withTitle: "离开")
            alert.addButton(withTitle: "留在此页")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}
