import Foundation

/// 一键开工编排：预检 → 创建/复用 worktree → 生成上下文包。
///
/// 真正的 TRAE 启动由 UI 层调用 `AppState.openAccountApp` 完成，
/// 这样账号管理器和工作台共用同一套启动/激活/记录逻辑。
public final class WorkbenchService: Sendable {
    public struct StartPreparation: Sendable, Identifiable {
        public let id: UUID
        public let project: Project
        public let workstation: Workstation
        public let account: Account
        public let targetWorktree: URL
        public let pathState: StartupPreflight.WorktreePathState
        public let targetBranchOccupied: Bool
        public let worktreeStatus: GitWorktreeService.WorktreeStatus?
        public let runtime: StartupPreflight.RuntimeContext
        public let preflight: StartupPreflight.Result

        public var willCreateWorktree: Bool {
            if case .missing = pathState { return true }
            return false
        }

        public var worktreeAlreadyOpen: Bool {
            let target = targetWorktree.standardizedFileURL.path
            return runtime.isAccountRunning
                && runtime.openWorkspaces.contains { $0.standardizedFileURL.path == target }
        }
    }

    public struct StartPlan: Sendable {
        public let project: Project
        public let workstation: Workstation
        public let account: Account
        public let worktreeURL: URL
        public let contextPack: String
        public let createdWorktree: Bool
    }

    private let projects: ProjectService
    private let workstations: WorkstationService
    private let accounts: AccountService
    private let git: GitWorktreeService
    private let preflight: StartupPreflight
    private let context: ContextPackBuilder

    public init(
        projects: ProjectService,
        workstations: WorkstationService,
        accounts: AccountService,
        git: GitWorktreeService = GitWorktreeService(),
        preflight: StartupPreflight = StartupPreflight(),
        context: ContextPackBuilder = ContextPackBuilder()
    ) {
        self.projects = projects
        self.workstations = workstations
        self.accounts = accounts
        self.git = git
        self.preflight = preflight
        self.context = context
    }

    public var gitAvailable: Bool { git.isInstalled }

    // MARK: - 预检

    public func prepareStart(
        project: Project,
        workstation: Workstation,
        account: Account,
        runtime: StartupPreflight.RuntimeContext
    ) throws -> StartPreparation {
        guard workstation.projectId == project.id else {
            throw WorkbenchError.workstationProjectMismatch
        }
        guard account.platform == .trae else {
            throw WorkbenchError.notATraeAccount
        }
        guard let targetWorktree = workstation.worktreeURL, !targetWorktree.path.isEmpty else {
            throw WorkbenchError.missingWorktreePath
        }
        let branch = workstation.branchName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !branch.isEmpty else {
            throw WorkbenchError.missingBranch
        }

        let repoExists = FileManager.default.fileExists(atPath: project.repoPath)
        let repoIsGit = repoExists && git.isRepository(at: project.repoURL)
        let branches = repoIsGit ? git.localBranches(at: project.repoURL) : []
        let baselineExists = branches.contains(project.baselineBranch)
        let records = (try? git.existingWorktrees(at: project.repoURL)) ?? []

        let targetPath = targetWorktree.standardizedFileURL.path
        let record = records.first { $0.path == targetPath }
        let pathExists = FileManager.default.fileExists(atPath: targetPath)
        let pathState: StartupPreflight.WorktreePathState = {
            if record != nil { return .existingSameRepo }
            if pathExists { return .existingOtherRepo }
            return .missing
        }()
        let branchOccupied = records.contains { $0.branch == branch && $0.path != targetPath }
        let status = record == nil ? nil : (try? git.statusSummary(at: targetWorktree))

        let lanes = (try? workstations.list(projectId: project.id)) ?? []
        let duplicateAccount = lanes.contains {
            $0.id != workstation.id && $0.isEnabled && $0.accountId == account.id
        }

        let input = StartupPreflight.Input(
            project: project,
            workstation: workstation,
            account: account,
            accountAlreadyBoundToOtherLane: duplicateAccount,
            gitInstalled: git.isInstalled,
            repoExists: repoExists,
            repoIsGit: repoIsGit,
            baselineBranchExists: baselineExists,
            pathState: pathState,
            targetBranchOccupied: branchOccupied,
            worktreeStatus: status,
            runtime: runtime
        )
        let result = StartupPreflight.evaluate(input)

        return StartPreparation(
            id: UUID(),
            project: project,
            workstation: workstation,
            account: account,
            targetWorktree: targetWorktree,
            pathState: pathState,
            targetBranchOccupied: branchOccupied,
            worktreeStatus: status,
            runtime: runtime,
            preflight: result
        )
    }

    // MARK: - 执行

    /// 在用户确认预检结果后创建/复用 worktree，并生成上下文包。
    ///
    /// 不会启动 TRAE、不会提交、不会清理未提交变更。
    public func executeStart(
        preparation: StartPreparation,
        task: String? = nil
    ) throws -> StartPlan {
        guard preparation.preflight.canProceed else {
            throw WorkbenchError.preflightBlocked
        }
        guard let branch = preparation.workstation.branchName, !branch.isEmpty else {
            throw WorkbenchError.missingBranch
        }

        let created: Bool
        switch preparation.pathState {
        case .missing:
            try git.addWorktree(
                repoURL: preparation.project.repoURL,
                path: preparation.targetWorktree,
                branch: branch,
                baseline: preparation.project.baselineBranch
            )
            created = true
        case .existingSameRepo:
            created = false
        case .existingOtherRepo:
            throw WorkbenchError.worktreePathConflict
        }

        let contextPack = ContextPackBuilder.build(
            project: preparation.project,
            workstation: preparation.workstation,
            account: preparation.account,
            worktreeURL: preparation.targetWorktree,
            task: task
        )
        return StartPlan(
            project: preparation.project,
            workstation: preparation.workstation,
            account: preparation.account,
            worktreeURL: preparation.targetWorktree,
            contextPack: contextPack,
            createdWorktree: created
        )
    }

    // MARK: - 生命周期对账

    /// 对账项目工位与实际 Git 状态：识别目录丢失、登记丢失、分支漂移与未纳管 worktree。
    ///
    /// 只做识别，不做任何修复；清理类操作（prune/删除 worktree）仍走
    /// `GitWorktreeService` 的确认流程。Git 不可用时抛出既有错误。
    public func reconcile(project: Project) throws -> WorktreeReconciliationReport {
        let lanes = try workstations.list(projectId: project.id)
        let records = try git.existingWorktrees(at: project.repoURL)
        return WorktreeReconciliation.reconcile(
            workstations: lanes,
            registered: records,
            repoMainPath: project.repoURL.standardizedFileURL.path,
            statusProvider: { path in
                try? git.statusSummary(at: URL(fileURLWithPath: path))
            }
        )
    }

    // MARK: - 工具

    public func status(for workstation: Workstation) -> GitWorktreeService.WorktreeStatus? {
        guard let url = workstation.worktreeURL else { return nil }
        return try? git.statusSummary(at: url)
    }

    public func removeWorktree(
        project: Project,
        workstation: Workstation,
        confirm: Bool
    ) throws {
        guard let url = workstation.worktreeURL else {
            throw WorkbenchError.missingWorktreePath
        }
        try git.removeWorktree(repoURL: project.repoURL, path: url, confirm: confirm)
    }

    public func isRepository(at path: String) -> Bool {
        git.isRepository(at: URL(fileURLWithPath: path))
    }

    public func localBranches(repoPath: String) -> [String] {
        git.localBranches(at: URL(fileURLWithPath: repoPath))
    }

    public func currentBranch(repoPath: String) -> String? {
        git.currentBranch(at: URL(fileURLWithPath: repoPath))
    }
}

public enum WorkbenchError: LocalizedError {
    case workstationProjectMismatch
    case notATraeAccount
    case missingWorktreePath
    case missingBranch
    case preflightBlocked
    case worktreePathConflict

    public var errorDescription: String? {
        switch self {
        case .workstationProjectMismatch:
            return "工位不属于当前项目"
        case .notATraeAccount:
            return "工作台工位只支持 TRAE 账号"
        case .missingWorktreePath:
            return "工位还没有生成 worktree 路径"
        case .missingBranch:
            return "工位还没有生成分支名"
        case .preflightBlocked:
            return "预检未通过，请先处理阻断项"
        case .worktreePathConflict:
            return "worktree 路径已被其他目录占用"
        }
    }
}
