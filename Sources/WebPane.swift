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
          var RAIL_LEFT = 84;      // 折叠后按钮的位置：让开交通灯（约占到 77）
          var lift = null;         // 侧栏头部比主栏头部低多少，量一次就够

          function sidebar() { return document.querySelector('[class*="sidebarCol"]'); }
          function columns() { return document.querySelectorAll('[class*="centerCol"],[class*="rightbarCol"]'); }
          function toggleIn(side) { return side ? side.querySelector('[class*="toggle"]') : null; }
          // 主栏右上角那排图标，跟侧栏折叠按钮是同一个组件，拿它当对齐基准。
          function reference() {
            return document.querySelector('[aria-label="打开右侧边栏"],[aria-label="收起右侧边栏"]');
          }

          function injectStyle() {
            if (document.getElementById('whaless-style')) { return; }
            var style = document.createElement('style');
            style.id = 'whaless-style';
            // 折叠后主栏顶到最左边，给它的顶栏让开交通灯
            style.textContent = 'html.whaless-rail [class*="centerCol"] > :first-child{padding-left:28px !important}';
            (document.head || document.documentElement).appendChild(style);
          }

          function setPad(node, px) {
            if (px === 0) {
              node.style.removeProperty('padding-top');
              node.style.removeProperty('box-sizing');
              return;
            }
            if (getComputedStyle(node).paddingTop === px + 'px') { return; }
            node.style.setProperty('padding-top', px + 'px', 'important');
            node.style.setProperty('box-sizing', 'border-box', 'important');
          }

          var rootStyled = false;
          function clearRoot() {
            var root = document.getElementById('root');
            if (!root || !rootStyled) { return; }
            root.style.removeProperty('padding-top');
            root.style.removeProperty('box-sizing');
            rootStyled = false;
          }

          // 折叠态给按钮加的临时定位，回展开态时全部撤掉
          var TEMP = ['position', 'left', 'top', 'z-index', 'visibility', 'pointer-events', 'transform'];
          function resetToggle(toggle) {
            for (var i = 0; i < TEMP.length; i++) { toggle.style.removeProperty(TEMP[i]); }
          }

          function apply() {
            injectStyle();
            var side = sidebar();
            var cols = columns();
            if (!side && !cols.length) {
              // 启动画面阶段还没有分栏，先退到底座；真界面出现后撤掉，避免叠加。
              var root = document.getElementById('root');
              if (!root || rootStyled) { return; }
              root.style.setProperty('padding-top', inset + 'px', 'important');
              root.style.setProperty('box-sizing', 'border-box', 'important');
              rootStyled = true;
              return;
            }
            clearRoot();
            for (var i = 0; i < cols.length; i++) { setPad(cols[i], 0); }
            if (!side) { return; }

            var toggle = toggleIn(side);
            var width = side.getBoundingClientRect().width;

            if (width > 0 && width < 200) {
              // 折叠态：应用把它收成 56px 窄条，主栏宽度是按这 56px 算的，
              // 所以占位不能动，只让这条窄栏"看不见"；折叠按钮本身拎出来浮在交通灯右边。
              side.style.setProperty('visibility', 'hidden', 'important');
              side.style.setProperty('background', 'transparent', 'important');
              // 应用把主栏宽度写成了"窗口 - 侧栏宽"，光把侧栏改 0 会让中间栏留在 790
              // 并在右边空一条。所以同时把主栏改成可伸缩，让它自己吃掉让出来的空间。
              side.style.setProperty('width', '0px', 'important');
              side.style.setProperty('min-width', '0px', 'important');
              side.style.setProperty('max-width', '0px', 'important');
              side.style.setProperty('flex', '0 0 0px', 'important');
              var mids = columns();
              for (var k = 0; k < mids.length; k++) {
                mids[k].style.setProperty('width', 'auto', 'important');
                mids[k].style.setProperty('flex', '1 1 0', 'important');
              }
              document.documentElement.classList.add('whaless-rail');
              if (toggle) {
                resetToggle(toggle);
                toggle.style.setProperty('visibility', 'visible', 'important');
                toggle.style.setProperty('pointer-events', 'auto', 'important');
                toggle.style.setProperty('position', 'fixed', 'important');
                toggle.style.setProperty('left', RAIL_LEFT + 'px', 'important');
                toggle.style.setProperty('top', '11px', 'important');
                toggle.style.setProperty('z-index', '2147483647', 'important');
              }
              return;
            }

            // 展开态：侧栏整列保持 28px 内距（logo 在交通灯下面），
            // 只把折叠按钮抬到和主栏那排图标同一水平线——它们是同一个组件同一个尺寸，
            // 差的那点高度纯粹来自侧栏的 28px 内距，所以按实测差值平移即可。
            document.documentElement.classList.remove('whaless-rail');
            ['visibility', 'background', 'width', 'min-width', 'max-width', 'flex'].forEach(function (name) {
              side.style.removeProperty(name);
            });
            var mids = columns();
            for (var k = 0; k < mids.length; k++) {
              mids[k].style.removeProperty('width');
              mids[k].style.removeProperty('flex');
            }
            setPad(side, inset);
            if (!toggle) { return; }
            resetToggle(toggle);
            if (lift === null) {
              var own = toggle.getBoundingClientRect().top;
              var ref = reference();
              var refTop = ref ? ref.getBoundingClientRect().top : 11;
              lift = Math.max(0, Math.round(own - refTop));
              window.console.log('[whaless] toggle lift = ' + lift);
            }
            if (lift > 0) {
              toggle.style.setProperty('transform', 'translateY(-' + lift + 'px)', 'important');
            }
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
          // 折叠/展开只改样式不产生结构变化，观察器收不到，补一层低频轮询。
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
            for delay in [0.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    webView.evaluateJavaScript("""
                        (function () {
                          var side = document.querySelector('[class*="sidebarCol"]');
                          var m = document.querySelector('[class*="centerCol"]');
                          function rect(el) {
                            if (!el) { return '-'; }
                            var r = el.getBoundingClientRect();
                            return [r.x, r.y, r.width].map(Math.round).join(',');
                          }
                          return 'side[' + rect(side) + '] center[' + rect(m) + '] win=' + innerWidth;
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
