# Whaless

给 DeepSeek Harness 的 web UI 套一个原生 macOS 窗口：双击就开，关掉就退，不占终端。

```
┌─────────────────────────┐
│  Whaless.app (SwiftUI)  │
│   ├─ WKWebView ─────────┼──▶ http://127.0.0.1:<port>/?token=…
│   └─ Process ───────────┼──▶ dsh web --no-open --port 0
└─────────────────────────┘
```

约 800 行 Swift，不做前端、不改内核。它和 iOS 端的 `Whaless`（`~/Developer/Whaless`）
没有任何共享代码：那个接的是自定义桥协议，这个只是把内核渲染好的页面装进一个窗口。

## 为什么不是"探测端口就直接打开"

这一版 `dsh web` 带浏览器认证：直接访问 `/` 会拿到 **401**，只有它启动时打印的那行

```
dsh web: http://127.0.0.1:53443/?token=…
```

才能进去（令牌换一个绑定 Host 的 cookie，之后正常）。所以壳必须**自己拥有进程**，
从 stdout 里抓那行地址。借用一个别人起的实例是没用的——拿不到它的令牌。

由此决定了三件事：

- `--port 0`：端口交给系统分配，永不和别的实例撞；
- stdout 必须实时读（`Pipe` + `readabilityHandler`），不能只重定向到文件；
- 退出/崩溃后要能收拾干净（见下文"孤儿进程"）。

## 内核只认 npm 那一份

壳是 npm 内核的外壳，所以定位顺序只有两个来源：

1. `npm i -g` 装的 `dsh`（`/opt/homebrew/bin`、`/usr/local/bin`、`~/.local/bin`）；
2. npx 缓存里的 `@deepseek-ai/dsh/lib/bin.js`（配 Homebrew 的 node）。

**会主动跳过指向桌面 App 的软链**：`/usr/local/bin/dsh` 在很多机器上其实是
`/Applications/DeepSeek Harness.app/.../cli/bin/dsh` 的别名，它不是 npm 内核、
也不会跟着 npm 更新，靠 `resolvingSymlinksInPath()` 按真实路径排除。

都没有就在界面上给一个「安装 npm 版内核」按钮，直接跑
`npm install -g @deepseek-ai/dsh@latest`。

## 内核菜单

- **检查内核更新…**（⇧⌘U）：`dsh -V` 拿当前版本，查
  `registry.npmjs.org/@deepseek-ai/dsh/latest` 拿最新版本，不一致就提示更新。
  npm 全局那种直接 `npm install -g @deepseek-ai/dsh@latest`，完成后可一键重启。
  npx 缓存那种只提示"重启会拿最新版"，不擅自改缓存。
- **安装 / 重装 npm 版内核…**：手动兜底。
- **打开日志**。

版本只做"是否相同"的判断，不假装能比较 prerelease 大小（`0.2.2-alpha.3` vs `0.2.1-rc.5`）。

## 补了哪些浏览器默认能力

WKWebView 只是渲染引擎。按前端 bundle 里**真实用到**的 API 补的，不是通用清单：

| 能力 | 实现 |
|---|---|
| `<input type=file>` 上传 | `runOpenPanelWith` → `NSOpenPanel` |
| 下载（`download` 属性） | `WKDownloadDelegate` → `NSSavePanel` |
| 外链 / `window.open` | `NSWorkspace.shared.open`，不在壳里劫持 |
| `beforeunload` 确认 | `runBeforeUnloadConfirmPanel` |
| JS `alert/confirm/prompt` | 三个 `WKUIDelegate` 方法 |
| ⌘R / ⌘± / ⌘0 | SwiftUI `.commands` |

拖拽上传、剪贴板不需要额外代码（HTML5 事件和 `navigator.clipboard` 原生可用）。

## 单窗口

- 场景用 `Window` 而不是 `WindowGroup`：后者每次"重新打开 App"都会新建一个窗口，
  系统再把它们合并成标签页——这就是"点一下多出一个标签"的来源。
- `NSWindow.allowsAutomaticWindowTabbing = false`（必须在 `willFinishLaunching` 里设，
  等窗口建好就晚了）+ 每个窗口 `tabbingMode = .disallowed`。
- `isRestorable = false`，避免重启时按上次状态多开窗口。

## 关窗不退出

关窗口只是把窗口藏起来，内核继续跑：

- `applicationShouldTerminateAfterLastWindowClosed` 返回 `false`
- `WindowKeeper` 拦 `windowShouldClose`，改成 `orderOut`
- 点 Dock 图标、或菜单栏的「显示窗口」把窗口拿回来
- 真正退出用 ⌘Q 或菜单栏「退出 Whaless」，那时才收子进程

`WindowKeeper` 只实现 `windowShouldClose`，其余 delegate 方法通过 `forwardingTarget`
转给 SwiftUI 原来的代理——直接顶掉它的话，窗口一隐藏 SwiftUI 就以为场景结束了，
重新显示时会把整棵视图重建、网页重新加载。

## 隐藏标题栏

`.windowStyle(.hiddenTitleBar)` + `ignoresSafeArea`，再给页面的 `sidebarCol` /
`centerCol` 加 28px 内距：背景覆盖 padding 盒，所以侧栏灰底和主区白底都能铺到红绿灯
那一行，只有内容下移。顶部那 28pt 由一层透明的 `DragStrip` 负责拖动窗口。

内距用 `setTimeout` 而不是 `requestAnimationFrame` 应用——窗口隐藏时 rAF 会被挂起。

## 顶部那一行：按钮和标题谁让谁

原生玻璃按钮浮在网页上（32pt 圆），**web 页面不知道它们存在**。所以页面里凡是贴着顶边
的内容都会钻到按钮底下：折叠侧栏后「插件」这类整页视图的 `H1` 正好在 `y=28`，被按钮
压掉小半行。

桌面端不是这么解的。`packages/client/ui-layout` 里有一整套窗口 chrome 变量：

```css
html[data-platform=darwin]{--dsh-frame-top-clearance:48px}
html[data-platform=darwin]{--dsh-frame-overlay-top:calc(var(--dsh-frame-top-clearance) + 20px)}
[data-platform=darwin] .frame[data-sidebar-collapsed]{--dsh-frame-leading-clearance:160px}
[data-platform=darwin] .pageHeading{padding-top:calc(28px + var(--dsh-frame-top-clearance))}
```

页面各自去读：插件页/自动化任务页的标题吃 `top-clearance`，会话标题行吃
`leading-clearance`（自己再减 20px 当内距），设置遮罩和下拉菜单吃 `overlay-top`。
连原生按钮该待在哪儿也是前端定的——`leadingSeat` 就是 `absolute; top:11px; left:88px`，
和壳里那两个按钮几乎一个像素不差。

问题在于这些规则**全挂在 `[data-platform=darwin]` 下**，而这个属性我们打不了：
前端一看到 darwin 就去等 preload 注入的 `dshDesktopBoot`，等不到整棵树不 mount（白屏，
见上一节的实测）。于是壳自己在注入的样式里把这套等价补回来：

```css
:root{--dsh-frame-top-clearance:48px;--dsh-frame-overlay-top:68px}

/* 整页标题：插件页叫 pageHead，自动化任务页叫 pageHeading，两个都是顶层容器 */
[class*="pageHead"]:not([class*="pageHeading"]),
[class*="pageHeading"]:not([class*="pageHead"] *),
[class*="detailTop"],[class*="moreHead"]{padding-top:calc(28px + var(--dsh-frame-top-clearance))}

/* 折叠态：挂着 frame 自己的 data-sidebar-collapsed 上，和折叠同一帧生效 */
[data-sidebar-collapsed]{--dsh-frame-leading-clearance:180px}
[data-sidebar-collapsed] [class*="centerCol"]{margin-left:-56px}
```

几点值得记下来：

- **`pageHead` 和 `pageHeading` 会互相踩**。插件页的 `pageHeading` 是 `pageHead` 的子元素，
  名字里也含 `pageHead`，早期一条 `[class*="pageHead"]` 同时命中两层，内距叠成 152px，
  标题直接掉到半屏。现在两边各带一个 `:not()` 互斥：父级认 `pageHead`，顶层认
  `pageHeading`，只吃一份 76px。
- **类名按后缀匹配**（`X_2TxG_pageHead` / `t-XoWW_pageHeading`），哈希前缀换了也不影响。
- **折叠状态读 `data-sidebar-collapsed`，不读自己加的类**。之前用 JS 加的 `whaless-rail`
  要等 50ms 防抖 + 宽度阈值，标题会在侧栏快滑完时才补一下，看着就是"闪一下"。
  React 改这个属性和改 grid 列是同一帧，跟它走就永远不会错拍。
- **主栏要往左吃掉那 56px 空轨道**。上游 `collapsedWidth = darwin ? 0 : 56`：桌面端折叠
  时侧栏轨道塌成 0，主栏从窗口左边缘开始画；我们走 web 分支留着图标轨道，主栏就从 56
  开始，标题下的分隔线左边空一截。`margin-left:-56px` 把主栏整体带过去（宽度是 stretch
  自适应，右边缘不动）。
- **「对话 / 轨迹」这行要单独补**。它跟标题行是兄弟节点（`grid-column:1/-1`），上游只给
  `titleRow` 让位，折叠后两行左边缘差 140px。用 `[class*="titleRow"] ~ [class*="tabs"]`
  把同一条 clearance 补给标签行（外加 8px——那是标题 crumb 自己的左右内距）。
- **过渡只挂在 `[data-animating]` 下**。上游用同一个属性给 grid 列开 0.3s 过渡；内距、
  `margin-left` 跟着它走，就不会出现"侧栏在滑、标题已经瞬移"的错拍。

实测数字：插件页 `headPad=76px`（`H1` 顶在 `y=76`）、自动化任务页 `H1` 顶在 `y=78`、
折叠后会话标题文字 `x=188`、标签行 `x=188`、分隔线从 `x=0` 起。

## 按钮跟着分割线走

按钮不是钉死在 `leading: 92` 的：展开时它待在**分割线左侧**（侧栏里面），折叠后才回到
交通灯旁。这需要壳知道侧栏的真实状态，而页面那边从来不会主动告诉原生。

走了一条最小通道：注入脚本监听 `sidebarCol` 的尺寸变化，变了就
`window.webkit.messageHandlers.whaless.postMessage({width, collapsed})`，原生
`WKScriptMessageHandler` 收到后写进 `ShellModel`（`@Published`）。带 `lastSent` 去重，
静止时一条也不发。

位置只认一个数：

```swift
private var leading: CGFloat { max(92, model.sidebarWidth - 40) }   // 按钮 32 + 离线 8
```

- 展开：`侧栏宽 - 40`，按钮右缘离分割线 8px，在侧栏里面；
- 折叠：`max(92, 56 - 40)` = `92`，和上游 `leadingSeat` 同址，落在交通灯右边。

两个坑值得记：

- **DOM 里有多个 `[class*="sidebarCol"]`**（展开列和折叠 rail 各一份，过渡期间两份都在）。
  `querySelector` 取第一个，抓到哪个全看渲染顺序——上报值会在 280/56 之间来回跳，按钮
  跟着乱跑（实测折叠完 10 秒又被"弹"回展开位）。改成**取所有匹配里最宽的那个**，
  隐藏/恢复也对每个节点各做一遍。
- **折叠判定不能看宽度阈值**，读 React 自己打在自己 frame 上的 `[data-sidebar-collapsed]`：
  宽度在折叠瞬间是 280 → 56 一步到位（没有中间值），而属性在折叠那一帧就上来了。
  只在首帧属性还没上时用 `< 200` 兜底。

因为宽度不是流式的，位置补间得自己做：翻转那一刻把两个状态一起塞进
`withAnimation(.easeInOut(0.3))`，和 web 端 grid 列的过渡同时长。实测折叠动画中间帧：
按钮 `240 → 226 → 140 → 92`，加号跟着这趟行程淡入，不是在终点原地弹出。

加号（新会话）只在折叠后出现——展开时侧栏自己有「新会话」，折叠后整列消失才需要这个
原生入口。这里有个坑：**`.opacity(0)` 藏不住玻璃**。玻璃是 `GlassEffectContainer`
统一渲染的，`opacity` 只作用到按钮内容，那个圆还留在原地。必须用 `if` 条件渲染 +
`.transition`。

启动时按钮要等页面渲染出来才显示：首次上报之前 `webContentReady` 还是 false，
整套 `GlassEffectContainer` 不进场——否则页面还在白屏/启动页，顶上先飘两个玻璃圆。

## 折叠后左栏里那个孤零零的加号

折叠时整列 `visibility: hidden`，本来应该什么都不剩。但有例外：工作区栏折叠成 rail 后，
`.sectionHeader` 里的「添加工作区」按钮（`<div class=root rail>` 撑满列高、内容垂直居中）
落在 `y≈356/714` 的正中间，而它自己那条链上有 `visibility: visible`，把父级抢回来的
可见性又抢回去了——于是左栏中间飘一个文件夹加号。

只压 `visibility` 治不住这种「自己声明可见」的元素，所以折叠时叠三层：

```
visibility: hidden + opacity: 0 + pointer-events: none
```

`opacity` 在父级形成合成层，子元素再怎么声明也回不来。实测折叠后左栏带
（`x < 70`）只剩 `html` / `frame` / `centerCol` 三个整块元素，不再有按钮。

## 侧栏开关是原生的

标题栏左侧那个图标（交通灯右边）是 SwiftUI 里挂的一个 `NSButton`，**web 端自己的折叠
按钮被 CSS 隐藏**（`visibility:hidden`，不是 `display:none`，否则 JS `.click()` 之外
还得自己复制状态机）。

```
点原生按钮 → evaluateJavaScript：side.querySelector('[class*="toggle"]').click()
           → 应用自己走它的状态机 → 主栏宽度由它重算 → 壳只负责"窄栏别露出来"
```

实测：

```
展开 side=280 center=790 rail=0   toggleVis=hidden
点击 side=56  center=1014 rail=1   ← 窄栏透明、主栏顶到左边
再点 side=280 center=790 rail=0
```

为什么不在壳里直接改宽度：主栏宽度是应用按"侧栏占多少"算的（父容器 grid 列），
壳改宽度它不知道，实测会切成上下堆叠（`side[0,0,1070,562]`）。

兜底入口：菜单「显示 → 切换侧边栏」（⌃⌘S）。按钮万一被挡住还能用键盘切。

> 用 `NSButton` 而不是 SwiftUI `Button`：这台机器上 SwiftUI 的宏插件是坏的
> （`@State` 展开报 `swift-plugin-server produced malformed response`），
> 顺手也拿到了原生 hover 高亮。

## 官方桌面端是怎么做的（拆 app.asar 看到的）

放 here 是为了记住"为什么不能照抄"。

**窗口**（`lib/main.js` 的 `createWindow`）：

```js
process.platform === "darwin" ? {
  titleBarStyle: "hiddenInset",
  trafficLightPosition: { x: 16, y: 18 },   // 交通灯位置是原生参数，不是 CSS
  vibrancy: "sidebar",                       // 侧栏毛玻璃
  visualEffectState: "active",
  backgroundColor: "#00000000"
} : {
  titleBarStyle: "hidden",
  titleBarOverlay: { height: 40, ... }       // Windows 用 overlay 高度 + CSS 变量
}
```

**preload 只做两件事**（`lib/preload-app.cjs`）：

```js
document.documentElement.dataset.platform = process.platform;   // darwin
// 全屏时 data-fullscreen，CSS 据此去掉顶部留白
```

前端 CSS 里 `html[data-platform=darwin]` 的规则就是透明背景 + `-webkit-app-region: drag`
的拖拽区（`[data-window-drag]`），**没有任何给交通灯让位的 padding**。

**所以他们的 "按钮和交通灯齐平 / 侧栏整体隐藏" 不是 CSS 技巧**，而是渲染器跑在桌面宿主模式：
preload 注入 `globalThis.dshDesktopBoot`，前端据此渲染自己的窗口 chrome（tab strip 那一行）。
我们试过只给 `dsh web` 的页面打 `data-platform=darwin`——结果是**白屏**：

```
rootChildren=0  htmlLen=42271  bg=rgba(0,0,0,0)  errs=none
```

因为缺 `dshDesktopBoot`，前端根本不 mount。这条路对 WKWebView 壳走不通。

**结论**：壳只能在 web 模式的基础上做等价的事——
交通灯用原生 frame 偏移（`+8/-6`），折叠按钮用 `translateY` 对齐到同一水平线，
隐藏侧栏用"窄条透明化 + 按钮浮到 left:84"。

试过更彻底的做法（把 grid 列宽改成 `0px 1fr 0px`，实测 `center=1070` 满宽），
但应用会按 DOM 宽度自适应，随即把两栏改成上下堆叠（`side[0,0,1070,562]`），
所以放弃了——**56px 占位是稳的，满宽是不稳的**。

## 已知限制

- **没有通知**。WKWebView 不暴露 `Notification` API（Apple DTS 明确说 Web Push 在
  WKWebView 里不可用），`turn-notify` 这类插件在这里会静默失效。想要通知得自己加一座
  `WKScriptMessageHandler` → `UNUserNotificationCenter` 的桥，或者就用手机端的 APNs。
- **会话写锁**。壳自己起一个 harness，和桌面端共用 `$DSH_HOME`。同时打开时别两边
  都发起长任务。
- **每次启动是新进程**，端口也变。这是 `--port 0` 的代价，换来的是永不冲突。
- **隐藏标题栏依赖类名后缀**（`sidebarCol` / `centerCol` / `pageHead`）。前端哪天改了名字，
  内距会退回加到 `#root` 上——不会压住红绿灯，但顶部会露出 body 底色，页面标题也会
  重新钻到按钮底下。日志里 `pad(col)=no-col`、`headPad=28px` 就是信号。

## 孤儿进程

`kill -9` 应用时子进程会被过继给 launchd 继续跑，下次启动就多一个监听端口。所以：

- 正常退出（⌘Q / 关窗）：`applicationWillTerminate` → `terminate()` → 3 秒后 `SIGKILL`；
- 崩溃 / 强杀：pid 记在 `~/Library/Application Support/Whaless/child.pid`，
  下次启动 `reapPreviousChild()` 按进程名核对（`DeepSeek`/`dsh`/`node`）后回收，
  避免 pid 复用误伤。

## 日志

调试白屏先看这里，两行就能分清"没加载"和"加载了但渲染空"：

```
~/Library/Logs/Whaless/shell.log   # load / didFinish / rendered(+0s/+6s) / 内核检查
~/Library/Logs/Whaless/dsh.log     # dsh 的原始输出（含带令牌的地址）
```

`rendered` 那行同时是布局体检：

```
side=280 center=853 rail=0 pad=50px quietTop=56/60 headPad=76px
```

`pad` 是侧栏内距、`headPad` 是页面标题内距、`rail` 是折叠标记。三个里任何一个
回到默认值（`pad=-` / `headPad=28px` / `rail=0` 却 `side=56`），就是选择器失效了。

## 目录

| 路径 | 内容 |
|---|---|
| `Sources/App.swift` | `@main`、窗口、菜单（含「内核」）、启动/失败界面 |
| `Sources/ShellModel.swift` | 状态机 + 内核检查/安装/重启 |
| `Sources/ServerRunner.swift` | 进程、令牌解析、内核定位、孤儿回收 |
| `Sources/KernelUpdate.swift` | 版本查询（npm registry）与升级 |
| `Sources/WebPane.swift` | WKWebView 与那堆 delegate |
| `Sources/WindowKeeper.swift` | 关窗保活（转发代理）+ 拿到 NSWindow |
| `Sources/DragStrip.swift` | 隐藏标题栏后那 28pt 的拖动区 |
| `Sources/SidebarToggle.swift` | 原生侧栏开关（NSButton + hover） |
| `Sources/AppPaths.swift` | 日志/支持目录 |
| `Sources/ShellLog.swift` | 壳自己的日志（令牌打码） |
| `Resources/Whaless.icon` | Icon Composer 文档，actool 生成亮/暗全套 |

## 构建

```bash
./scripts/build.sh
```

需要 `xcodegen`（`brew install xcodegen`）。ad-hoc 签名，本机自用足够；分发要换
Developer ID + 公证。
