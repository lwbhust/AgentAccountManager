import Foundation
import AppKit
import CoreGraphics

/// TRAE 官方能力封装。
///
/// 阶段 A 结论：TRAE 桌面端 CLI（trae-cn）官方支持 `--user-data-dir`，
/// 可启动独立实例实现账号隔离（VERIFIED，继承自 VS Code）。
/// 每个账号分配独立的 user-data-dir，首次登录后持久化会话。
public struct TraeService: Sendable {
    public let cliPath: String
    public let appBundlePath: String
    private let process = ProcessService()

    /// - Parameters:
    ///   - cliPath: 显式指定内置命令行路径；nil 时按实际安装位置推导。
    ///   - appBundlePath: 显式指定应用包路径；nil 时自动查找（/Applications 优先）。
    public init(cliPath: String? = nil, appBundlePath: String? = nil) {
        let bundle = appBundlePath
            ?? Platform.trae.installedApplicationURL?.path
            ?? Platform.trae.applicationURL.path
        self.appBundlePath = bundle
        self.cliPath = cliPath
            ?? bundle + "/Contents/Resources/app/bin/trae-cn"
    }

    /// 本机是否已安装 TRAE CN（以内置命令行是否可执行为准）。
    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: cliPath)
    }

    /// 官方应用包能否在本机解析到（用于区分「应用未安装」与「CLI 不可用」）。
    public var isApplicationBundleResolvable: Bool {
        Platform.trae.installedApplicationURL != nil
    }

    // MARK: - user-data-dir 管理

    /// 所有 TRAE 账号隔离目录的根目录。
    public var traeDataRoot: URL {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (appSupport ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("AgentAccountManager", isDirectory: true)
            .appendingPathComponent("TraeUserData", isDirectory: true)
    }

    /// 获取某账号的 user-data-dir 路径（不存在则创建）。
    public func userDataDir(for accountId: UUID) throws -> URL {
        let dir = traeDataRoot.appendingPathComponent(accountId.uuidString, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 某账号的隔离目录是否存在（不创建目录）。
    public func hasUserDataDir(for accountId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: dataDirPath(for: accountId).path)
    }

    /// 某账号的隔离目录路径（不创建目录）。
    public func dataDirPath(for accountId: UUID) -> URL {
        traeDataRoot.appendingPathComponent(accountId.uuidString, isDirectory: true)
    }

    /// 删除某账号的隔离目录（删除账号时清理本应用创建的数据）。
    public func removeUserDataDir(for accountId: UUID) {
        let dir = dataDirPath(for: accountId)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// 判断账号是否已有持久化的会话数据（隔离目录存在且非空）。
    ///
    /// TRAE 首次启动会向 user-data-dir 写入配置与登录态；
    /// 目录非空说明该账号至少完成过一次启动，会话可能已持久化。
    /// 注意：仅作会话推断的辅助信号，不构成身份核验。
    public func hasPersistedSession(accountId: UUID) -> Bool {
        let dir = traeDataRoot.appendingPathComponent(accountId.uuidString, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return !contents.isEmpty
    }

    // MARK: - 上次打开的项目

    /// 读取该账号隔离配置里记录的上次打开的工作区。
    ///
    /// TRAE（VS Code 内核）会把最近窗口状态写在隔离目录自己的
    /// `User/globalStorage/storage.json` 的 `windowsState` 里。这里只读本应用
    /// 自己创建的目录、只取工作区路径，不读取任何认证数据。
    /// - Returns: 仍然存在的工作区路径；没有记录或路径已失效时返回 nil。
    public func lastWorkspace(for accountId: UUID) -> URL? {
        let storageURL = dataDirPath(for: accountId)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("storage.json")

        guard let data = try? Data(contentsOf: storageURL),
              let state = try? JSONDecoder().decode(StoredUIState.self, from: data) else {
            return nil
        }

        var candidates: [String] = []
        if let window = state.windowsState?.lastActiveWindow {
            candidates.append(contentsOf: [window.folder, window.workspace].compactMap { $0 })
        }
        for window in (state.windowsState?.openedWindows ?? []).reversed() {
            candidates.append(contentsOf: [window.folder, window.workspace].compactMap { $0 })
        }
        if let workspaces = state.profileAssociations?.workspaces {
            candidates.append(contentsOf: workspaces.keys)
        }

        for candidate in candidates {
            guard let url = URL(string: candidate), url.isFileURL else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            return url
        }
        return nil
    }

    /// `storage.json` 中与窗口恢复相关的字段。
    private struct StoredUIState: Decodable {
        struct Window: Decodable {
            let folder: String?
            let workspace: String?
        }
        struct WindowsState: Decodable {
            let lastActiveWindow: Window?
            let openedWindows: [Window]?
        }
        struct ProfileAssociations: Decodable {
            let workspaces: [String: String]?
        }
        let windowsState: WindowsState?
        let profileAssociations: ProfileAssociations?
    }

    /// 读取该账号隔离实例当前打开的所有工作区（最近活跃的排在最前）。
    ///
    /// 优先读 `globalStorage/storage.json` 的 `windowsState`：`lastActiveWindow`
    /// 是最近活跃的窗口，`openedWindows` 是当前打开的所有窗口，这是 VS Code
    /// 内核实时维护的窗口列表。缺少该记录时回退到 `workspaceStorage` 的最新一条。
    /// 只读本应用创建的目录，不读取任何认证数据。
    public func openWorkspaces(for accountId: UUID) -> [URL] {
        let storageURL = dataDirPath(for: accountId)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("storage.json")

        if let data = try? Data(contentsOf: storageURL),
           let state = try? JSONDecoder().decode(StoredUIState.self, from: data) {
            var ordered: [String] = []
            if let window = state.windowsState?.lastActiveWindow {
                ordered.append(contentsOf: [window.folder, window.workspace].compactMap { $0 })
            }
            for window in state.windowsState?.openedWindows ?? [] {
                ordered.append(contentsOf: [window.folder, window.workspace].compactMap { $0 })
            }
            let urls = Self.uniqueExistingFileURLs(ordered)
            if !urls.isEmpty { return urls }
        }

        return currentWorkspace(for: accountId).map { [$0] } ?? []
    }

    /// 去重并保留仍然存在的目录，顺序保持不变。
    static func uniqueExistingFileURLs(_ candidates: [String]) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for candidate in candidates {
            guard let url = URL(string: candidate), url.isFileURL else { continue }
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted,
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            urls.append(url)
        }
        return urls
    }

    /// 某个工作区在本账号隔离目录里的最近活动时间。
    public struct WorkspaceActivity: Sendable {
        public let url: URL
        /// `workspace.json` 的最后修改时间（近似"最近使用"）
        public let modifiedAt: Date

        public init(url: URL, modifiedAt: Date) {
            self.url = url
            self.modifiedAt = modifiedAt
        }
    }

    /// 列出该账号隔离目录里所有仍然存在的项目及其最近活动时间。
    ///
    /// VS Code 内核会为每个打开过的工作区在
    /// `User/workspaceStorage/<hash>/workspace.json` 写一条记录，
    /// 文件修改时间即该项目最近一次活动时间。只读本应用创建的目录，
    /// 不读取任何认证数据。
    public func workspaceActivity(for accountId: UUID) -> [WorkspaceActivity] {
        let storageRoot = dataDirPath(for: accountId)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("workspaceStorage", isDirectory: true)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: storageRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { entry in
            let file = entry.appendingPathComponent("workspace.json")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attrs[.modificationDate] as? Date,
                  let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(StoredWorkspace.self, from: data),
                  let folder = record.folder,
                  let url = URL(string: folder),
                  url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return WorkspaceActivity(url: url, modifiedAt: modified)
        }
    }

    /// 该账号隔离实例最近活动过的单个工作区。
    public func currentWorkspace(for accountId: UUID) -> URL? {
        workspaceActivity(for: accountId).max { $0.modifiedAt < $1.modifiedAt }?.url
    }

    private struct StoredWorkspace: Decodable {
        let folder: String?
    }

    // MARK: - 启动

    /// 以指定账号的隔离实例启动 TRAE。
    /// - Parameters:
    ///   - account: 目标账号
    ///   - workspace: 可选的工作区路径；传入后 TRAE 会直接打开该文件夹，
    ///     而不是停在空白欢迎页，从而延续上次的项目。
    /// - Returns: 启动是否成功
    @discardableResult
    public func launchIsolated(account: Account, workspace: URL? = nil) throws -> Bool {
        guard account.platform == .trae else { return false }
        let dir = try userDataDir(for: account.id)
        var arguments = ["--user-data-dir", dir.path]
        if let workspace {
            arguments.append(workspace.path)
        }
        try process.launch(launchPath: cliPath, arguments: arguments)
        return true
    }

    /// 检查 TRAE 是否正在运行。
    public func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Platform.trae.bundleIdentifier
        }
    }

    // MARK: - 按账号区分运行状态

    /// 当前正在运行的本应用隔离实例（账号 ID → 主进程 PID）。
    ///
    /// TRAE 每个账号用 `--user-data-dir <该账号目录>` 启动独立实例，
    /// 因此命令行参数是「这个进程属于哪个账号」的唯一可靠证据。
    ///
    /// 不使用 `NSWorkspace.shared.runningApplications` 过滤 bundle ID，
    /// 因为实测 TRAE 主进程（可执行文件名是 Electron）在 NSWorkspace 枚举中
    /// 的 bundleIdentifier 不出现，会直接漏掉主进程。改走 shell 管道
    /// `ps -axo | grep <隔离目录根>`——让 shell 先过滤，Swift 层只接收
    /// 几条匹配的进程行，既不会漏也不会在主线程卡。
    public func runningIsolatedProcesses() -> [UUID: pid_t] {
        let rootPath = traeDataRoot.standardizedFileURL.path
        // shell 单引号包裹 + 转义路径中可能存在的单引号
        let escaped = rootPath.replacingOccurrences(of: "'", with: "'\\''")
        let shCmd = "ps -axo pid=,args= | grep -F '\(escaped)'"

        let (code, stdout, _) = process.run(
            launchPath: "/bin/sh",
            arguments: ["-c", shCmd],
            timeout: 3
        )
        guard code == 0 else { return [:] }
        return Self.parseIsolatedProcesses(
            fromProcessList: stdout,
            root: rootPath
        )
    }

    /// 当前正在运行的 TRAE 独立实例对应的账号 ID 集合。
    public func runningIsolatedAccountIds() -> Set<UUID> {
        Set(runningIsolatedProcesses().keys)
    }

    /// 把指定账号已在运行的实例带到前台，不再拉起新的 CLI 转发进程。
    ///
    /// 重复执行 `trae-cn --user-data-dir` 会短暂启动一个 Electron 进程，
    /// 该进程把请求转发给主实例后立即退出，在程序坞里表现为「开一个又关掉」。
    /// 已有窗口时直接激活原有实例，避免这次多余的启动。
    ///
    /// - Important: 当调用方指定了 `workspace` 时，本方法始终返回 `false`。
    ///   原因是 `NSRunningApplication.activate(.activateAllWindows)` 只能把
    ///   整个进程的所有窗口带到前台，无法聚焦到某个特定项目窗口；而 VS Code/TRAE
    ///   的 CLI 转发机制（`trae-cn --user-data-dir <dir> <workspace>`）能让内核自己
    ///   把目标项目窗口准确聚焦。牺牲一个短命转发进程换来正确的窗口定位是值得的。
    ///
    /// - Parameters:
    ///   - accountId: 目标账号
    ///   - workspace: 期望切换到的项目；nil 表示只激活实例（会直接激活进程）。
    /// - Returns: 是否已激活；实例未运行、没有可显示的窗口、
    ///   或指定了 workspace（始终返回 false，由调用方走 CLI）时返回 false。
    @discardableResult
    public func activateRunningInstance(for accountId: UUID, workspace: URL? = nil) -> Bool {
        // 指定了 workspace 时必须走 CLI 路径，让 VS Code 内核自己聚焦目标窗口；
        // 仅在"只激活实例、不指定窗口"这个场景下才能用 .activateAllWindows 优化。
        if workspace != nil { return false }

        guard let pid = runningIsolatedProcesses()[accountId],
              Self.hasOpenWindow(pid: pid),
              let app = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        return app.activate(options: [.activateAllWindows])
    }

    /// 该进程是否有可显示的窗口（用于区分「实例在运行」与「窗口已全部关闭」）。
    private static func hasOpenWindow(pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let height = bounds["Height"] as? Double else {
                return false
            }
            // 忽略菜单栏、浮层等高度很小、不属于主窗口的辅助窗口
            return height >= 100
        }
    }

    /// 从进程命令行列表里解析出属于本应用隔离目录的账号 ID。
    ///
    /// 同时兼容 `--user-data-dir <路径>` 与 `--user-data-dir=<路径>` 两种写法；
    /// 只认 `<root>/<UUID>` 形式，默认配置目录（如 `Trae CN`）会被忽略。
    public static func parseIsolatedAccountIds(fromProcessList output: String, root: String) -> Set<UUID> {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var ids: Set<UUID> = []
        for line in output.split(separator: "\n") where line.contains("--user-data-dir") {
            guard let range = line.range(of: prefix) else { continue }
            let rest = line[range.upperBound...]
            let token = rest.prefix { $0 != "/" && $0 != " " && $0 != "\"" }
            if let id = UUID(uuidString: String(token)) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// 从带 PID 的 `ps` 输出里解析出账号 ID 与主进程 PID 的对应关系。
    public static func parseIsolatedProcesses(fromProcessList output: String, root: String) -> [UUID: pid_t] {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var processes: [UUID: pid_t] = [:]
        for line in output.split(separator: "\n") where line.contains("--user-data-dir") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = pid_t(trimmed[..<separator]),
                  let range = trimmed.range(of: prefix) else { continue }
            let rest = trimmed[range.upperBound...]
            let token = rest.prefix { $0 != "/" && $0 != " " && $0 != "\"" }
            if let id = UUID(uuidString: String(token)) {
                processes[id] = pid
            }
        }
        return processes
    }

    /// 打开 TRAE 官方应用（不指定 user-data-dir，使用默认配置）。
    @discardableResult
    public func openApp() -> Bool {
        NSWorkspace.shared.open(URL(fileURLWithPath: appBundlePath))
    }

    // MARK: - 身份核验（待验证）

    /// 尝试用 traecli login status 核验当前登录身份。
    /// 阶段 A 结论：traecli 与桌面端是否共享登录态尚未验证，
    /// 若 traecli 未安装或不共享，则返回 nil，由用户手动确认。
    public func verifyLoginIdentity() -> String? {
        guard let traecli = findTraecli() else { return nil }
        // 加上超时，避免命令行卡住时整个切换流程停在“执行中”
        let (code, stdout, _) = process.run(
            launchPath: traecli,
            arguments: ["login", "status"],
            timeout: 5
        )
        guard code == 0, !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findTraecli() -> String? {
        let candidates = [
            "/usr/local/bin/traecli",
            "/opt/homebrew/bin/traecli",
            "\(NSHomeDirectory())/.trae-cli/bin/traecli"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
