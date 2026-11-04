import Foundation

/// 受控 Git worktree 操作。
///
/// 只执行显式白名单命令；读取状态与 worktree 登记，不读取源码内容。
/// 创建/删除由调用方二次确认，失败不重试、不使用 `--force`。
public struct GitWorktreeService: Sendable {
    public struct WorktreeStatus: Sendable, Equatable {
        public let branch: String?
        public let isClean: Bool
        public let changedFileCount: Int

        public init(branch: String?, isClean: Bool, changedFileCount: Int) {
            self.branch = branch
            self.isClean = isClean
            self.changedFileCount = changedFileCount
        }
    }

    public struct WorktreeRecord: Sendable, Identifiable, Equatable {
        public let path: String
        public let branch: String?
        public let head: String?

        public var id: String { path }

        public init(path: String, branch: String?, head: String?) {
            self.path = path
            self.branch = branch
            self.head = head
        }
    }

    private let gitPath: String
    private let process: ProcessService

    public init(gitPath: String? = nil, process: ProcessService = ProcessService()) {
        self.gitPath = gitPath ?? Self.resolveGitPath()
        self.process = process
    }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: gitPath)
    }

    // MARK: - 读取

    public func isRepository(at url: URL) -> Bool {
        guard isInstalled else { return false }
        let (code, output, _) = process.run(
            launchPath: gitPath,
            arguments: ["-C", url.path, "rev-parse", "--is-inside-work-tree"],
            timeout: 8
        )
        return code == 0 && output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func currentBranch(at repoURL: URL) -> String? {
        guard isInstalled else { return nil }
        let (code, output, _) = process.run(
            launchPath: gitPath,
            arguments: ["-C", repoURL.path, "rev-parse", "--abbrev-ref", "HEAD"],
            timeout: 8
        )
        guard code == 0 else { return nil }
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty || branch == "HEAD" ? nil : branch
    }

    public func localBranches(at repoURL: URL) -> [String] {
        guard isInstalled else { return [] }
        let (code, output, _) = process.run(
            launchPath: gitPath,
            arguments: ["-C", repoURL.path, "for-each-ref", "--format=%(refname:short)", "refs/heads"],
            timeout: 8
        )
        guard code == 0 else { return [] }
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public func statusSummary(at url: URL) throws -> WorktreeStatus {
        let output = try run(["-C", url.path, "status", "--porcelain=v1", "--branch"], timeout: 12)
        var branch: String?
        var changed = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("## ") {
                let rest = String(text.dropFirst(3))
                let name = rest.components(separatedBy: "...").first ?? ""
                branch = name.isEmpty ? nil : name
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                changed += 1
            }
        }
        return WorktreeStatus(
            branch: branch,
            isClean: changed == 0,
            changedFileCount: changed
        )
    }

    public func existingWorktrees(at repoURL: URL) throws -> [WorktreeRecord] {
        let output = try run(["-C", repoURL.path, "worktree", "list", "--porcelain"], timeout: 12)
        var records: [WorktreeRecord] = []
        var currentPath: String?
        var currentBranch: String?
        var currentHead: String?

        func flush() {
            if let path = currentPath {
                records.append(WorktreeRecord(
                    path: URL(fileURLWithPath: path).standardizedFileURL.path,
                    branch: currentBranch,
                    head: currentHead
                ))
            }
            currentPath = nil
            currentBranch = nil
            currentHead = nil
        }

        for lineSub in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                currentHead = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                currentBranch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "detached" {
                currentBranch = nil
            }
        }
        flush()
        return records
    }

    public func isWorktree(_ path: URL, of repoURL: URL) throws -> Bool {
        let target = path.standardizedFileURL.path
        return try existingWorktrees(at: repoURL).contains { $0.path == target }
    }

    // MARK: - 写入

    public func addWorktree(
        repoURL: URL,
        path: URL,
        branch: String,
        baseline: String
    ) throws {
        let target = path.standardizedFileURL.path
        guard !FileManager.default.fileExists(atPath: target) else {
            throw GitWorktreeError.pathExists
        }
        let records = try existingWorktrees(at: repoURL)
        if records.contains(where: { $0.branch == branch && $0.path != target }) {
            throw GitWorktreeError.branchInUse(branch)
        }
        let branches = localBranches(at: repoURL)
        if branches.contains(branch) {
            _ = try run(
                ["-C", repoURL.path, "worktree", "add", target, branch],
                timeout: 120
            )
        } else {
            _ = try run(
                ["-C", repoURL.path, "worktree", "add", "-b", branch, target, baseline],
                timeout: 120
            )
        }
    }

    public func removeWorktree(
        repoURL: URL,
        path: URL,
        confirm: Bool
    ) throws {
        guard confirm else { throw GitWorktreeError.confirmationRequired }
        let target = path.standardizedFileURL.path
        let records = try existingWorktrees(at: repoURL)
        guard records.contains(where: { $0.path == target }) else {
            throw GitWorktreeError.notAWorktree(target)
        }
        let status = try statusSummary(at: path)
        guard status.isClean else {
            throw GitWorktreeError.worktreeDirty(status.changedFileCount)
        }
        _ = try run(
            ["-C", repoURL.path, "worktree", "remove", target],
            timeout: 30
        )
    }

    public func pruneStale(repoURL: URL, confirm: Bool) throws {
        guard confirm else { throw GitWorktreeError.confirmationRequired }
        _ = try run(["-C", repoURL.path, "worktree", "prune"], timeout: 30)
    }

    // MARK: - 私有

    @discardableResult
    private func run(_ arguments: [String], timeout: TimeInterval) throws -> String {
        guard isInstalled else { throw GitWorktreeError.gitNotInstalled }
        let (code, stdout, stderr) = process.run(
            launchPath: gitPath,
            arguments: ["--no-pager"] + arguments,
            timeout: timeout
        )
        guard code == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitWorktreeError.commandFailed(message, code)
        }
        return stdout
    }

    private static func resolveGitPath() -> String {
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }
}

public enum GitWorktreeError: LocalizedError {
    case gitNotInstalled
    case commandFailed(String, Int32)
    case pathExists
    case branchInUse(String)
    case notAWorktree(String)
    case worktreeDirty(Int)
    case confirmationRequired

    public var errorDescription: String? {
        switch self {
        case .gitNotInstalled:
            return "未找到可用的 Git，请先安装 Xcode Command Line Tools"
        case .commandFailed(let message, let code):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Git 命令失败（退出码 \(code)）：\(trimmed.prefix(500))"
        case .pathExists:
            return "目标 worktree 目录已存在，请先确认它不是要覆盖的内容"
        case .branchInUse(let branch):
            return "分支 \(branch) 已被其他 worktree 占用"
        case .notAWorktree:
            return "目标路径不是该仓库的 worktree"
        case .worktreeDirty(let count):
            return "worktree 有 \(count) 个未提交变更，请先处理后再移除"
        case .confirmationRequired:
            return "该操作需要二次确认"
        }
    }
}
