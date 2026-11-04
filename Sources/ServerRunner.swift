import Foundation

/// 启动阶段的失败原因。用独立类型而不是 String：`Result` 的失败值必须是 `Error`。
struct LaunchFailure: Error {
    let message: String
}

/// 定位并托管 `dsh web` 子进程。
///
/// 关键事实：这一版 `dsh web` 有浏览器认证——直接开 `http://127.0.0.1:3080/`
/// 会拿到 401，只有它自己打印的 `http://127.0.0.1:<port>/?token=…` 才能进。
/// 所以壳必须**自己启动进程**，从 stdout 里抓那行地址；借用一个别人起的实例是没用的
/// （拿不到它的令牌）。
///
/// 由此推出三件事：
/// 1. `--port 0` 让系统分配端口，省掉端口冲突；
/// 2. stdout 必须实时读，不能只重定向到文件（否则拿不到令牌）；
/// 3. 进程死了要么重启，要么把原因写进日志，绝不静默失败。
/// 内核是从哪儿来的——决定了"检查更新"能做什么。
enum KernelInstall {
    /// `npm i -g` 装的，直接 `npm install -g @…@latest` 就能升。
    case npmGlobal(String)
    /// 只跑过 npx，内核躺在缓存里。
    case npxCache(node: String, cli: String)

    var label: String {
        switch self {
        case .npmGlobal: return "npm 全局安装"
        case .npxCache: return "npx 缓存"
        }
    }

    var supportsUpgrade: Bool {
        if case .npmGlobal = self { return true }
        return false
    }

    var hint: String {
        switch self {
        case .npmGlobal(let path):
            return path
        case .npxCache:
            return "当前用的是 npx 缓存，重启会拿最新版；也可以改用 npm 全局安装。"
        }
    }
}

/// 一个可启动的内核入口。`prefix` 是给 node 用的（`node <bin.js> …`）。
struct Launch {
    let executable: URL
    let prefix: [String]
    let install: KernelInstall

    func webArguments(port: String) -> [String] {
        prefix + ["web", "--no-open", "--port", port]
    }

    var versionArguments: [String] {
        prefix + ["-V"]
    }
}

final class ServerRunner {
    private var process: Process?
    private var pipe: Pipe?
    private var logHandle: FileHandle?
    private var buffer = ""
    private var stopping = false
    private var restarts = 0

    private var onReady: ((URL) -> Void)?
    private var onFailure: ((LaunchFailure) -> Void)?
    private var settled = false
    private let lock = NSLock()

    // MARK: - 启动

    func start(completion: @escaping (Result<URL, LaunchFailure>) -> Void) {
        stopping = false
        restarts = 0
        settled = false
        onReady = { url in
            DispatchQueue.main.async { completion(.success(url)) }
        }
        onFailure = { failure in
            DispatchQueue.main.async { completion(.failure(failure)) }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            ServerRunner.reapPreviousChild()
            guard let launch = ServerRunner.resolve() else {
                self.fail("""
                    没有找到 npm 版内核（dsh）。

                    点下面的「安装 npm 版内核」自动装，也可以自己在终端执行：
                    npm i -g @deepseek-ai/dsh
                    """)
                return
            }
            ShellLog.write("内核: \(launch.executable.path)（\(launch.install.label)）")
            do {
                try self.spawn(launch)
            } catch {
                self.fail("启动 dsh 失败：\(error.localizedDescription)")
                return
            }
            // 地址由 stdout 决定；这里只是兜底超时。
            DispatchQueue.global().asyncAfter(deadline: .now() + 40) { [weak self] in
                guard let self, !self.isSettled else { return }
                self.fail("dsh web 启动超时（没在输出里看到带令牌的地址）。日志：\(ServerRunner.logURL.path)")
            }
        }
    }

    func stop() {
        stopping = true
        pipe?.fileHandleForReading.readabilityHandler = nil
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        ServerRunner.clearPidFile()
        try? logHandle?.close()
    }

    // MARK: - 进程与输出

    /// 固定端口：端口不变 → origin 不变 → WKWebView 的 HTTP 缓存能命中，
    /// 第二次启动页面加载从 ~1.9s 降到零点几秒。端口被别的进程占用时，
    /// 重启路径会自动退回 `--port 0` 让系统分配。
    private var portArgument: String {
        if fallbackToRandomPort { return "0" }
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: "kernelPort") == 0 {
            defaults.set(47810, forKey: "kernelPort")
        }
        return String(defaults.integer(forKey: "kernelPort"))
    }

    /// 首次启动失败（端口被占）后改用随机端口。
    private var fallbackToRandomPort = false

    private func spawn(_ launch: Launch) throws {
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.webArguments(port: self.portArgument)
        process.environment = ServerRunner.environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let handle = try ServerRunner.openLog()
        self.logHandle = handle

        pipe.fileHandleForReading.readabilityHandler = { [weak self] source in
            let data = source.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.consume(text)
        }

        process.terminationHandler = { [weak self] finished in
            guard let self, !self.stopping else { return }
            self.pipe?.fileHandleForReading.readabilityHandler = nil
            guard !self.isSettled else { return }      // 已经在跑的实例退出：交给上层重连
            guard self.restarts < 2 else {
                self.fail("dsh 反复退出（退出码 \(finished.terminationStatus)）。日志：\(ServerRunner.logURL.path)")
                return
            }
            self.restarts += 1
            // 第一次重启大概率是固定端口被占：退回随机端口，别再撞同一个。
            self.fallbackToRandomPort = true
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                try? self.spawn(launch)
            }
        }

        try process.run()
        self.process = process
        self.pipe = pipe
        ServerRunner.writePidFile(process.processIdentifier)
    }

    /// 按行切分输出：写进日志，同时找那行带令牌的地址。
    private func consume(_ chunk: String) {
        lock.lock()
        buffer += chunk
        var lines: [String] = []
        while let index = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[buffer.startIndex..<index]))
            buffer = String(buffer[buffer.index(after: index)...])
        }
        lock.unlock()

        for line in lines {
            if let data = (line + "\n").data(using: .utf8) {
                try? logHandle?.write(contentsOf: data)
            }
            if !isSettled, let url = ServerRunner.tokenURL(in: line) {
                settle(url)
            }
        }
    }

    private static func tokenURL(in line: String) -> URL? {
        guard let range = line.range(of: "http://127.0.0.1:", options: .literal) else { return nil }
        let tail = line[range.lowerBound...]
        // 地址通常在一行末尾，没有终止空格，所以缺省取到行尾。
        let end = tail.firstIndex(where: { $0 == " " || $0 == "\u{1B}" }) ?? tail.endIndex
        let candidate = String(tail[tail.startIndex..<end])
        guard candidate.contains("token="), let url = URL(string: candidate) else { return nil }
        return url
    }

    private var isSettled: Bool {
        lock.lock(); defer { lock.unlock() }
        return settled
    }

    private func settle(_ url: URL) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        lock.unlock()
        restarts = 0
        onReady?(url)
    }

    private func fail(_ message: String) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        lock.unlock()
        onFailure?(LaunchFailure(message: message))
    }

    // MARK: - 定位

    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        // GUI 应用的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，homebrew 的 node 会找不到。
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        return env
    }()

    static func resolve() -> Launch? {
        // 只要 npm 装的那份。注意 `/usr/local/bin/dsh` 可能是桌面 App 的软链，
        // 那种要按真实路径排除掉——它不是 npm 内核，也不会跟着 npm 更新。
        let named = ["/opt/homebrew/bin/dsh", "/usr/local/bin/dsh", "\(NSHomeDirectory())/.local/bin/dsh"]
        for path in named where isExecutable(path) {
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if real.contains("DeepSeek Harness.app") {
                ShellLog.write("跳过 \(path)：指向桌面端内置内核（\(real)）")
                continue
            }
            return Launch(executable: URL(fileURLWithPath: path), prefix: [], install: .npmGlobal(real))
        }

        // 只跑过 npx 的机器：缓存里有一份 kernel，但需要自己找 node。
        if let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first(where: isExecutable),
           let cli = newestNpxCLI() {
            return Launch(executable: URL(fileURLWithPath: node), prefix: [cli], install: .npxCache(node: node, cli: cli))
        }
        return nil
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private static func newestNpxCLI() -> String? {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".npm/_npx")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        var best: (String, Date)?
        for dir in dirs {
            let cli = dir.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js").path
            guard FileManager.default.fileExists(atPath: cli) else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: cli)
            let date = (attributes?[.modificationDate] as? Date) ?? .distantPast
            if best == nil || date > best!.1 { best = (cli, date) }
        }
        return best?.0
    }

    // MARK: - 孤儿进程

    /// 强杀/崩溃时子进程会被过继给 launchd 继续跑，下次启动就多一个监听端口。
    /// 记下 pid，下次启动只杀"确实是我们起的那个"（按进程名核对，避免 pid 复用误伤）。
    private static var pidFileURL: URL {
        AppPaths.supportDir.appendingPathComponent("child.pid")
    }

    private static func writePidFile(_ pid: Int32) {
        try? String(pid).write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    static func clearPidFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    static func reapPreviousChild() {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else {
            clearPidFile()
            return
        }
        defer { clearPidFile() }
        guard kill(pid, 0) == 0 else { return }           // 已经没了
        guard let name = processName(pid: pid), name.hasPrefix("DeepSeek") || name.hasPrefix("dsh") || name.hasPrefix("node") else {
            ShellLog.write("跳过回收 pid \(pid)：进程名不是 dsh")
            return
        }
        kill(pid, SIGTERM)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        ShellLog.write("回收上次遗留的子进程 pid \(pid)")
    }

    private static func processName(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: CChar.self, capacity: size) { raw in
                sysctl(&mib, 4, raw, &size, nil, 0)
            }
        }
        guard result == 0 else { return nil }
        return withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return nil }
            return String(cString: base)
        }
    }

    // MARK: - 日志

    static var logURL: URL {
        AppPaths.logsDir.appendingPathComponent("dsh.log")
    }

    private static func openLog() throws -> FileHandle {
        let url = logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        // 超过 4MB 就清空，避免日志无限长。
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        if size > 4 * 1024 * 1024 {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        return handle
    }
}
