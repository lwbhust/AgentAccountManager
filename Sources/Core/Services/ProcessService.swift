import Foundation

/// 封装 Process，用于执行经过验证的官方 CLI 命令。
public struct ProcessService: Sendable {
    public init() {}

    /// 同步执行命令并返回退出码与输出。
    /// - Parameters:
    ///   - launchPath: 可执行文件路径
    ///   - arguments: 参数列表
    ///   - timeout: 超时秒数；超时会终止进程，并在 stderr 中说明原因
    /// - Returns: (exitCode, stdout, stderr)；-1 表示启动失败，-2 表示超时被终止
    @discardableResult
    public func run(
        launchPath: String,
        arguments: [String] = [],
        timeout: TimeInterval? = nil
    ) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        // 先并发读空管道，再等待进程退出。单线程先 wait 后 read 时，
        // 输出超过管道缓冲区（64KB）会互相等待，导致调用方永久阻塞。
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let output = ProcessOutput()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            output.setStdout(stdoutHandle.readDataToEndOfFile())
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            output.setStderr(stderrHandle.readDataToEndOfFile())
            readGroup.leave()
        }

        let lock = NSLock()
        var timedOut = false
        var timeoutWork: DispatchWorkItem?
        if let timeout {
            let work = DispatchWorkItem {
                lock.lock()
                defer { lock.unlock() }
                guard process.isRunning else { return }
                timedOut = true
                process.terminate()
            }
            timeoutWork = work
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + timeout, execute: work)
        }

        process.waitUntilExit()
        timeoutWork?.cancel()

        // 子进程可能仍持有管道写端（例如 shell 管道里的下游命令），
        // 这里只做有限等待，避免调用方被无限拖住。
        _ = readGroup.wait(timeout: .now() + 1)

        let stdout = output.stdout
        let stderr = output.stderr

        lock.lock()
        let wasTimedOut = timedOut
        lock.unlock()

        if wasTimedOut {
            let seconds = Int(timeout ?? 0)
            let reason = "命令执行超过 \(seconds) 秒，已终止"
            return (-2, stdout, stderr.isEmpty ? reason : stderr + "\n" + reason)
        }
        return (process.terminationStatus, stdout, stderr)
    }

    /// 异步启动进程（不等待退出），用于启动 GUI 应用实例。
    public func launch(launchPath: String, arguments: [String] = []) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        try process.run()
    }
}

/// 并发读取 stdout/stderr 时使用的线程安全缓冲。
private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    func setStdout(_ data: Data) {
        lock.lock()
        stdoutData = data
        lock.unlock()
    }

    func setStderr(_ data: Data) {
        lock.lock()
        stderrData = data
        lock.unlock()
    }

    var stdout: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    var stderr: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stderrData, encoding: .utf8) ?? ""
    }
}
