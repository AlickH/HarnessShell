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
- **隐藏标题栏依赖类名后缀**（`sidebarCol` / `centerCol`）。前端哪天改了名字，内距会
  退回加到 `#root` 上——不会压住红绿灯，但顶部会露出 body 底色。日志里
  `pad(col)=no-col` 就是信号。

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
| `Sources/AppPaths.swift` | 日志/支持目录 |
| `Sources/ShellLog.swift` | 壳自己的日志（令牌打码） |
| `Resources/Whaless.icon` | Icon Composer 文档，actool 生成亮/暗全套 |

## 构建

```bash
./scripts/build.sh
```

需要 `xcodegen`（`brew install xcodegen`）。ad-hoc 签名，本机自用足够；分发要换
Developer ID + 公证。
