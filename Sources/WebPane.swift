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

        // 标题栏被隐藏后内容铺到最上面，给 #root 让出红绿灯的高度：
        // 上面那条就露出页面自己的背景色（body 的 #fff / #151517），看起来是同一个界面。
        configuration.userContentController.addUserScript(Self.titlebarScript(inset: 28))

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
        webView.load(URLRequest(url: url))
        return webView
    }

    /// 让页面自己避开窗口左上角的三个按钮，同时让左右两栏的背景一直铺到窗口顶端。
    ///
    /// 关键是**把内距加在两栏自己身上**（`sidebarCol` / `centerCol`），而不是它们的
    /// 共同祖先：背景会覆盖 padding 盒，于是侧栏的灰底、主区的白底都能延伸到红绿灯
    /// 那一行，只有内容整体下移——看起来就像页面本来就长这样，而不是有一条标题栏。
    ///
    /// 类名带 CSS Modules 的哈希前缀（`pI_x6G_sidebarCol`），所以按后缀匹配；
    /// 万一将来改了名，退回到给 `#root` 加内距（会露出 body 底色，但至少不会压住按钮）。
    private static func titlebarScript(inset: CGFloat) -> WKUserScript {
        let source = """
        (function () {
          var inset = \(Int(inset));
          var styled = new WeakSet();

          function columns() {
            return document.querySelectorAll('[class*="sidebarCol"],[class*="centerCol"],[class*="rightbarCol"]');
          }

          var rootStyled = false;

          function clearRoot() {
            var root = document.getElementById('root');
            if (!root || !rootStyled) { return; }
            root.style.removeProperty('padding-top');
            root.style.removeProperty('box-sizing');
            rootStyled = false;
          }

          function apply() {
            var nodes = columns();
            if (!nodes.length) {
              // 启动画面阶段还没有两栏，只能先退到底座上；等真界面出现要把它撤掉，
              // 否则两处内距叠加，内容会缩进两次。
              var root = document.getElementById('root');
              if (!root || rootStyled) { return; }
              root.style.setProperty('padding-top', inset + 'px', 'important');
              root.style.setProperty('box-sizing', 'border-box', 'important');
              rootStyled = true;
              return;
            }
            clearRoot();
            for (var i = 0; i < nodes.length; i++) {
              var node = nodes[i];
              if (styled.has(node)) { continue; }
              node.style.setProperty('padding-top', inset + 'px', 'important');
              node.style.setProperty('box-sizing', 'border-box', 'important');
              styled.add(node);
            }
          }

          var scheduled = false;
          function schedule() {
            if (scheduled) { return; }
            scheduled = true;
            requestAnimationFrame(function () { scheduled = false; apply(); });
          }

          apply();
          document.addEventListener('DOMContentLoaded', apply);
          window.addEventListener('load', apply);
          // 应用是运行时挂载的，节点会被整体替换，所以盯着变化重新加。
          new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
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
            for delay in [0.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    webView.evaluateJavaScript("""
                        (function () {
                          var col = document.querySelector('[class*="sidebarCol"]');
                          var root = document.getElementById('root');
                          var text = document.body ? document.body.innerText.slice(0, 30) : '';
                          return 'pad(col)=' + (col ? getComputedStyle(col).paddingTop : 'no-col')
                            + ' pad(root)=' + (root ? getComputedStyle(root).paddingTop : '-')
                            + ' | ' + text;
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
