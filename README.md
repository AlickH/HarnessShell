# Harness Shell

给 DeepSeek Harness 的 web UI 套一个原生 macOS 窗口：双击就开，关掉就退，不占终端。

```
┌──────────────────────────────┐
│  Harness Shell.app (SwiftUI) │
│   ├─ WKWebView ──────────────┼──▶ http://127.0.0.1:<port>/?token=…
│   └─ Process ────────────────┼──▶ dsh web --no-open --port 0
└──────────────────────────────┘
```

约 600 行 Swift，不做前端、不改内核。它和 `Whaless`（iOS 客户端）没有任何共享代码：
那个接的是自定义桥协议，这个只是把内核自己渲染好的页面装进一个窗口。

## 为什么不是"探测 3080 就直接打开"

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

## 跑起来

```bash
./scripts/build.sh          # xcodegen → xcodebuild → open
```

需要 `xcodegen`（`brew install xcodegen`）。ad-hoc 签名，本机自用足够；分发要换 Developer ID + 公证。

启动时会按顺序找一个能用的 `dsh`：

1. `/opt/homebrew/bin/dsh`
2. `/usr/local/bin/dsh`
3. `~/.local/bin/dsh`
4. 桌面端自带的 CLI（`/Applications/DeepSeek Harness.app/.../cli/bin/dsh`）
5. npx 缓存里的 `@deepseek-ai/dsh/lib/bin.js` + Homebrew 的 node

都找不到就显示一段说明，不会白屏。

## 补了哪些浏览器默认能力

WKWebView 只是个渲染引擎，"点了没反应"的那些默认缺口按实测补了这几个（依据是前端
bundle 里真实用到的 API，不是通用清单）：

| 能力 | 实现 |
|---|---|
| `<input type=file>` 上传 | `runOpenPanelWith` → `NSOpenPanel` |
| 下载（`download` 属性） | `WKDownloadDelegate` → `NSSavePanel` |
| 外链 / `window.open` | `NSWorkspace.shared.open`，不在壳里劫持 |
| `beforeunload` 确认 | `runBeforeUnloadConfirmPanel` |
| JS `alert/confirm/prompt` | 三个 `WKUIDelegate` 方法 |
| ⌘R / ⌘± / ⌘0 | SwiftUI `.commands` |

拖拽上传、剪贴板不需要额外代码（HTML5 事件和 `navigator.clipboard` 在 WKWebView 里原生可用）。

## 已知限制

- **没有通知**。WKWebView 不暴露 `Notification` API（Apple DTS 明确说 Web Push 在
  WKWebView 里不可用），所以 `turn-notify` 这类插件在这里会静默失效。想要通知得自己
  加一座 `WKScriptMessageHandler` → `UNUserNotificationCenter` 的桥，或者就用手机端的 APNs。
- **会话写锁**。壳自己起一个 harness，和桌面端共用 `$DSH_HOME`。同时打开时不要两边
  都发起长任务，会撞锁。
- **每次启动是新进程**，端口也变。这是 `--port 0` 的代价，换来的是永不冲突。

## 孤儿进程

`kill -9` 应用时子进程会被过继给 launchd 继续跑，下次启动就多一个监听端口。所以：

- 正常退出（⌘Q / 关窗）：`applicationWillTerminate` → `terminate()` → 3 秒后 `SIGKILL`；
- 崩溃 / 强杀：pid 记在 `~/Library/Application Support/HarnessShell/child.pid`，
  下次启动 `reapPreviousChild()` 按进程名核对（`DeepSeek`/`dsh`/`node`）后回收，
  避免 pid 复用误伤。

## 日志

调试白屏先看这里，两行就能分清"没加载"和"加载了但渲染空"：

```
~/Library/Logs/HarnessShell/shell.log   # load / didFinish / rendered(+0s/+6s)
~/Library/Logs/HarnessShell/dsh.log     # dsh web 的原始输出（含带令牌的地址）
```

## 目录

| 路径 | 内容 |
|---|---|
| `Sources/App.swift` | `@main`、窗口、菜单命令、启动/失败界面 |
| `Sources/ShellModel.swift` | 状态机：`starting(…)` → `ready(url)` / `failed(…)` |
| `Sources/ServerRunner.swift` | 进程、令牌解析、孤儿回收、日志 |
| `Sources/WebPane.swift` | WKWebView 与那堆 delegate |
| `Sources/ShellLog.swift` | 壳自己的日志（令牌打码） |
