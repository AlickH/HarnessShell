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
        // web → 原生：侧栏宽度上报通道（按钮位置要贴着分割线走）。
        configuration.userContentController.add(context.coordinator, name: "whaless")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // 关掉这些手势：它们会让页面被缩放/拖出边界，露出背后的白边。
        // Electron 桌面端默认也不开，行为一致。
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        // 透明 WebView：侧栏那一片由原生 NSVisualEffectView 透上来（见 App.swift），
        // 页面自己负责把 frame/侧栏画成透明。
        webView.underPageBackgroundColor = .clear
        // 暗色模式启动时，页面加载前 WKWebView 会先露出它自己的默认白底，
        // 造成「白闪」。给它的 layer 一个跟随外观的底色，把这一闪压成暗色。
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        Self.syncWebViewAppearance(webView)
        // 关闭 WKWebView 自身的背景绘制（私有 KVC）：它默认在页面内容提交前
        // 画一块白底，是白闪的元凶。关掉后由上层 layer 底色兜底。
        webView.setValue(false, forKey: "drawsBackground")
        // 禁用弹性滚动：否则双指拖动会把页面拖出边界，露出背后的白边。
        Self.disableBounce(in: webView)
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

    /// WKWebView 的两层"兜底底色"都要清空：页面加载前露出的应该是窗口里的原生材质，
    /// 而不是白闪或一块纯色（以前为了压白闪铺了实色，现在实色会挡住毛玻璃）。
    private static func syncWebViewAppearance(_ webView: WKWebView) {
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.underPageBackgroundColor = .clear
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

    /// 无标题栏：内容铺满到交通灯下面。顶部那两个液态玻璃按钮是 SwiftUI 画的浮层，
    /// web 页面不知道它们存在，所以壳要把「让位」这件事自己补上——照抄官方桌面端
    /// 的做法，只是绕开那条打不开的 `data-platform=darwin` 分支。
    ///
    /// 展开/收起仍由标题栏的 SwiftUI 按钮触发（JS `.click()` 这个按钮），所以按钮
    /// 保留在 DOM 里且可见，两处入口指向同一个状态机。
    private static func sidebarScript() -> WKUserScript {
        let source = """
        (function () {
          // 注入脚本任何一处抛错都直接进壳日志：这个脚本是壳和 web 的唯一粘合层，
          // 静默死掉的后果是"原生按钮消失、web 按钮复活"，肉眼像整层注入被剥掉。
          window.addEventListener('error', function (e) {
            try {
              window.webkit.messageHandlers.whaless.postMessage(
                { log: 'js error: ' + e.message + ' @' + e.lineno });
            } catch (err) {}
          });
          // 注意：DOM 里可能同时存在多个 `[class*="sidebarCol"]` 节点（展开列和
          // 折叠 rail 各一份，或过渡期间两份都在），querySelector 取第一个会抓到
          // 哪个全看渲染顺序——上报值就会在 280/56 之间来回跳，按钮跟着乱跑。
          // 所以一律按"最宽的那个"算宽度，折叠状态则读 React 自己打的
          // `[data-sidebar-collapsed]`（它在折叠那一帧就打上，比宽度更可信）。
          // 复制品（ghost）是整列的 clone，类名里同样带 sidebarCol，但它钉死在窗口上、
          // 宽度永远是展开宽度 —— 一旦把它算进候选，量出来的宽度在整段动画里恒等于 280，
          // 原生的液态玻璃按钮就跟着一动不动，等动画结束才"啪"地跳到位。所以一律排除。
          function sidebars() {
            return Array.prototype.slice.call(
              document.querySelectorAll(
                '[class*="sidebarCol"]:not([data-whaless-ghost])'));
          }

          function widest(list) {
            var max = 0;
            for (var i = 0; i < list.length; i++) {
              var w = list[i].getBoundingClientRect().width;
              if (w > max) { max = w; }
            }
            return max;
          }

          // ---- 内容区跟随系统 ----
          // 要求是"跟系统外观走、用系统色"，不是页面自己选的亮/暗主题：
          // 所以在这里把 body 的深色标记按 macOS 外观强制同步（应用自己改了也按回去），
          // 内容区底色再由原生把 NSColor 系统色推过来。
          var darkQuery = null;
          function syncSystemTheme() {
            var body = document.body;
            if (!body || !window.matchMedia) { return; }
            var dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
            if (body.hasAttribute('data-ds-dark-theme') !== dark) {
              body.toggleAttribute('data-ds-dark-theme', dark);
            }
          }
          function watchSystemTheme() {
            if (!window.matchMedia) { return; }
            syncSystemTheme();
            if (darkQuery) { return; }
            darkQuery = window.matchMedia('(prefers-color-scheme: dark)');
            var onChange = function () {
              syncSystemTheme();
              reportTheme();
            };
            if (darkQuery.addEventListener) {
              darkQuery.addEventListener('change', onChange);
            } else if (darkQuery.addListener) {
              darkQuery.addListener(onChange);
            }
          }

          // 原生推来的"系统内容底色"（NSColor.textBackgroundColor 按当前外观解析）。
          // 这是真正的 macOS 系统色，不是主题里写死的亮/暗值：直接压到主题的
          // base token 上，内容区所有吃这个 token 的容器就都跟系统色走。
          // 点击后短时间内多刷几次（面板开合有自己的动画，等它落位按钮才出来）。
          window.__whalessApply = function () { apply(); };

          window.__whalessContentBg = function (value) {
            if (!value || !document.body) { return; }
            document.body.style.setProperty('--dsw-alias-bg-base', value, 'important');
          };

          // 页面主题单独上报：原生毛玻璃材质跟着它走。不能等侧栏 DOM——
          // React mount 之前那几秒窗口已经在显示了，材质得先是对的颜色。
          var lastThemeSent = '';
          function reportTheme() {
            var body = document.body;
            if (!body) { return; }
            var dark = body.hasAttribute('data-ds-dark-theme');
            var key = dark ? '1' : '0';
            if (key === lastThemeSent) { return; }
            lastThemeSent = key;
            try {
              window.webkit.messageHandlers.whaless.postMessage({ dark: dark });
            } catch (e) {}
          }

          // 右侧栏三个按钮：位置和状态报给原生，由原生画液态玻璃圆钮。
          // 只在静止态量（动画/拖拽里 apply 已经提前返回，不会为此强制布局）。
          var lastButtonsSent = '';
          function rectCenter(sel) {
            var el = document.querySelector(sel);
            if (!el) { return null; }
            var r = el.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0) { return null; }
            return [Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2)];
          }
          // 面板在滑动时先不报：那期间按钮的 rect 是动画中间值，报了原生按钮
          // 就会跟着满屏跑。等它落位再一次性出来（原地显隐，不跟着滑）。
          function panelSettled(panel) {
            if (!panel) { return false; }
            if (!panel.hasAttribute('data-sidebar-right-open')) { return false; }
            if (typeof panel.getAnimations !== 'function') { return true; }
            var anims = panel.getAnimations({ subtree: true });
            for (var i = 0; i < anims.length; i++) {
              var a = anims[i];
              if (a.playState === 'running'
                  && a.transitionProperty === 'transform') { return false; }
            }
            return true;
          }
          // 会话页右上角：开在应用里（split 控件）+ 更多操作（…）。
          // 位置报给原生画玻璃按钮；它们的菜单项也由原生用系统菜单来展示，
          // 这里只在后台"开一下菜单读 DOM、马上关掉"（探测期间弹出层被 CSS 藏住）。
          var lastHeaderSent = '';
          var menusProbed = false;

          // 默认 app 的图标：网页那颗 split 控件里就是 <img>，画到 canvas 取 dataURL。
          var lastIconData = null;
          function targetIconData() {
            var target = document.querySelector('[data-open-target]');
            var img = target && target.querySelector('img');
            if (!img || !img.complete || !img.naturalWidth) { return null; }
            try {
              var canvas = document.createElement('canvas');
              canvas.width = 64;
              canvas.height = 64;
              canvas.getContext('2d').drawImage(img, 0, 0, 64, 64);
              return canvas.toDataURL('image/png');
            } catch (e) { return null; }
          }

          function sessionHeaderData() {
            var more = document.querySelector('button[aria-label="更多操作"]');
            var target = document.querySelector('[data-open-target]');
            var center = document.querySelector('[class*="centerCol"]');
            var point = function (el) {
              if (!el) { return null; }
              var r = el.getBoundingClientRect();
              if (r.width <= 0 || r.height <= 0) { return null; }
              return [Math.round(r.left), Math.round(r.top),
                      Math.round(r.width), Math.round(r.height)];
            };
            return {
              more: point(more),
              target: point(target),
              // 这两颗挂在"内容区"层级：右边缘跟着内容列走，不跟窗口右边走。
              right: center
                ? Math.round(center.getBoundingClientRect().right) : null,
              width: Math.round(window.innerWidth),
              icon: (function () {
                var data = targetIconData();
                if (data !== lastIconData) { lastIconData = data; return data; }
                return null;
              })(),
              split: !!(target
                && target.querySelector('button[class*="chevron"]'))
            };
          }

          // 打开网页菜单 → 等它渲染 → 读条目 → 再关掉。菜单弹出是异步渲染的，
          // 所以每一步都用 setTimeout 串起来，不能同步读。
          function probeMenus() {
            if (menusProbed) { return; }
            var more = document.querySelector('button[aria-label="更多操作"]');
            var target = document.querySelector('[data-open-target]');
            var chevron = target && target.querySelector('button[class*="chevron"]');
            if (!more && !chevron) { return; }
            menusProbed = true;
            document.documentElement.classList.add('whaless-menu-probe');
            var labels = { more: [], apps: [] };

            // 把「图标节点」栅格化成 PNG dataURL：img 直接画；svg 先转 data URL 再画。
            function rasterize(source, width, height) {
              var canvas = document.createElement('canvas');
              canvas.width = 64;
              canvas.height = 64;
              canvas.getContext('2d').drawImage(source, 0, 0, 64, 64);
              return canvas.toDataURL('image/png');
            }

            function itemIcon(item, done) {
              var img = item.querySelector('img');
              if (img && img.complete && img.naturalWidth > 0) {
                try { done(rasterize(img, 64, 64)); return; } catch (e) {}
              }
              var svg = item.querySelector('svg');
              if (!svg) { done(null); return; }
              try {
                var xml = new XMLSerializer().serializeToString(svg);
                var url = 'data:image/svg+xml;base64,'
                  + btoa(unescape(encodeURIComponent(xml)));
                var image = new Image();
                image.onload = function () {
                  try { done(rasterize(image, 64, 64)); } catch (e) { done(null); }
                };
                image.onerror = function () { done(null); };
                image.src = url;
              } catch (e) { done(null); }
            }

            function readItems(done) {
              var nodes = document.querySelectorAll('[role="menu"] [role="menuitem"]');
              var entries = new Array(nodes.length);
              var remaining = nodes.length;
              if (!remaining) { done([]); return; }
              for (var i = 0; i < nodes.length; i++) {
                (function (node, index) {
                  itemIcon(node, function (icon) {
                    entries[index] = { label: String(node.textContent).trim(), icon: icon };
                    remaining -= 1;
                    if (remaining === 0) { done(entries); }
                  });
                })(nodes[i], i);
              }
            }

            function finish() {
              document.documentElement.classList.remove('whaless-menu-probe');
              try {
                window.webkit.messageHandlers.whaless
                  .postMessage({ menuLabels: labels });
              } catch (e) {}
            }

            var queue = [];
            if (more) {
              queue.push(function (next) {
                more.click();
                setTimeout(function () {
                  readItems(function (entries) {
                    labels.more = entries;
                    more.click();
                    setTimeout(next, 80);
                  });
                }, 160);
              });
            }
            if (chevron) {
              queue.push(function (next) {
                chevron.click();
                setTimeout(function () {
                  readItems(function (entries) {
                    labels.apps = entries;
                    chevron.click();
                    setTimeout(next, 80);
                  });
                }, 160);
              });
            }
            var run = function (index) {
              if (index >= queue.length) { setTimeout(finish, 80); return; }
              queue[index](function () { run(index + 1); });
            };
            run(0);
          }

          function reportSessionHeader() {
            var data = sessionHeaderData();
            var key = JSON.stringify(data);
            if (key !== lastHeaderSent) {
              lastHeaderSent = key;
              try {
                window.webkit.messageHandlers.whaless
                  .postMessage({ sessionHeader: data });
              } catch (e) {}
            }
            probeMenus();
          }

          // 原生选中系统菜单项后，回到网页里点同一个条目。
          window.__whalessPickMenu = function (kind, index) {
            var trigger = kind === 'apps'
              ? document.querySelector('[data-open-target] button[class*="chevron"]')
              : document.querySelector('button[aria-label="更多操作"]');
            if (!trigger) { return; }
            trigger.click();
            setTimeout(function () {
              var items = document.querySelectorAll(
                '[role="menu"] [role="menuitem"]');
              if (items[index]) { items[index].click(); }
            }, 100);
          };

          // 打开"开在应用里"的默认目标（主按钮）
          window.__whalessOpenTarget = function () {
            var button = document.querySelector('[data-open-target] button[class*="main"]');
            if (button) { button.click(); }
          };

          // 「新会话」胶囊：只要位置/尺寸，宽度在原生那边按 sidebarWidth 实时算。
          var lastNewSessionSent = '';
          function reportNewSession() {
            var el = document.querySelector(
              '[class*="sidebarCol"]:not([data-whaless-ghost]) [class*="newSession"]');
            var data = null;
            if (el) {
              var r = el.getBoundingClientRect();
              if (r.width > 0 && r.height > 0) {
                data = [Math.round(r.left), Math.round(r.top),
                        Math.round(r.height)];
              }
            }
            var key = JSON.stringify(data);
            if (key === lastNewSessionSent) { return; }
            lastNewSessionSent = key;
            try {
              window.webkit.messageHandlers.whaless
                .postMessage({ newSession: data });
            } catch (e) {}
          }

          function reportRightButtons() {
            var panel = document.querySelector('[data-sidebar-right-panel]');
            var showPanelButtons = panelSettled(panel);
            var splitEl = showPanelButtons
              ? document.querySelector('[data-dockkit-split-button]') : null;
            // 只要"有没有 / 能不能用"，不要坐标：三个按钮由原生按固定间距排，
            // 位置不跟网页走（否则开合时会叠在一起、高低也参差）。
            var data = {
              mode: !!(showPanelButtons
                && document.querySelector('[data-sidebar-right-mode]')),
              split: !!splitEl,
              splitEnabled: !!(splitEl && !splitEl.disabled),
              open: !!(panel && panel.hasAttribute('data-sidebar-right-open')),
              fullscreen: !!(panel
                && panel.getAttribute('data-sidebar-right-panel') === 'fullscreen')
            };
            var key = JSON.stringify(data);
            if (key === lastButtonsSent) { return; }
            lastButtonsSent = key;
            try {
              window.webkit.messageHandlers.whaless.postMessage({ rightButtons: data });
            } catch (e) {}
          }

          // 侧栏状态上报：原生按钮的位置和显隐都靠它。
          // 折叠动画 0.3s 期间会连发一串，有 lastSent 去重，静止时一条也不发。
          var lastSent = '';
          // 拖动分隔线期间：应用每帧都在改列宽、重排会话区。壳这边不再把每帧的
          // 宽度都跨进程喂给原生（液态玻璃按钮每帧重渲染很贵），而是限流到 ~30Hz：
          // 按钮跟着分隔线走、但不参与每一帧，松手时补一次精确值，不会跳。
          function dragging() {
            var f = frameEl();
            return !!(f && f.hasAttribute('data-dragging'));
          }
          var lastDragReport = 0;

          function report(list) {
            if (!list || !list.length) { return; }
            var width = Math.round(widest(list));
            if (width <= 0) { return; }
            var collapsed = !!document.querySelector('[data-sidebar-collapsed]');
            // 属性还没上来的首帧用宽度兜底（56px 窄条 = 折叠）。
            if (!collapsed && width < 200) { collapsed = true; }
            // 页面自己的主题（跟系统无关）：原生那层毛玻璃的材质要跟它走，
            // 不跟系统走——否则系统亮色 + 页面暗色时侧栏会是一块亮的雾。
            var dark = !!(document.body
              && document.body.hasAttribute('data-ds-dark-theme'));
            var key = width + ':' + (collapsed ? '1' : '0') + ':' + (dark ? '1' : '0');
            if (key === lastSent) { return; }
            lastSent = key;
            if (window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.whaless) {
              try {
                window.webkit.messageHandlers.whaless
                  .postMessage({ width: width, collapsed: collapsed, dark: dark });
              } catch (e) {}
            }
          }

          function injectStyle() {
            if (document.getElementById('whaless-style')) { return; }
            var style = document.createElement('style');
            style.id = 'whaless-style';
            // web 自己的折叠按钮彻底藏起来，由原生工具栏按钮承接折叠功能。
            // visibility 而不是 display：元素还在 DOM 里，JS .click() 照样触发它的事件。
            style.textContent = [
              '[class*="sidebarCol"] [class*="toggle"]{visibility:hidden !important}',
              '[class*="sidebar"] [class*="toggle"]{visibility:hidden !important}',
              // 右侧栏的三个按钮改由原生液态玻璃圆钮接管（展开 / 全屏 / 收起）。
              // 同样用 visibility：元素还在 DOM 里，原生按钮 .click() 调同一个事件。
              // 网页那颗「新会话」也画成胶囊形：收放动画里快照显示的就是它，
              // 落位后原生胶囊接上时形状一致，不会"从圆角矩形跳到胶囊"。
              '[class*="sidebarCol"] [class*="newSession"]'
                + '{border-radius:999px !important}',
              // 输入框外框（composer 那张大圆角卡片）：玻璃底。
              // 这里只能用 CSS 近似 —— glassEffect 是原生视图效果，挂在网页里
              // 要么被网页盖住、要么盖在网页上把文字糊掉。所以把"玻璃"的几个
              // 视觉要素都补齐：半透明底 + 更强的模糊/饱和 + 亮描边 + 顶部高光 + 斜向光泽。
              '[class*="composerStack"] [class*="card"]'
                + '{background:linear-gradient(135deg,'
                + 'rgba(255,255,255,.06),rgba(255,255,255,0) 45%),'
                + 'color-mix(in srgb,var(--dsw-alias-bg-layer-1) 45%,transparent)'
                + ' !important;'
                + ' -webkit-backdrop-filter:blur(32px) saturate(1.9);'
                + ' backdrop-filter:blur(32px) saturate(1.9);'
                + ' border:1px solid rgba(255,255,255,.14) !important;'
                + ' box-shadow:inset 0 1px 0 rgba(255,255,255,.16),'
                + 'inset 0 -1px 0 rgba(255,255,255,.04),'
                + '0 10px 30px rgba(0,0,0,.18) !important}',
              // 右侧栏引导区那几张大按钮：半透明底 + 背景模糊，做出玻璃卡片的感觉
              // （面板本身仍是实底，所以是"透玻璃质感"而不是真透桌面）。
              '[data-sidebar-right-guide-entry],'
                + '[data-sidebar-right-guide] [class*="entry"]'
                + '{background:color-mix(in srgb,var(--dsw-alias-bg-layer-1) 55%,transparent)'
                + ' !important;'
                + ' -webkit-backdrop-filter:blur(20px) saturate(1.6);'
                + ' backdrop-filter:blur(20px) saturate(1.6)}',
              // 会话页右上角两个控件改由原生接管（开在应用里 / 更多操作）。
              'button[aria-label="更多操作"],[data-open-target]'
                + '{visibility:hidden !important}',
              // 探测菜单项时把网页弹出层藏住：只读 DOM，不让人看见它闪一下。
              'html.whaless-menu-probe [role="menu"]'
                + '{visibility:hidden !important}',
              // 侧栏里的「新会话」由原生玻璃胶囊接管（位置/宽度跟侧栏走）。
              // 排除复制品：收放动画时快照里要保持原样。
              '[class*="sidebarCol"]:not([data-whaless-ghost]) [class*="newSession"]'
                + '{visibility:hidden !important}',
              '[data-sidebar-right-expand],'
                + '[data-sidebar-right-mode],'
                + '[data-sidebar-right-toggle],'
                + '[data-dockkit-split-button]{visibility:hidden !important}',
              // 无标题栏下，侧栏内容要往下让出交通灯 + 两个液态玻璃按钮那一行。
              '[class*="sidebarCol"]{padding-top:50px !important;box-sizing:border-box !important;}',
              // ---- 侧栏毛玻璃：页面只负责"别把材质盖住" ----
              // 原生那层 NSVisualEffectView 在 App.swift（窗口透明 + behindWindow），
              // 等价于官方桌面端 Electron 的 `vibrancy: "sidebar"`。这里把要透的链路
              // 全打成透明，并给侧栏铺一层和桌面端 darwin 模式同款的薄 tint：
              // 整列（含顶部 50px 让位区）有色，内容根不再画第二层底。
              '[class*="frame"]{background:transparent !important}',
              // tint 的取值照抄上游 darwin 模式：亮色 40%、暗色 50%，
              // 上下各带一点冷色渐变，玻璃才不是一层平灰。
              '[class*="sidebarCol"]{background:linear-gradient(to bottom,'
                + '#7a9bf01a,#7a9bf000 35%,#8f89b800 68%,#8f89b817),'
                + 'color-mix(in srgb,var(--dsw-specific-sidebar-fill) 40%,transparent)'
                + ' !important}',
              'body[data-ds-dark-theme] [class*="sidebarCol"]{'
                + 'background:linear-gradient(to bottom,'
                + '#7a9bf014,#7a9bf000 35%,#8f89b800 68%,#8f89b812),'
                + 'color-mix(in srgb,var(--dsw-specific-sidebar-fill) 50%,transparent)'
                + ' !important}',
              '[class*="sidebarCol"] > * > *{background:transparent !important}',
              // 内容区不再由网页铺底：底色改由原生 ContentBackplate 铺在 WebView 下面
              // （同一个系统色），这样原生玻璃层才有地方透出来。
              '[class*="centerCol"],[class*="bottomRow"]'
                + '{background:transparent !important}',
              '[class*="rightbarCol"]{background:var(--dsw-alias-bg-base) !important}',
              // 会话列表底部那条渐隐是"渐隐到侧栏实色底"的：侧栏改玻璃之后它
              // 会变成一条盖住材质的实色条，直接去掉（列表本身滚动不受影响）。
              '[class*="sidebarCol"] [class*="_fade"]{display:none !important}',
              // ---- 右侧栏第一次展开的入场动画 ----
              // 上游要等自己创建出 surface 才渲染右侧面板，面板挂载时已经是展开态：
              // CSS 过渡没有"上一态"可补间，第一次只能直接出现（看起来像闪一下），
              // 之后面板留在 DOM 里、开关才有过渡。这里给"第一次挂载"补一条同参数
              // 的入场动画，等它走完再由 JS 打标记，之后都交回给上游的过渡。
              '@keyframes whaless-right-in{'
                + 'from{transform:translateX(var(--dsh-sidebar-width))}}',
              'html:not([data-whaless-right-seen])'
                + ' [data-sidebar-right-panel][data-sidebar-right-open] [data-dockkit-host=dock],'
                + 'html:not([data-whaless-right-seen])'
                + ' [data-sidebar-right-panel][data-sidebar-right-open] [data-dockkit-empty],'
                + 'html:not([data-whaless-right-seen])'
                + ' [data-sidebar-right-panel][data-sidebar-right-open] [data-dockkit-divider]{'
                + 'animation:whaless-right-in var(--ds-transition-duration-slow,.3s) '
                + 'var(--ds-ease-in-out)}',
              '@media (prefers-reduced-motion:reduce){'
                + 'html:not([data-whaless-right-seen]) [data-sidebar-right-panel] *'
                + '{animation:none !important}}',
              // ---- 顶部让位：把桌面端 `[data-platform=darwin]` 那套等价补回来 ----
              // 上游 layout 里 darwin 模式会声明这两个变量（48px 标题栏 + 68px 浮层），
              // 页面标题（`pageHead` / `pageHeading`，28px + clearance）和设置遮罩都用它。
              // 壳不能直接打 data-platform=darwin：前端会等 preload 注入的
              // `dshDesktopBoot`，等不到就不 mount（白屏）。所以变量自己声明，
              // 各页面那条 darwin 分支下不来的规则也在这里补一条同类选择器。
              ':root{--dsh-frame-top-clearance:48px;--dsh-frame-overlay-top:68px}',

              // 注意排除 `pageHeading`：插件页里它是 `pageHead` 的子元素，名字里也含
              // "pageHead"，两个都吃到 76px 就叠成 152px，标题掉到半屏。而自动化任务页
              // 的标题恰好就叫 `pageHeading`（顶层），所以对它反过来排除「pageHead 的后代」，
              // 两边互不误伤。
              '[class*="pageHead"]:not([class*="pageHeading"]),'
                + '[class*="pageHeading"]:not([class*="pageHead"] *),'
                + '[class*="detailTop"],[class*="moreHead"]'
                + '{padding-top:calc(28px + var(--dsh-frame-top-clearance,48px)) !important}',
              // 折叠后主栏顶到左边，会话标题行会压在玻璃按钮底下。
              // 桌面端的写法是 leading clearance 160px（标题行自己减去 20px 当内距）。
              // 关键：挂在 frame 自己的 `data-sidebar-collapsed` 上，而不是 JS 加的类——
              // React 改这个属性和折叠是同一帧，标题跟侧栏一起动，不会等 50ms 防抖
              // 之后再补一次，看起来就像"闪一下"。
              // 160px 是上游给 macOS 定的值（他们的按钮从 x=88 起、到 164 结束）。
              // 我们的两个玻璃按钮是 SwiftUI 画的，位置略靠右（右缘约 166），
              // 照 160 走标题只剩 2px 余量，所以补到 180——两边差 20px，肉眼就是
              // "紧贴着"和"正常留白"的区别。标签行用同一条变量，仍然对齐。
              '[data-sidebar-collapsed]{--dsh-frame-leading-clearance:180px}',
              // 折叠后主栏往左吃掉那 56px 空轨道。
              // 上游 layout 里 `collapsedWidth = darwin ? 0 : 56`：桌面端折叠时侧栏轨道
              // 直接塌成 0，主栏从窗口左边缘开始，标题下的分隔线才会顶到边。我们走的是
              // web 分支，留着 56px 图标轨道（虽然整列被藏了），主栏就从 56 开始画，
              // 分隔线左边空一截。margin-left 负回 56：宽度是 stretch 自适应，
              // 右边缘仍落在原处，只有左边缘越过去，正好把分隔线和内容一起带到边。
              '[data-sidebar-collapsed] [class*="centerCol"]{margin-left:-56px !important}',
              // ---- 折叠/展开：面板当一张图整块平移 ----
              // 位移由 JS 每帧写入（见 __whalessAnim），这里只负责"长什么样"：
              //   · 列宽收窄时内容不许重排 → 宽度钉在展开宽度
              //   · 不裁切，让 .frame 的 overflow:hidden 在窗口边缘裁
              // 右侧栏（dsh-client-ui-sidebar-right）是同一套思路的静态版：
              //   transform:translateX(--dsh-sidebar-width) + visibility 延迟关闭。
              // 分隔线就用上游自己的：`.pI_x6G_sidebarCol{border-right:.5px solid
              // var(--dsw-alias-border-l3)}`（暗色 16% 白 / 亮色 12% 黑）。
              // 这条之前被 `border-right-width:0` 删掉了，现在按原设计补回来，
              // 不加额外描边 —— 和桌面端 web 模式下的分割线完全同一条。
              '[class*="sidebarCol"]{overflow:visible !important;'
                + 'border-right:.5px solid var(--dsw-alias-border-l3) !important}',
              '[class*="sidebarCol"] > * > *{'
                + 'width:var(--whaless-sidebar-w,280px) !important;'
                + 'min-width:var(--whaless-sidebar-w,280px) !important;'
                + 'max-width:none !important}',
              // 合成层只在动画那 300ms 开：常开的话面板静止时也独占一层，
              // 它的右缘会和主栏的分割线在合成器里对接出一条发亮的亚像素缝。
              '[data-whaless-anim] [class*="sidebarCol"] > * > *,[data-whaless-ghost]'
                + '{will-change:transform}',
              // ---- 位移 = [data-sidebar-collapsed] 的纯 CSS 函数，和右侧栏同一套 ----
              // 面板的过渡时长/曲线和列宽那条一模一样，两者在同一次样式重算里启动，
              // 所以中间不需要任何 JS 参与，也不会"卡"。
              '[class*="sidebarCol"] > * > *{'
                + 'transition:transform var(--ds-transition-duration-slow,.3s) '
                + 'var(--ds-ease-in-out,cubic-bezier(.4,0,.2,1))}',
              // 折叠态：整块平移到窗口外（-100% = 展开宽度，永远对得上）。
              '[data-sidebar-collapsed] [class*="sidebarCol"]:not([data-whaless-ghost]) > * > *'
                + '{transform:translateX(-100%)}',
              // 复制品的位移交给 CSS 过渡：和真身面板用同一条时长/曲线/位移，
              // 两者都在合成器上跑 —— 主线程再忙（会话页那种长对话）也不会掉帧，
              // 也就不会出现"真身顺、复制品一顿一顿"的相对位移。
              '[data-whaless-ghost]{transition:none !important;visibility:visible !important}',
              '[data-whaless-anim] [data-whaless-ghost]{'
                + 'transition:transform var(--ds-transition-duration-slow,.3s) '
                + 'var(--ds-ease-in-out,cubic-bezier(.4,0,.2,1)) !important}',
              '[data-whaless-ghost][data-whaless-ghost-closed]'
                + '{transform:translateX(-100%) !important}',
              // 影子 frame（复制品的祖先）只是个"状态冻结器"：几何全部由内联样式给死，
              // 皮肤给它加的装饰（伪元素、背景、边框）一律抹掉，别让它多画东西。
              '[data-whaless-ghost-frame]{transition:none !important;'
                + 'background:none !important;border:0 !important;'
                + 'box-shadow:none !important;grid-template-columns:none !important}',
              '[data-whaless-ghost-frame]:before,'
                + '[data-whaless-ghost-frame]:after'
                + '{content:none !important;display:none !important}',
              // 动画期间真身让位给冻结的那一份（复制品负责画面）。
              // :not 排除复制品——它自己类名里也有 sidebarCol，不然会被一起藏掉。
              '[data-whaless-frozen] [class*="sidebarCol"]:not([data-whaless-ghost])'
                + '{visibility:hidden !important}',
              // 宽版/图标版内容自带 0→1 淡入（`.wide` 在根上，`.railIn` 在子元素上）。
              // 常开这条（不只动画期间）：动画结束后 React 若再补一帧渲染，
              // 淡入会让整个面板"闪一下"。
              '[class*="sidebarCol"] [class*="wide"],'
                + '[class*="sidebarCol"] [class*="railIn"] *{animation:none !important}',
              // 列宽不做过渡：点下去一次到位（只重排/重绘一帧），
              // 平滑交给下面主栏的 transform —— 全程合成器，不逐帧跑布局。
              // 列宽跳变后主栏比窗口窄（展开态那一侧），滑动时尾边会露底；
              // 动画期间给 frame 铺一层和主栏同色的底盖住，收尾就撤。
              '[data-whaless-anim] [class*="frame"]{'
                + 'background:var(--dsw-alias-bg-base) !important;'
                + 'transition:none !important}',
              // 标题让位跟着侧栏一起过渡：只在壳主动切换的那一下挂，窗口缩放不拖慢。
              '[data-whaless-anim] [class*="titleRow"],'
                + '[data-whaless-anim] [class*="titleRow"] ~ [class*="tabs"]{'
                + 'transition:padding-inline-start var(--ds-transition-duration-slow,.3s) '
                + 'var(--ds-ease-in-out,cubic-bezier(.4,0,.2,1)) !important}',
              // 主栏：布局已经跳到终点，这里用 transform 把"内容原本该走的位移"
              // 补出来（起点由 JS 按实测的内容中心差写内联值）。
              '[data-whaless-anim] [class*="centerCol"]{'
                + 'transition:transform var(--ds-transition-duration-slow,.3s) '
                + 'var(--ds-ease-in-out,cubic-bezier(.4,0,.2,1)) !important}',
              '@media (prefers-reduced-motion:reduce){',
              '  [data-whaless-anim] [class*="titleRow"],'
                + '[data-whaless-anim] [class*="titleRow"] ~ [class*="tabs"],'
                + '[data-whaless-anim] [class*="centerCol"]{transition:none !important}',
              '}',
              // 会话页「对话 / 轨迹」是标题行下面单独一行（`grid-column:1/-1`），
              // 上游只给标题行让位，折叠后两行左边缘会差 140px。同一条 clearance
              // 补给它，两行文字左对齐（多出的 8px 是标题 crumb 自己的左右内距）。
              '[class*="titleRow"] ~ [class*="tabs"]'
                + '{padding-inline-start:calc(8px + max(0px, var(--dsh-frame-leading-clearance,0px) - 20px)) !important}',
              // 禁止页面内部滚动容器的 overscroll 弹性回弹，否则双指拖动会露白边。
              'html,body{overscroll-behavior:none !important;}',
              '*{overscroll-behavior:none !important;}',
              // 页面自底向上都得透，原生毛玻璃才看得见。暗色模式下原本这里铺
              // #141414 防白闪；现在不放底色反而不会闪（窗口/WebView 层也是透明的，
              // 露出来的是材质）。color-scheme 留着让表单控件跟随暗色。
              'html,body{background:transparent !important}',
              '@media (prefers-color-scheme: dark){html{color-scheme:dark}}'
            ].join('\\n');
            (document.head || document.documentElement).appendChild(style);
          }

          // 折叠态：sidebarCol 收成 56px 窄条，整列彻底消失，主栏顶到左边。
          // 只 visibility 不够——rail 里 `.sectionHeader` 的「添加工作区」按钮悬在列中间
          // （垂直居中），而它自己那条链上写着 visibility:visible，把可见性又抢了回去，
          // 结果左栏中间孤零零飘一个文件夹加号。
          // 补 opacity / pointer-events：opacity 在父级形成合成层，子元素抢不回来。
          var RAIL_HIDE = [
            ['visibility', 'hidden'],
            ['opacity', '0'],
            ['pointer-events', 'none'],
            ['background', 'transparent']
          ];

          // 展开态宽度缓存：动画那 280ms 里要把内容钉在这个宽度上，
          // 不然列一边缩、内容一边重排，就又不是"一整块"了。
          var expandedWidth = 280;

          function animating() {
            return document.documentElement.hasAttribute('data-whaless-anim');
          }

          // 折叠态的可见性压制，单独抽出来：动画一开始必须无条件清掉。
          // 否则展开时列上还挂着折叠期留下的 `opacity:0;visibility:hidden`（内联
          // !important），整段滑入都是隐形的，收尾才"啪"地出现 —— 就是"闪现"。
          function setRailHide(el, on) {
            for (var i = 0; i < RAIL_HIDE.length; i++) {
              if (on) {
                el.style.setProperty(RAIL_HIDE[i][0], RAIL_HIDE[i][1], 'important');
              } else {
                el.style.removeProperty(RAIL_HIDE[i][0]);
              }
            }
          }

          function clearRailHide() {
            var list = sidebars();
            for (var i = 0; i < list.length; i++) { setRailHide(list[i], false); }
          }

          // 上一拍读到的列宽，用来判断"是否已经稳定"。
          var lastSampledW = 0;

          // 右侧栏的"第一次展开"标记：见上面 CSS 的说明。
          var rightSeenScheduled = false;
          function markRightSeen() {
            if (rightSeenScheduled) { return; }
            var html = document.documentElement;
            if (html.hasAttribute('data-whaless-right-seen')) { return; }
            if (!document.querySelector(
                '[data-sidebar-right-panel][data-sidebar-right-open]')) { return; }
            rightSeenScheduled = true;
            setTimeout(function () {
              html.setAttribute('data-whaless-right-seen', '');
            }, durMs() * 1.5);
          }

          // 快照是某一刻"拍"下来的，主题一换它就过时了（深色快照滑进浅色界面）。
          // 记下拍摄时的主题指纹，复用前对一下，对不上就丢掉、退回真身滑入。
          var savedTheme = '';

          // 指纹只挑"页面自己的主题信号"：深色标记、body 的 class、body 底色。
          // 不能带 html 的 class —— 壳自己会往上挂 `whaless-rail`（apply 里跟着
          // 折叠状态 toggle），折叠/展开一翻转指纹就变，于是每次展开都把那张
          // 宽版快照当成"换主题了"扔掉，退回真身自己滑 —— 收起有快照、展开没快照，
          // 两个方向的观感自然对不上（元素和背景各走各的）。
          function themeKey() {
            var body = document.body;
            if (!body) { return ''; }
            return (body.className || '') + '|'
              + (body.hasAttribute('data-ds-dark-theme') ? '1' : '0') + '|'
              + getComputedStyle(body).backgroundColor;
          }

          function apply() {
            injectStyle();
            watchSystemTheme();
            reportTheme();
            markRightSeen();
            var list = sidebars();
            if (!list.length) { return; }
            // 拖动中：宽度要跟着手指实时变 —— 侧栏内容被 `--whaless-sidebar-w`
            // 钉着（这是动画用的），不更新它内容就停在旧宽度，松手才跳一下。
            // 其余侧栏逻辑（轨道显隐、两次采样防抖）仍让路；原生按钮限流跟随。
            if (dragging()) {
              var liveW = Math.round(widest(list));
              if (liveW >= 200 && liveW !== expandedWidth) {
                expandedWidth = liveW;
                document.documentElement.style.setProperty(
                  '--whaless-sidebar-w', liveW + 'px');
              }
              var now = performance.now();
              if (now - lastDragReport > 33) {
                lastDragReport = now;
                report(list);
              }
              return;
            }
            // 动画期间一帧 JS 都不跑：宽度由原生那边用同一条曲线自己补间（见
            // ShellModel.beginToggle），可见性也不能动。这里直接返回，省掉每帧的
            // querySelectorAll + getBoundingClientRect + 跨进程 postMessage。
            if (animating()) { return; }
            report(list);
            reportRightButtons();
            reportNewSession();
            reportSessionHeader();
            watch(list);
            for (var k = 0; k < list.length; k++) {
              var el = list[k];
              var w = el.getBoundingClientRect().width;
              // 展开宽度只认"连续两次采样一致"的值：动画刚结束那一拍如果还被
              // observer 触发一次，读到的是中间宽度，拿它当展开宽度用，复制品
              // 的宽度和位移会整体歪掉。
              if (w >= 200) {
                if (lastSampledW === w || lastSampledW === 0) {
                  expandedWidth = Math.round(w);
                  document.documentElement.style.setProperty(
                    '--whaless-sidebar-w', expandedWidth + 'px');
                }
              }
              lastSampledW = w;
              if (w > 0 && w < 200) {
                // 折叠态：整列彻底消失。
                setRailHide(el, true);
              } else if (w >= 200) {
                // 展开态：完整恢复（过渡期间两份节点都可能在，各按各的宽度处理）。
                setRailHide(el, false);
              }
            }
            document.documentElement.classList.toggle('whaless-rail',
              !!document.querySelector('[data-sidebar-collapsed]'));
          }

          // 每个见过的 sidebarCol 节点挂一次 ResizeObserver（WeakSet 去重）。
          // 折叠动画期间每帧回调 apply()，宽度一路流给原生，按钮才跟得上分割线。
          var ro = null;
          var watched = (typeof WeakSet === 'function') ? new WeakSet() : null;
          function watch(list) {
            if (!watched || typeof ResizeObserver !== 'function') { return; }
            if (!ro) { ro = new ResizeObserver(function () { apply(); }); }
            for (var i = 0; i < list.length; i++) {
              if (watched.has(list[i])) { continue; }
              watched.add(list[i]);
              ro.observe(list[i]);
            }
          }

          var scheduled = false;
          function schedule() {
            if (scheduled) { return; }
            scheduled = true;
            setTimeout(function () { scheduled = false; apply(); }, 50);
          }

          // ---- 折叠/展开：位移交给 CSS，JS 只负责"冻一张图" ----
          //
          // 右侧栏为什么顺（dsh-client-ui-sidebar-right）：面板 position:absolute，
          // 只改 transform + 一条 transition —— 合成器动画，零重排、零 JS。
          //
          // 左侧栏之前是 JS 每帧读主栏左缘、写 CSS 变量、再跨进程上报，所以"卡"。
          // 现在走同一条路：面板位移只由 `[data-sidebar-collapsed]` 这一个属性决定，
          // 过渡时长/曲线和列宽那条完全一样。列宽过渡本来就有（应用自己在 frame 上
          // 用 useLayoutEffect 打 `data-animating`，和 grid-template-columns 同一次提交），
          // 主栏 margin 和面板 transform 也都在这同一次样式重算里启动 —— 三者同时起跑、
          // 同一条曲线，位置天然吻合，整段动画中间一帧 JS 都不用跑。
          //
          // JS 只留一件 CSS 干不了的事：收起那一刻内容会从宽版换成图标版（React 行为），
          // 提前克隆一份停在窗口上，让滑出去的始终是同一张图。复制品也放进 frame 里，
          // 这样它在同一次重算里拿到 `data-sidebar-collapsed`，和列宽一起起跑。
          var anim = null;
          // 收起时留下的宽版快照。展开方向复用它：那样滑进来的自始至终是同一张
          // 画面，不会出现 React 半路把图标版换成宽版（"滑到一半画面切了"）。
          var savedGhost = null;

          // 动画时长取应用自己的 token（默认 .3s）。兜底超时必须在这之上，
          // 否则"到点强制收尾"会把还在滑的复制品撤掉 —— 画面就是滑到一半突然消失。
          function durMs() {
            var v = getComputedStyle(document.documentElement)
              .getPropertyValue('--ds-transition-duration-slow').trim();
            var n = parseFloat(v);
            if (!n) { return 300; }
            return v.indexOf('ms') > 0 ? n : n * 1000;
          }

          function frameEl() {
            return document.querySelector('[class*="frame"]');
          }

          function copyScroll(from, to) {
            var a = from.querySelectorAll('*');
            var b = to.querySelectorAll('*');
            for (var i = 0; i < a.length && i < b.length; i++) {
              if (a[i].scrollTop) { b[i].scrollTop = a[i].scrollTop; }
            }
          }

          // 挑出"真正画着面板"的那一列：优先含宽版内容的（`.wide`），其次最宽的。
          // 不能只取 querySelector 的第一个——收起/展开的中间态里 DOM 里可能同时有两列。
          function colToClone() {
            var list = sidebars(), best = null, bestScore = -1;
            for (var i = 0; i < list.length; i++) {
              var el = list[i];
              var r = el.getBoundingClientRect();
              if (r.height < 80 || r.width <= 0) { continue; }
              var score = r.width + (el.querySelector('[class*="wide"]') ? 1000 : 0);
              if (score > bestScore) { bestScore = score; best = el; }
            }
            return best;
          }

          // 把这一列整块复制、钉在窗口上。宽度用缓存的展开宽度——列宽这会儿可能已经
          // 收到 56 了，复制品必须按展开的样子出现，否则里面的内容会重排。
          //
          // 复制品不再挂进真正的 frame。皮肤会按 frame 上的状态属性改写侧栏内部样式
          // （claude 皮肤的 `[data-dsh-claude-part~=layout-frame]:not([data-sidebar-collapsed])
          // > ... button[new-session]` 就是一条），折叠属性一出现，快照里的「新会话」
          // 按钮立刻从菜单行变回带边框的大按钮——看起来就是闪了一下。所以给复制品配一个
          // 「点击前那一帧」的 frame 影子当祖先，挂在 body 下：祖先链上的状态从此冻结，
          // 快照自始至终长得跟点击前一样。几何由 placeGhost 内联写死。
          function ghostShell(frame) {
            var shell = document.createElement('div');
            var attrs = frame.attributes;
            for (var i = 0; i < attrs.length; i++) {
              var name = attrs[i].name;
              if (name === 'class' || name === 'style'
                  || name === 'data-animating' || name === 'data-sidebar-collapsed'
                  || name === 'data-whaless-ghost-frame') { continue; }
              shell.setAttribute(name, attrs[i].value);
            }
            shell.setAttribute('data-whaless-ghost-frame', '');
            return shell;
          }

          function placeGhost(shell, rect) {
            var s = shell.style;
            function put(k, v) { s.setProperty(k, v, 'important'); }
            put('position', 'fixed');
            put('left', rect.left + 'px');
            put('top', rect.top + 'px');
            put('width', expandedWidth + 'px');
            put('height', rect.height + 'px');
            put('margin', '0');
            put('padding', '0');
            put('border', '0');
            put('display', 'block');
            put('overflow', 'hidden');
            put('background', 'none');
            put('pointer-events', 'none');
            put('z-index', '2147483000');
          }

          // 克隆会把 SVG 内部的 id 一起复制一份：快照里 `url(#dsh-wordmark-badge-clip)`
          // 这类引用仍然指向文档里第一次出现的那份 —— 真身里那份。真身被冻成
          // visibility:hidden 之后，那个 clipPath 画不出东西，快照里的「HARNESS」
          // 徽标就只剩一块蓝底。给复制品里的 id 换前缀、引用跟着改，让快照只认自己的 defs。
          function rewriteGhostIds(ghost) {
            var prefix = 'whaless-ghost' + (++ghostSeq) + '-';
            var map = {};
            var withId = ghost.querySelectorAll('[id]');
            var i, el, old;
            for (i = 0; i < withId.length; i++) {
              old = withId[i].getAttribute('id');
              if (!old) { continue; }
              map[old] = prefix + old;
              withId[i].setAttribute('id', map[old]);
            }
            var REFS = ['clip-path', 'mask', 'filter', 'fill', 'stroke',
                        'marker-start', 'marker-mid', 'marker-end', 'href', 'xlink:href'];
            var nodes = ghost.querySelectorAll('*');
            for (i = 0; i < nodes.length; i++) {
              el = nodes[i];
              for (var k = 0; k < REFS.length; k++) {
                var v = el.getAttribute(REFS[k]);
                if (!v) { continue; }
                var at = v.indexOf('url(#');
                if (at >= 0) {
                  var end = v.indexOf(')', at);
                  var id = v.slice(at + 5, end).trim();
                  if (map[id]) {
                    el.setAttribute(REFS[k],
                      v.slice(0, at + 5) + map[id] + v.slice(end));
                  }
                } else if (v.charAt(0) === '#' && map[v.slice(1)]) {
                  el.setAttribute(REFS[k], '#' + map[v.slice(1)]);
                }
              }
            }
          }
          var ghostSeq = 0;

          function makeGhost() {
            var col = colToClone();
            var frame = frameEl();
            if (!col || !frame) { return null; }
            var rect = col.getBoundingClientRect();
            var ghost = col.cloneNode(true);
            ghost.setAttribute('data-whaless-ghost', '');
            rewriteGhostIds(ghost);
            // 底色不在这里画：侧栏要透出原生毛玻璃，克隆体自带和真身同一条
            // CSS（列上的 tint + 内容根透明），跟着滑的就是同一张"半透明"的图。
            // 影子 frame 负责"长在展开态里"，复制品自己只负责尺寸和位移。
            ghost.style.cssText = 'position:relative;left:0;top:0;width:100%;height:100%;'
              + 'margin:0;overflow:hidden;box-sizing:border-box;'
              + 'visibility:visible !important;';
            var shell = ghostShell(frame);
            shell.appendChild(ghost);
            placeGhost(shell, rect);
            document.body.appendChild(shell);
            copyScroll(col, ghost);
            savedTheme = themeKey();
            return shell;
          }

          // 内容当前的横向中心（页面坐标）。列宽跳变后用它算"内容实际该走多远"：
          // 长对话是居中列，列变宽时内容不是简单平移整个列宽，而是重新居中。
          function contentCenterX() {
            var sc = document.querySelector('[data-conversation-scroll]');
            if (!sc) {
              var c = document.querySelector('[class*="centerCol"]');
              if (c) { sc = c; }
            }
            if (!sc) { return null; }
            var r = sc.getBoundingClientRect();
            return r.left + r.width / 2;
          }

          // 真身面板此刻的实际位移。收尾时把复制品摆到同一个值上再撤，
          // 否则"换人"那一帧会差 1~2px —— 就是展开末尾那一下抖动。
          function panelTx() {
            var col = document.querySelector(
              '[class*="sidebarCol"]:not([data-whaless-ghost])');
            var mid = col && col.firstElementChild;
            var pan = mid && mid.firstElementChild;
            if (!pan) { return 0; }
            var m = getComputedStyle(pan).transform;
            if (!m || m === 'none') { return 0; }
            var inner = m.slice(m.indexOf('(') + 1, -1).split(',');
            var tx = parseFloat(inner[4]);
            return isNaN(tx) ? 0 : tx;
          }

          function finish() {
            if (!anim) { return; }
            var a = anim;
            anim = null;
            if (a.timer) { clearTimeout(a.timer); }
            if (a.ghost && a.onGhostEnd) {
              a.ghost.removeEventListener('transitionend', a.onGhostEnd);
            }
            // 面板自己的 transform 过渡可能比列宽晚一两帧才落位。先等它走完再"换人"：
            // 否则最后一帧真身还停在离终点 1px 的地方，复制品一撤，边缘和原生按钮
            // 就一起往回跳一像素。最多等 4 帧，绝不把画面一直冻着。
            var target = a.collapsing ? -expandedWidth : 0;
            var tries = 0;
            (function swapWhenSettled() {
              if (a.ghost && tries++ < 4 && Math.abs(panelTx() - target) > 0.3) {
                requestAnimationFrame(swapWhenSettled);
                return;
              }
              swap(a);
            })();
          }

          // 把画面从复制品换回真身，并收掉这一轮的冻结状态。
          function swap(a) {
            var html = document.documentElement;
            var shell = a.shell;
            if (a.ghost) {
              // 先把复制品挪到真身的位置（差多少补多少），再让它退场：
              // 正反两个方向最后都严丝合缝，不会"到点抖一下"。
              a.ghost.style.setProperty(
                'transform', 'translateX(' + panelTx() + 'px)', 'important');
            }
            // 真身先露面，复制品后撤 —— 顺序反了会空一帧。
            html.removeAttribute('data-whaless-frozen');
            if (shell && shell.parentNode) {
              shell.parentNode.removeChild(shell);
              // 快照留着：下一次展开要靠它，否则会滑到一半换内容。
              // 收起方向结束时它已经在窗外；展开方向结束（停在展开位）要复位回窗外，
              // 否则下次展开没有起点。
              a.ghost.style.removeProperty('transform');
              a.ghost.setAttribute('data-whaless-ghost-closed', '');
              savedGhost = shell;
            }
            if (a.center) {
              a.center.style.removeProperty('transform');
              a.center.style.removeProperty('transition');
            }
            html.removeAttribute('data-whaless-anim');
            apply();
            // 原生侧在动画窗口内故意不理宽度上报，而 report() 已经记过 lastSent，
            // 不重置的话最终宽度永远送不过去（按钮位置会停在补间的终点值上）。
            setTimeout(function () { lastSent = ''; apply(); }, 150);
          }

          window.__whalessAnim = {
            // 原生点按钮之前调：冻画面、挂结束监听；真正的位移在点下去那一帧由 CSS 接管。
            begin: function () {
              if (anim) { finish(); }
              var html = document.documentElement;
              var frame = frameEl();
              var collapsing = !document.querySelector('[data-sidebar-collapsed]');
              anim = { ghost: null, shell: null, center: null, frame: frame,
                       timer: 0, onEnd: null, onGhostEnd: null,
                       beforeCenter: null, collapsing: collapsing };
              anim.beforeCenter = contentCenterX();
              if (collapsing) {
                // 收起：内容马上要换成图标版，先冻一份。
                anim.shell = makeGhost();
                anim.ghost = anim.shell && anim.shell.firstElementChild;
                // 先把"展开态"这一版样式落定（一次强制样式计算，不是每帧），
                // 之后 afterClick 里加 closed 属性，过渡才有起点。
                if (anim.ghost) {
                  void anim.ghost.offsetWidth;
                  html.setAttribute('data-whaless-frozen', '');
                }
              } else {
                // 展开：清掉折叠期留下的可见性压制，否则整段滑入是隐形的、收尾才"啪"出现。
                clearRailHide();
                // 展开也要冻：折叠态 DOM 里只有图标版，React 会在滑到一半时把它换成
                // 宽版 —— 那就是"滑到一半画面切了"。复用收起时留下的宽版快照，
                // 从窗外原样滑进来。
                if (savedGhost && savedTheme !== themeKey()) {
                  // 主题变了：旧快照作废，让真身自己滑进来（内容会换，但颜色不会错）。
                  savedGhost = null;
                }
                if (savedGhost) {
                  var g = savedGhost;
                  savedGhost = null;
                  anim.shell = g;
                  anim.ghost = g.firstElementChild;
                  // 快照一直保持 closed 态（translateX(-100%)），挂回来先把这一版
                  // 样式落定，afterClick 去掉 closed 它才会从窗外滑进来。
                  g.firstElementChild.setAttribute('data-whaless-ghost-closed', '');
                  document.body.appendChild(g);
                  void anim.ghost.offsetWidth;
                  html.setAttribute('data-whaless-frozen', '');
                }
              }
              html.setAttribute('data-whaless-anim', '');
              if (anim.ghost) {
                anim.onGhostEnd = function (e) {
                  if (e.target === anim.ghost && e.propertyName === 'transform') {
                    finish();
                  }
                };
                anim.ghost.addEventListener('transitionend', anim.onGhostEnd);
              }
              // 兜底：万一没触发 transitionend（列宽没变），别把画面一直冻着。
              // 必须晚于动画本身，否则会在半路把复制品撤掉。
              anim.timer = setTimeout(finish, durMs() * 1.6 + 300);
            },

            // 点完按钮同步调用：和真身同帧切换复制品的 closed 属性，
            // 两边从同一次样式重算开始、同一条曲线滑，中缝不再靠每帧 JS 修。
            afterClick: function () {
              if (!anim || !anim.ghost) { return; }
              // React 的提交在事件之后（微任务/下一帧），这里必须等布局真的变了
              // 才能量出"内容该走多远"；rAF 在提交之后、绘制之前，正好。
              var tries = 0;
              function start() {
                if (!anim) { return; }
                if (anim.collapsing) {
                  anim.ghost.setAttribute('data-whaless-ghost-closed', '');
                } else {
                  anim.ghost.removeAttribute('data-whaless-ghost-closed');
                }
                var col = document.querySelector('[class*="centerCol"]');
                var after = contentCenterX();
                var delta = (col && after !== null && anim.beforeCenter !== null)
                  ? anim.beforeCenter - after : 0;
                // 布局还没提交时差值是 0，下一帧再看（最多 3 帧）
                if (Math.abs(delta) < 0.5 && tries++ < 3) {
                  requestAnimationFrame(start);
                  return;
                }
                if (!col || Math.abs(delta) < 0.5) { return; }
                // 布局已经跳到终点：把主栏先摆回"内容原本在的位置"，再补间到 0。
                anim.center = col;
                var st = col.style;
                st.setProperty('transition', 'none', 'important');
                st.setProperty('transform', 'translateX(' + delta + 'px)', 'important');
                void col.offsetWidth;
                st.removeProperty('transition');
                st.setProperty('transform', 'translateX(0px)', 'important');
              }
              requestAnimationFrame(start);
            }
          };

          // 松手：等应用自己把 data-dragging 摘掉，再补一次上报，按钮按新宽度归位。
          ['pointerup', 'pointercancel'].forEach(function (name) {
            document.addEventListener(name, function () {
              setTimeout(apply, 0);
            }, true);
          });

          apply();
          document.addEventListener('DOMContentLoaded', function () {
            apply();
            // 主题是挂在 body 上的属性：切主题要立刻让原生材质跟上。
            new MutationObserver(reportTheme).observe(document.body, {
              attributes: true, attributeFilter: ['data-ds-dark-theme']
            });
            reportTheme();
          });
          window.addEventListener('load', apply);
          new MutationObserver(schedule)
            .observe(document.documentElement, { childList: true, subtree: true });
          setInterval(apply, 600);
        })();
        """

        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
        WKScriptMessageHandler {
        private let model: ShellModel
        private let origin: URL
        weak var webView: WKWebView?
        private var provisionalRetries = 0

        init(model: ShellModel, origin: URL) {
            self.model = model
            self.origin = origin
        }

        /// 侧栏状态上报：只在主线程改 @Published，SwiftUI 按钮的位置跟着分割线走。
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "whaless",
                  let body = message.body as? [String: Any] else { return }
            if let log = body["log"] as? String {
                ShellLog.write(log)
                return
            }
            if let buttons = body["rightButtons"] as? [String: Any] {
                model.reportRightButtons(buttons)
            }
            if let newSession = body["newSession"] as? [NSNumber] {
                model.reportNewSession(newSession)
            }
            if let header = body["sessionHeader"] as? [String: Any] {
                model.reportSessionHeader(header)
            }
            if let labels = body["menuLabels"] as? [String: Any] {
                model.reportMenuLabels(labels)
            }
            if let dark = (body["dark"] as? NSNumber)?.boolValue {
                model.reportTheme(dark: dark)
            }
            guard let width = (body["width"] as? NSNumber)?.doubleValue,
                  width > 0 else { return }
            let collapsed = (body["collapsed"] as? NSNumber)?.boolValue ?? false
            model.reportSidebar(width: width, collapsed: collapsed)
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
            model.pushSystemContentColor()
            ShellLog.write("didFinish \(webView.url.map(ShellLog.redact) ?? "-")")
            // 白屏排查：把页面标题和首屏文字记下来，能立刻区分"没加载"和"加载了但渲染空"。
            for delay in [0.0, 6.0, 14.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    webView.evaluateJavaScript("""
                        (function () {
                          var side = document.querySelector('[class*="sidebarCol"]');
                          var m = document.querySelector('[class*="centerCol"]');
                          function w(el) { return el ? Math.round(el.getBoundingClientRect().width) : '-'; }
                          // 探测侧栏内部「真实内容根」的 top（quietBars / logoRow），
                          // 验证 padding-top 是否真的把它压到按钮（y≈44）下方。
                          var firstTop = '-';
                          var pad = '-';
                          // 页面标题（插件 / 自动化任务这类整页视图）的顶部内距。
                          // 壳靠 `[class*="pageHead"]` 补到 28+48px；哪天取到 28px，
                          // 说明前端改了类名，标题就又会钻到玻璃按钮底下。
                          var headPad = '-';
                          var head = document.querySelector('[class*="pageHead"]');
                          if (head) { headPad = getComputedStyle(head).paddingTop; }
                          if (side) {
                            pad = getComputedStyle(side).paddingTop;
                            var qb = side.querySelector('[class*="quietBars"]')
                                 || side.querySelector('[class*="logoRow"]')
                                 || side.querySelector('[class*="root"]');
                            if (qb) {
                              var r = qb.getBoundingClientRect();
                              firstTop = Math.round(r.top) + '/' + Math.round(r.height);
                            }
                          }
                          // 毛玻璃链路：这几层的背景只要有一层不透明，材质就透不上来。
                          return 'side=' + w(side) + ' center=' + w(m)
                            + ' rail=' + (document.documentElement.classList.contains('whaless-rail') ? '1' : '0')
                            + ' pad=' + pad + ' quietTop=' + firstTop
                            + ' headPad=' + headPad;
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
