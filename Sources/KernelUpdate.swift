import Foundation

/// 一次内核检查的结果。
/// 检查/更新阶段的失败原因。
struct UpdateFailure: Error {
    let message: String
}

struct KernelCheck {
    let install: KernelInstall
    let current: String?
    let latest: String?

    /// 只做"不一样"的判断，不假装能正确比较 prerelease 大小。
    var isOutdated: Bool {
        guard let current, let latest else { return false }
        return current != latest
    }
}

/// 查 / 升 npm 上的 `@deepseek-ai/dsh`。
///
/// 只认 npm 装的那份：壳本来就是 npm 内核的外壳，桌面端内置的那份既不会跟着 npm
/// 走，也不该被这里的按钮改。
enum KernelUpdate {
    static let packageName = "@deepseek-ai/dsh"

    static var registryURL: URL {
        URL(string: "https://registry.npmjs.org/\(packageName)/latest")!
    }

    // MARK: - 检查

    static func check(completion: @escaping (Result<KernelCheck, UpdateFailure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let launch = ServerRunner.resolve() else {
                finish(completion, .failure(UpdateFailure(message: "还没装 npm 版内核。点「安装 npm 版内核」装一个。")))
                return
            }
            let current = version(of: launch)
            guard let latest = latestVersion() else {
                finish(completion, .failure(UpdateFailure(message: "查不到 npm 上的最新版本（网络或 registry 不可达）。")))
                return
            }
            finish(completion, .success(KernelCheck(install: launch.install, current: current, latest: latest)))
        }
    }

    static func currentVersion() -> String? {
        ServerRunner.resolve().flatMap { version(of: $0) }
    }

    private static func finish(_ completion: @escaping (Result<KernelCheck, UpdateFailure>) -> Void,
                               _ result: Result<KernelCheck, UpdateFailure>) {
        DispatchQueue.main.async { completion(result) }
    }

    // MARK: - 升级 / 安装

    /// 没装内核时也走这条：`npm install -g @…@latest`。
    static func installLatest(completion: @escaping (Result<String, UpdateFailure>) -> Void) {
        guard let npm = npmPath() else {
            DispatchQueue.main.async { completion(.failure(UpdateFailure(message: "没找到 npm。先装 Node.js（brew install node）。"))) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(URL(fileURLWithPath: npm),
                             ["install", "-g", "\(packageName)@latest"],
                             timeout: 300)
            guard let result else {
                DispatchQueue.main.async { completion(.failure(UpdateFailure(message: "npm 没能启动。"))) }
                return
            }
            guard result.status == 0 else {
                let tail = String(result.output.suffix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async { completion(.failure(UpdateFailure(message: "更新失败（exit \(result.status)）：\n\(tail)"))) }
                return
            }
            let newVersion = currentVersion()
            DispatchQueue.main.async { completion(.success(newVersion ?? "未知")) }
        }
    }

    // MARK: - 小工具

    static func version(of launch: Launch) -> String? {
        guard let result = run(launch.executable, launch.versionArguments, timeout: 20) else { return nil }
        return firstVersion(in: result.output)
    }

    private static func latestVersion() -> String? {
        var request = URLRequest(url: registryURL)
        request.timeoutInterval = 12
        let semaphore = DispatchSemaphore(value: 0)
        var version: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                version = json["version"] as? String
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 15)
        return version
    }

    static func firstVersion(in text: String) -> String? {
        let pattern = #"\d+\.\d+\.\d+(?:-[0-9A-Za-z.\-]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    private static func npmPath() -> String? {
        ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", "/usr/bin/npm"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ServerRunner.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // 必须并发读：输出超过管道缓冲时子进程会阻塞在写上面，等退出就死锁了。
        var collected = Data()
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collected = pipe.fileHandleForReading.readDataToEndOfFile()
            readerDone.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        _ = readerDone.wait(timeout: .now() + 10)
        return (process.terminationStatus, String(data: collected, encoding: .utf8) ?? "")
    }
}
