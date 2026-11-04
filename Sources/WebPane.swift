import AppKit
import SwiftUI
import WebKit

/// 三层结构（从下到上）：
///
///   1. 主内容 WebView —— 通栏铺满整个窗口，永远全宽。侧栏在 DOM 里被整列藏掉、
///      grid 轨道钉成 0，所以聊天内容一直延伸到窗口左缘 = 延伸到侧栏玻璃的正下方。
///   2. 玻璃面板 —— NSGlassEffectView，只盖住侧栏那一块。它模糊的是身后
///      主 WebView 的真实像素：滚动时文字从玻璃下穿过、被真实模糊（Tahoe 行为）。
///   3. 侧栏 WebView —— 同一个页面的第二个实例，只渲染侧栏 UI（镜像自主实例），
///      背景透明，浮在玻璃上，文字清晰。
///
/// 收起/展开 = 玻璃面板 + 侧栏 WebView 整体原生平移滑出/滑入（0.3s，
/// 和按钮曲线同源），主内容零重排——旧版那套 ghost 快照/逐帧贴边全部不再需要。
final class GlassHostView: NSView {
    private let glass: NSView
    private let panel: NSView
    private let mainContent: NSView
    private let sideContent: NSView

    /// 侧栏展开宽度（ShellModel 维护，默认 280）。
    var sidebarWidth: CGFloat = 280 { didSet { needsLayout = true } }
    private var panelHidden = false
    private var panelAnimating = false

    init(main: NSView, side: NSView) {
        mainContent = main
        sideContent = side
        panel = NSView()
        if #available(macOS 26.0, *) {
            let v = NSGlassEffectView()
            v.style = .clear
            v.cornerRadius = 0
            glass = v
        } else {
            // 26 以下的退路：vibrancy 的 sidebar 材质（磨砂，视觉接近）。
            let v = NSVisualEffectView()
            v.material = .sidebar
            v.blendingMode = .behindWindow
            v.state = .followsWindowActiveState
            glass = v
        }
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(mainContent)
        panel.wantsLayer = true
        panel.layer?.masksToBounds = true
        panel.addSubview(glass)
        // 侧栏 WebView 浮在玻璃上面：玻璃画材质，WebView 画 UI（背景透明）。
        // 不塞进 contentView：实测玻璃的雾化/高光会叠在 contentView 的内容上，
        // 亮色下文字被洗掉；叠在上面则文字永远清晰，层级和系统侧栏一致。
        panel.addSubview(sideContent)
        addSubview(panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        mainContent.frame = bounds
        // 面板动画期间 frame 由 animator 接管，这里不碰，否则每帧被打回原位。
        if !panelAnimating {
            panel.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
            glass.frame = panel.bounds
            if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
                g.contentView?.frame = g.bounds
            }
            // 侧栏实例的视口给宽（1400px）：280px 视口会掉进应用的移动端断点，
            // 窄视口还会触发应用自己的自动折叠、写进两个实例共享的 localStorage，
            // 把主实例也带折叠了。超出的部分被 panel 的 masksToBounds 裁掉。
            sideContent.frame = NSRect(x: 0, y: 0,
                                       width: max(bounds.width, 1400),
                                       height: bounds.height)
        }
    }

    /// 玻璃不参与命中测试：侧栏区域给侧栏 WebView，其余给主 WebView。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if !panel.isHidden, panel.frame.contains(local) {
            return sideContent.hitTest(convert(local, to: sideContent))
        }
        return mainContent.hitTest(convert(local, to: mainContent))
    }

    /// 静止状态同步（启动首报、应用自己折叠/展开但没走壳按钮的场合）。
    func applyState(width: CGFloat, collapsed: Bool) {
        sidebarWidth = width
        setPanelHidden(collapsed)
        needsLayout = true
    }

    /// 面板滑入/滑出（Tahoe 式：侧栏整体平移，主内容不动）。0.3s + 与按钮
    /// beginToggle 完全相同的缓动曲线，两边天然同步。
    func animatePanel(collapsing: Bool, width: CGFloat) {
        sidebarWidth = width
        panelAnimating = true
        panel.isHidden = false
        needsLayout = true
        panel.layoutSubtreeIfNeeded()
        if collapsing {
            slidePanel(to: -width) { [weak self] in
                guard let self else { return }
                self.panelAnimating = false
                self.setPanelHidden(true)
            }
        } else {
            panel.frame.origin.x = -width
            slidePanel(to: 0) { [weak self] in
                self?.panelAnimating = false
                self?.needsLayout = true
            }
        }
    }

    private func setPanelHidden(_ hidden: Bool) {
        guard panelHidden != hidden else { return }
        panelHidden = hidden
        panel.isHidden = hidden
        if !hidden { panel.layer?.removeAllAnimations() }
        needsLayout = true
    }

    private func slidePanel(to x: CGFloat, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrameOrigin(NSPoint(x: x, y: panel.frame.origin.y))
        }, completionHandler: completion)
    }

    /// 玻璃的亮暗跟页面主题走（不是跟系统）。玻璃身后现在有真实内容/底色，
    /// tint 要比旧版（玻璃后面是纯白窗口底）低得多——高了会把模糊出来的
    /// 内容盖死，又变回一块平灰。
    func applyTheme(_ bg: NSColor, dark: Bool) {
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            if dark {
                let tint = bg.blended(withFraction: 0.08, of: .white) ?? bg
                g.tintColor = tint.withAlphaComponent(0.45)
            } else {
                g.tintColor = bg.withAlphaComponent(0.35)
            }
            g.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        } else if let v = glass as? NSVisualEffectView {
            v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
    }
}

/// WKWebView 承载 harness 的 web UI，并把浏览器"白给"的那几件事补回来：
/// 文件选择、下载、外链、JS 对话框、关闭前确认。
struct WebPane: NSViewRepresentable {
    let url: URL
    let model: ShellModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, origin: url)
    }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator

        // 两个实例各用一套 configuration / userContentController：
        // 主实例注入"通栏 + 镜像发射"脚本，侧栏实例注入"只渲染侧栏 + 镜像接收"脚本。
        let mainConfig = WKWebViewConfiguration()
        mainConfig.websiteDataStore = .default()
        mainConfig.userContentController.addUserScript(Self.mainScript())
        mainConfig.userContentController.add(coordinator, name: "whaless")

        let sideConfig = WKWebViewConfiguration()
        sideConfig.websiteDataStore = .default()
        sideConfig.userContentController.addUserScript(Self.sideScript())
        sideConfig.userContentController.add(coordinator, name: "whalessSide")

        let main = WKWebView(frame: .zero, configuration: mainConfig)
        let side = WKWebView(frame: .zero, configuration: sideConfig)
        let host = GlassHostView(main: main, side: side)

        for w in [main, side] {
            w.navigationDelegate = coordinator
            w.uiDelegate = coordinator
            // 关掉这些手势：它们会让页面被缩放/拖出边界，露出背后的白边。
            w.allowsBackForwardNavigationGestures = false
            w.allowsMagnification = false
            w.underPageBackgroundColor = .clear
            w.wantsLayer = true
            w.layer?.backgroundColor = NSColor.clear.cgColor
            // 关闭 WKWebView 自身的背景绘制（私有 KVC）：它默认在页面内容提交前
            // 画一块白底，是白闪的元凶。侧栏实例必须透明。
            w.setValue(false, forKey: "drawsBackground")
            Self.disableBounce(in: w)
            if #available(macOS 13.3, *) {
                w.isInspectable = true   // Safari 的「开发」菜单里能挂上检查器
            }
        }

        coordinator.webView = main
        coordinator.sideWebView = side
        coordinator.host = host
        model.attach(main)
        model.attachSide(side)
        model.glassHost = host

        ShellLog.write("load \(ShellLog.redact(url))")
        // 先清 cookie 再加载：每次启动端口都变（--port 0），上一次实例留下的
        // 会话 cookie 会被先送到新端口上，服务端判它无效 → 页面停在 401。
        // 清完两个实例一起加载，免得侧栏实例撞上还没清完的旧 cookie。
        Self.clearCookies(of: main) {
            main.load(URLRequest(url: url))
            side.load(URLRequest(url: url))
        }
        return host
    }

    /// 递归找到 WKWebView 内部的 NSScrollView，关掉弹性滚动。
    /// macOS 的 WKWebView 没有公开的 scrollView 属性，只能遍历子视图。
    private static func disableBounce(in view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.verticalScrollElasticity = .none
            scroll.horizontalScrollElasticity = .none
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            return
        }
        for sub in view.subviews {
            disableBounce(in: sub)
        }
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

    // MARK: - 主实例脚本（通栏 + 镜像发射）

    private static func mainScript() -> WKUserScript {
        let source = """
        (function () {
          // 注入脚本任何一处抛错都直接进壳日志：这个脚本是壳和 web 的唯一粘合层。
          window.addEventListener('error', function (e) {
            try {
              window.webkit.messageHandlers.whaless.postMessage(
                { log: 'js error: ' + e.message + ' @' + e.lineno });
            } catch (err) {}
          });

          function post(obj) {
            try { window.webkit.messageHandlers.whaless.postMessage(obj); } catch (e) {}
          }

          // ---------- 注入样式 ----------
          // 主实例：侧栏整列藏掉（DOM 保留，点击/镜像照常）、grid 轨道钉成 0，
          // 主内容永远通栏——侧栏玻璃浮在内容上面，内容从玻璃下穿过。
          function injectStyle() {
            if (document.getElementById('whaless-style')) { return; }
            var style = document.createElement('style');
            style.id = 'whaless-style';
            style.textContent = [
              // web 自己的折叠按钮藏起来，由原生工具栏按钮承接折叠功能。
              // visibility 而不是 display：JS .click() 照样触发它的事件。
              '[class*="sidebarCol"] [class*="toggle"]{visibility:hidden !important}',
              '[class*="sidebar"] [class*="toggle"]{visibility:hidden !important}',
              // 桌面端让位变量（壳自己声明；上游 darwin 分支进不来）。
              ':root{--dsh-frame-top-clearance:48px;--dsh-frame-overlay-top:68px;',
              '  --whaless-sidebar-w:280px;',
              '  --dsh-frame-leading-clearance:calc(var(--whaless-sidebar-w) + 24px)}',
              // 折叠后让位收窄到交通灯 + 玻璃按钮那一行的宽度。
              '[data-sidebar-collapsed]{--dsh-frame-leading-clearance:180px}',
              // 页面标题/详情头：顶部让位 + 左侧让位（侧栏现在是浮层，标题不能压在玻璃下）。
              '[class*="pageHead"]:not([class*="pageHeading"]),'
                + '[class*="pageHeading"]:not([class*="pageHead"] *),'
                + '[class*="detailTop"],[class*="moreHead"]'
                + '{padding-top:calc(28px + var(--dsh-frame-top-clearance,48px)) !important;'
                + 'padding-inline-start:var(--dsh-frame-leading-clearance,0px) !important}',
              // 会话页标题行/标签行的左侧让位（上游 macOS 值再各让 20/12px）。
              '[class*="titleRow"]{'
                + 'padding-inline-start:calc(max(0px, var(--dsh-frame-leading-clearance,0px)) - 20px) !important}',
              '[class*="titleRow"] ~ [class*="tabs"]{'
                + 'padding-inline-start:calc(max(0px, var(--dsh-frame-leading-clearance,0px)) - 12px) !important}',
              // 主内容永远通栏：不动轨道（centerCol 有显式 grid 定位，改轨道数
              // 会把它挤进 0 宽轨道——实测整屏黑掉），而是让它横跨全部列，
              // 压在藏掉的侧栏轨道上面。玻璃浮在它上面，内容从玻璃下穿过。
              '[class*="centerCol"]{grid-column:1/-1 !important}',
              '[class*="sidebarCol"]{display:none !important}',
              // 禁止页面内部滚动容器的 overscroll 弹性回弹，否则双指拖动会露白边。
              'html,body{overscroll-behavior:none !important;}',
              '*{overscroll-behavior:none !important;}',
              // 暗色模式下，React 渲染出深色主题前，html/body 的默认白底会闪一下。
              '@media (prefers-color-scheme: dark){',
              '  html{background:#141414 !important;color-scheme:dark;}',
              '  body{background:#141414 !important;}',
              '}'
            ].join('\\n');
            (document.head || document.documentElement).appendChild(style);
          }

          // ---------- 主题采样 ----------
          // 页面自己的主题（用户在网页里切的）可能和系统外观不一致。广度优先找
          // 主栏第一个不透明背景的后代，拿到后上报 —— 系统切亮暗、页面内切主题都能跟上。
          function realPageBg() {
            var c = document.querySelector('[class*="centerCol"]');
            if (!c) { return ''; }
            var q = [c], n = 0;
            while (q.length && n < 300) {
              var el = q.shift(); n++;
              if (el !== c) {
                var b = getComputedStyle(el).backgroundColor;
                if (b && b !== 'transparent' && b !== 'rgba(0, 0, 0, 0)') {
                  var m = b.match(/^rgba?[(](.*)[)]$/);
                  if (m) {
                    var p = m[1].split(',');
                    if ((p.length > 3 ? parseFloat(p[3]) : 1) > 0.9) { return b; }
                  }
                }
              }
              for (var i = 0; i < el.children.length; i++) { q.push(el.children[i]); }
            }
            return '';
          }

          function pageBgRGB() {
            var v = realPageBg();
            var r = 20, g = 20, b = 20;
            var m = v.match(/^rgba?[(](.*)[)]$/);
            if (m) {
              var p = m[1].split(',');
              r = parseFloat(p[0]); g = parseFloat(p[1]); b = parseFloat(p[2]);
            } else if (v.charAt(0) === '#') {
              var hex = v.slice(1);
              if (hex.length === 3) { hex = hex.charAt(0) + hex.charAt(0)
                + hex.charAt(1) + hex.charAt(1) + hex.charAt(2) + hex.charAt(2); }
              r = parseInt(hex.slice(0, 2), 16);
              g = parseInt(hex.slice(2, 4), 16);
              b = parseInt(hex.slice(4, 6), 16);
            } else {
              v = '';
            }
            return { rgb: Math.round(r) + ',' + Math.round(g) + ',' + Math.round(b),
                     dark: (r * 299 + g * 587 + b * 114) / 1000 < 128 };
          }

          // ---------- 状态上报（按钮位置/显隐 + 玻璃主题） ----------
          // 宽度恒为 280（原生面板自己管宽度），只有折叠态和主题需要上报。
          var lastSent = '';
          function report() {
            var collapsed = !!document.querySelector('[data-sidebar-collapsed]');
            var pb = pageBgRGB();
            var key = (collapsed ? '1' : '0') + ':' + pb.rgb;
            if (key === lastSent) { return; }
            var changed = key !== lastSent;
            lastSent = key;
            post({ width: 280, collapsed: collapsed, dark: pb.dark, bg: pb.rgb });
            // 主题/折叠变了 → 镜像立刻跟进（主题类挂在 html 上，侧栏列自己的
            // observer 感知不到）。
            if (changed) { scheduleMirror(); }
          }

          // ---------- 侧栏镜像 ----------
          // 主实例是唯一数据源：侧栏列的 DOM 一变就序列化发给原生，由原生转发给
          // 侧栏实例渲染。点击/滚动反向往主实例投递，两边永远不会对不上账。
          function pathOf(el, root) {
            var path = [];
            var cur = el;
            while (cur && cur !== root) {
              var p = cur.parentElement;
              if (!p) { break; }
              var idx = 0;
              for (var i = 0; i < p.children.length; i++) {
                if (p.children[i] === cur) { idx = i; break; }
              }
              path.unshift(idx);
              cur = p;
            }
            return path;
          }
          function elByPath(root, path) {
            var cur = root;
            for (var i = 0; i < path.length; i++) {
              if (!cur) { return null; }
              cur = cur.children[path[i]];
            }
            return cur || null;
          }
          function scrollStates(col) {
            var out = [];
            var nodes = col.querySelectorAll('*');
            for (var i = 0; i < nodes.length; i++) {
              if (nodes[i].scrollTop > 0) {
                out.push({ p: pathOf(nodes[i], col), s: nodes[i].scrollTop });
              }
            }
            return out;
          }

          var mirCol = null, mirObs = null, mirTimer = 0, lastHtml = '';
          function attachMirrorObserver(col) {
            if (col === mirCol && mirObs) { return; }
            if (mirObs) { mirObs.disconnect(); }
            mirCol = col;
            mirObs = new MutationObserver(function () { scheduleMirror(); });
            mirObs.observe(col, { childList: true, subtree: true,
                                  attributes: true, characterData: true });
          }
          function scheduleMirror() {
            if (mirTimer) { return; }
            mirTimer = setTimeout(sendMirror, 80);
          }
          function sendMirror() {
            mirTimer = 0;
            var col = document.querySelector('[class*="sidebarCol"]');
            if (!col) { return; }
            attachMirrorObserver(col);
            var html = col.outerHTML;
            if (html === lastHtml) { return; }
            lastHtml = html;
            post({ mirror: { html: html, scrolls: scrollStates(col),
              theme: { c: document.documentElement.className || '',
                       d: document.documentElement.getAttribute('data-theme') || '',
                       b: document.body ? document.body.className : '' } } });
          }

          // 原生反向调用的入口（侧栏点击/滚动投递回来）。
          window.__whalessMirror = { send: function () { lastHtml = ''; sendMirror(); } };
          window.__whalessRemoteClick = function (path) {
            var col = document.querySelector('[class*="sidebarCol"]');
            var el = elByPath(col, path);
            if (!el) { return 'miss'; }
            el.click();
            return 'ok';
          };
          window.__whalessRemoteScroll = function (list) {
            var col = document.querySelector('[class*="sidebarCol"]');
            if (!col) { return; }
            for (var i = 0; i < list.length; i++) {
              var el = elByPath(col, list[i].p);
              if (el) { el.scrollTop = list[i].s; }
            }
          };

          function apply() {
            injectStyle();
            report();
          }

          // 临时探针：定位折叠窄栏的元素类名，看完删。
          setTimeout(function () {
            var el = document.elementFromPoint(50, 300);
            var chain = [];
            var cur = el;
            while (cur && cur !== document.body && chain.length < 6) {
              chain.push(cur.tagName + '.' + String(cur.className).slice(0, 60));
              cur = cur.parentElement;
            }
            var rails = [];
            document.querySelectorAll('[class*="rail"]').forEach(function (n) {
              var b = n.getBoundingClientRect();
              rails.push(String(n.className).slice(0, 60) + ' [' + Math.round(b.x) + ','
                + Math.round(b.y) + ' ' + Math.round(b.width) + 'x' + Math.round(b.height) + ']');
            });
            var keys = [];
            try {
              for (var i = 0; i < localStorage.length; i++) {
                var k = localStorage.key(i);
                if (/collap|sidebar|rail/i.test(k)) {
                  keys.push(k + '=' + String(localStorage.getItem(k)).slice(0, 40));
                }
              }
            } catch (e) {}
            post({ log: 'railProbe at50,300=' + (chain.join(' < ') || '-')
              + ' rails=[' + rails.join(' | ') + ']'
              + ' ls=[' + keys.join(' | ') + ']' });
          }, 3500);

          apply();
          document.addEventListener('DOMContentLoaded', apply);
          window.addEventListener('load', apply);
          var scheduled = false;
          new MutationObserver(function () {
            if (scheduled) { return; }
            scheduled = true;
            setTimeout(function () { scheduled = false; apply(); }, 50);
          }).observe(document.documentElement,
                     { childList: true, subtree: true, attributes: true });
          setInterval(apply, 600);
          // 镜像 observer 可能因 React 换节点失效：定期重挂。
          setInterval(function () {
            var col = document.querySelector('[class*="sidebarCol"]');
            if (col) { attachMirrorObserver(col); }
          }, 1000);
          setTimeout(sendMirror, 400);
          setTimeout(sendMirror, 1500);
          // 系统亮暗切换时页面主题会跟着变，但列宽不变 —— 强制重报一次。
          if (window.matchMedia) {
            var mq = window.matchMedia('(prefers-color-scheme: dark)');
            var onScheme = function () {
              lastSent = '';
              apply();
              // React 换主题有几帧延迟，晚一拍再采一次，确保拿到渲染后的底色。
              setTimeout(function () { lastSent = ''; apply(); }, 350);
            };
            if (mq.addEventListener) { mq.addEventListener('change', onScheme); }
            else if (mq.addListener) { mq.addListener(onScheme); }
          }
        })();
        """

        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // MARK: - 侧栏实例脚本（只渲染侧栏 + 镜像接收）

    private static func sideScript() -> WKUserScript {
        let source = """
        (function () {
          function post(obj) {
            try { window.webkit.messageHandlers.whalessSide.postMessage(obj); } catch (e) {}
          }
          window.addEventListener('error', function (e) {
            post({ log: 'side js error: ' + e.message + ' @' + e.lineno });
          });

          function injectStyle() {
            if (document.getElementById('whaless-side-style')) { return; }
            var style = document.createElement('style');
            style.id = 'whaless-side-style';
            style.textContent = [
              // 整页透明：玻璃在 WebView 底下透上来。
              'html,body{background:transparent !important}',
              // 只留侧栏：主内容/右侧栏整页藏掉，frame 退化为普通块。
              '[class*="centerCol"],[class*="sidebar-right"]{display:none !important}',
              '[class*="frame"]{display:block !important;background:transparent !important}',
              // 实例自己的侧栏真身藏起来（React 还管理着它，不能动 DOM），
              // 展示的是主实例镜像过来的那份。
              '[class*="sidebarCol"]{visibility:hidden !important}',
              '[data-whaless-mirror] [class*="sidebarCol"]{visibility:visible !important;'
                + 'background:transparent !important;width:100% !important;padding-top:0 !important}',
              '[data-whaless-mirror] [class*="sidebarCol"] > *,'
                + '[data-whaless-mirror] [class*="sidebarCol"] > * > *'
                + '{background:transparent !important}',
              // web 折叠按钮藏起来（原生按钮承接折叠）。
              '[class*="toggle"]{visibility:hidden !important}',
              // 玻璃上不显示滚动条；镜像里的列表自己滚。
              '*::-webkit-scrollbar{display:none !important}',
              '*{scrollbar-width:none !important}',
              'body{overflow:hidden !important}',
              ':root{--dsh-frame-top-clearance:48px;--dsh-frame-overlay-top:68px}'
            ].join('\\n');
            (document.head || document.documentElement).appendChild(style);
          }

          function pathOf(el, root) {
            var path = [];
            var cur = el;
            while (cur && cur !== root) {
              var p = cur.parentElement;
              if (!p) { break; }
              var idx = 0;
              for (var i = 0; i < p.children.length; i++) {
                if (p.children[i] === cur) { idx = i; break; }
              }
              path.unshift(idx);
              cur = p;
            }
            return path;
          }
          function elByPath(root, path) {
            var cur = root;
            for (var i = 0; i < path.length; i++) {
              if (!cur) { return null; }
              cur = cur.children[path[i]];
            }
            return cur || null;
          }

          var box = null, ready = false;
          function ensureBox() {
            if (box) { return box; }
            box = document.createElement('div');
            box.setAttribute('data-whaless-mirror', '');
            box.style.cssText = 'position:fixed;left:0;top:0;width:280px;height:100%;'
              + 'padding-top:50px;box-sizing:border-box;overflow:hidden;'
              + 'z-index:2147483000;background:transparent;';
            (document.body || document.documentElement).appendChild(box);
            // 镜像里的点击 → 算出路径 → 原生转发给主实例点同一个元素。
            box.addEventListener('click', function (e) {
              var col = box.firstElementChild;
              if (!col) { return; }
              var t = e.target;
              if (t === box) { return; }
              e.preventDefault();
              e.stopPropagation();
              var tag = t.tagName;
              if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') { return; }
              post({ sideClick: pathOf(t, col) });
            }, true);
            // 镜像里滚动 → 反向同步主实例的滚动位置。
            var scrollTimer = 0;
            box.addEventListener('scroll', function () {
              if (scrollTimer) { return; }
              scrollTimer = setTimeout(function () {
                scrollTimer = 0;
                var col = box.firstElementChild;
                if (!col) { return; }
                var out = [];
                var nodes = col.querySelectorAll('*');
                for (var i = 0; i < nodes.length; i++) {
                  if (nodes[i].scrollTop > 0) {
                    out.push({ p: pathOf(nodes[i], col), s: nodes[i].scrollTop });
                  }
                }
                post({ sideScroll: out });
              }, 120);
            }, true);
            return box;
          }

          // 原生转发进来的镜像挂载点。
          window.__whalessSideMount = function (payload) {
            if (!payload) { return; }
            injectStyle();
            ensureBox();
            // 主题类跟主实例走（颜色变量都挂在 html/body 的类上）。
            if (payload.theme) {
              var h = document.documentElement;
              h.className = payload.theme.c || '';
              if (payload.theme.d) { h.setAttribute('data-theme', payload.theme.d); }
              else { h.removeAttribute('data-theme'); }
              if (document.body) { document.body.className = payload.theme.b || ''; }
            }
            if (payload.html) { box.innerHTML = payload.html; }
            var col = box.firstElementChild;
            if (col && payload.scrolls) {
              for (var i = 0; i < payload.scrolls.length; i++) {
                var el = elByPath(col, payload.scrolls[i].p);
                if (el) { el.scrollTop = payload.scrolls[i].s; }
              }
            }
            if (!ready) { ready = true; post({ ready: 1 }); }
          };

          injectStyle();
          post({ ready: 1 });
          document.addEventListener('DOMContentLoaded', function () {
            injectStyle();
            post({ ready: 1 });
          });
        })();
        """

        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
        WKScriptMessageHandler {
        private let model: ShellModel
        private let origin: URL
        weak var webView: WKWebView?
        weak var sideWebView: WKWebView?
        weak var host: GlassHostView?
        private var provisionalRetries = 0

        init(model: ShellModel, origin: URL) {
            self.model = model
            self.origin = origin
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch message.name {
            case "whaless": handleMainMessage(body)
            case "whalessSide": handleSideMessage(body)
            default: break
            }
        }

        // MARK: 主实例消息

        private func handleMainMessage(_ body: [String: Any]) {
            if let log = body["log"] as? String {
                ShellLog.write(log)
                return
            }
            // 镜像帧 → 原生转发给侧栏实例（主实例是唯一数据源）。
            if let mirror = body["mirror"] as? [String: Any] {
                relayToSide(mirror)
            }
            // 页面主题（跟系统无关）决定玻璃和窗口底色的亮暗。
            if let dark = (body["dark"] as? NSNumber)?.boolValue {
                model.pageDark = dark
            }
            if let rgb = body["bg"] as? String {
                let parts = rgb.split(separator: ",").compactMap { Double($0) }
                if parts.count >= 3 {
                    let c = NSColor(calibratedRed: parts[0] / 255,
                                    green: parts[1] / 255,
                                    blue: parts[2] / 255, alpha: 1)
                    model.pageBgColor = c
                    host?.applyTheme(c, dark: model.pageDark)
                }
            }
            guard let width = (body["width"] as? NSNumber)?.doubleValue,
                  width > 0 else { return }
            let collapsed = (body["collapsed"] as? NSNumber)?.boolValue ?? false
            model.reportSidebar(width: width, collapsed: collapsed)
        }

        private func relayToSide(_ payload: [String: Any]) {
            guard let side = sideWebView,
                  !payload.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            side.evaluateJavaScript("__whalessSideMount(\(json));", completionHandler: nil)
        }

        // MARK: 侧栏实例消息

        private func handleSideMessage(_ body: [String: Any]) {
            if let log = body["log"] as? String {
                ShellLog.write(log)
                return
            }
            if body["ready"] != nil {
                // 侧栏实例就绪：让主实例立刻补发一帧镜像。
                webView?.evaluateJavaScript(
                    "window.__whalessMirror && window.__whalessMirror.send();",
                    completionHandler: nil)
                return
            }
            func json(_ obj: Any) -> String? {
                guard let data = try? JSONSerialization.data(withJSONObject: obj),
                      let s = String(data: data, encoding: .utf8) else { return nil }
                return s
            }
            if let path = body["sideClick"] as? [Int], let s = json(path) {
                webView?.evaluateJavaScript(
                    "window.__whalessRemoteClick && window.__whalessRemoteClick(\(s));",
                    completionHandler: nil)
            }
            if let list = body["sideScroll"] as? [[String: Any]], let s = json(list) {
                webView?.evaluateJavaScript(
                    "window.__whalessRemoteScroll && window.__whalessRemoteScroll(\(s));",
                    completionHandler: nil)
            }
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
            let role = webView === self.webView ? "main" : "side"
            ShellLog.write("didFinish[\(role)] \(webView.url.map(ShellLog.redact) ?? "-")")
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
