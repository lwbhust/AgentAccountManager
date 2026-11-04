import Foundation

/// 开工预检：只判断仓库、工位、账号身份和运行态，不读取积分。
public struct StartupPreflight: Sendable {
    public init() {}

    public enum Status: String, Sendable, Equatable {
        case pass
        case info
        case warning
        case blocked

        public var title: String {
            switch self {
            case .pass: return "通过"
            case .info: return "提示"
            case .warning: return "警告"
            case .blocked: return "阻断"
            }
        }
    }

    public struct Check: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let detail: String?
        public let status: Status

        public init(id: String, title: String, detail: String? = nil, status: Status) {
            self.id = id
            self.title = title
            self.detail = detail
            self.status = status
        }
    }

    public struct Result: Sendable {
        public let checks: [Check]

        public init(checks: [Check]) {
            self.checks = checks
        }

        public var canProceed: Bool {
            !checks.contains { $0.status == .blocked }
        }

        public var blockingChecks: [Check] {
            checks.filter { $0.status == .blocked }
        }

        public var warningChecks: [Check] {
            checks.filter { $0.status == .warning }
        }

        public var infoChecks: [Check] {
            checks.filter { $0.status == .info }
        }

        public var summary: String {
            if !blockingChecks.isEmpty {
                return "有 \(blockingChecks.count) 项需要先处理"
            }
            if !warningChecks.isEmpty {
                return "有 \(warningChecks.count) 项提示，确认后可继续"
            }
            return "检查通过，可以开工"
        }
    }

    public enum WorktreePathState: Sendable {
        case missing
        case existingSameRepo
        case existingOtherRepo
    }

    public struct RuntimeContext: Sendable {
        public let isAccountRunning: Bool
        public let openWorkspaces: [URL]
        public let targetWorktree: URL
        public let runningLaneLabel: String?

        public init(
            isAccountRunning: Bool,
            openWorkspaces: [URL],
            targetWorktree: URL,
            runningLaneLabel: String? = nil
        ) {
            self.isAccountRunning = isAccountRunning
            self.openWorkspaces = openWorkspaces
            self.targetWorktree = targetWorktree
            self.runningLaneLabel = runningLaneLabel
        }
    }

    public struct Input: Sendable {
        public let project: Project
        public let workstation: Workstation
        public let account: Account?
        public let accountAlreadyBoundToOtherLane: Bool
        public let gitInstalled: Bool
        public let repoExists: Bool
        public let repoIsGit: Bool
        public let baselineBranchExists: Bool
        public let pathState: WorktreePathState
        public let targetBranchOccupied: Bool
        public let worktreeStatus: GitWorktreeService.WorktreeStatus?
        public let runtime: RuntimeContext

        public init(
            project: Project,
            workstation: Workstation,
            account: Account?,
            accountAlreadyBoundToOtherLane: Bool,
            gitInstalled: Bool,
            repoExists: Bool,
            repoIsGit: Bool,
            baselineBranchExists: Bool,
            pathState: WorktreePathState,
            targetBranchOccupied: Bool,
            worktreeStatus: GitWorktreeService.WorktreeStatus?,
            runtime: RuntimeContext
        ) {
            self.project = project
            self.workstation = workstation
            self.account = account
            self.accountAlreadyBoundToOtherLane = accountAlreadyBoundToOtherLane
            self.gitInstalled = gitInstalled
            self.repoExists = repoExists
            self.repoIsGit = repoIsGit
            self.baselineBranchExists = baselineBranchExists
            self.pathState = pathState
            self.targetBranchOccupied = targetBranchOccupied
            self.worktreeStatus = worktreeStatus
            self.runtime = runtime
        }
    }

    public static func evaluate(_ input: Input) -> Result {
        var checks: [Check] = []

        checks.append(Check(
            id: "git",
            title: "Git 可用",
            detail: input.gitInstalled ? nil : "未找到可用的 Git，请先安装 Xcode Command Line Tools",
            status: input.gitInstalled ? .pass : .blocked
        ))

        checks.append(Check(
            id: "repo",
            title: "仓库有效",
            detail: !input.repoExists
                ? "仓库路径不存在：\(input.project.repoPath)"
                : (!input.repoIsGit ? "目录不是 Git 仓库：\(input.project.repoPath)" : nil),
            status: input.repoExists && input.repoIsGit ? .pass : .blocked
        ))

        checks.append(Check(
            id: "baseline",
            title: "基线分支存在",
            detail: input.baselineBranchExists
                ? "基线分支：\(input.project.baselineBranch)"
                : "本地找不到分支 \(input.project.baselineBranch)",
            status: input.baselineBranchExists ? .pass : .blocked
        ))

        switch input.pathState {
        case .missing:
            checks.append(Check(
                id: "worktreePath",
                title: "worktree 路径可用",
                detail: "将创建 \(input.runtime.targetWorktree.path)",
                status: .pass
            ))
        case .existingSameRepo:
            checks.append(Check(
                id: "worktreePath",
                title: "worktree 已存在",
                detail: "将复用 \(input.runtime.targetWorktree.path)，不会 reset 或 clean",
                status: .pass
            ))
        case .existingOtherRepo:
            checks.append(Check(
                id: "worktreePath",
                title: "worktree 路径冲突",
                detail: "路径已存在，但不是该仓库的 worktree：\(input.runtime.targetWorktree.path)",
                status: .blocked
            ))
        }

        checks.append(Check(
            id: "branch",
            title: "工位分支可用",
            detail: input.targetBranchOccupied
                ? "分支 \(input.workstation.branchName ?? "") 已被其他 worktree 占用"
                : "工位分支：\(input.workstation.branchName ?? "未生成")",
            status: input.targetBranchOccupied ? .blocked : .pass
        ))

        if let status = input.worktreeStatus, !status.isClean {
            checks.append(Check(
                id: "dirty",
                title: "worktree 有未提交变更",
                detail: "\(status.changedFileCount) 个文件有变更；开工不会自动提交或清理",
                status: .warning
            ))
        }

        checks.append(Check(
            id: "enabled",
            title: "工位已启用",
            detail: input.workstation.isEnabled ? nil : "该工位当前已停用",
            status: input.workstation.isEnabled ? .pass : .blocked
        ))

        if let account = input.account {
            checks.append(Check(
                id: "account",
                title: "账号已选择",
                detail: "\(account.displayName)（\(account.platform.displayName)）",
                status: .pass
            ))
            checks.append(Check(
                id: "accountPlatform",
                title: "账号平台匹配",
                detail: account.platform == .trae ? nil : "工作台工位只支持 TRAE 账号",
                status: account.platform == .trae ? .pass : .blocked
            ))
            if input.project.orchestrationMode == .rolePlay,
               let bound = input.workstation.accountId,
               bound != account.id {
                checks.append(Check(
                    id: "roleBinding",
                    title: "角色工位账号不一致",
                    detail: "该工位绑定的是另一个账号，请先在工位设置中调整",
                    status: .blocked
                ))
            }
        } else {
            checks.append(Check(
                id: "account",
                title: "账号未选择",
                detail: "请先为工位选择 TRAE 账号",
                status: .blocked
            ))
        }

        if input.accountAlreadyBoundToOtherLane {
            checks.append(Check(
                id: "accountDuplicate",
                title: "账号已绑定其他工位",
                detail: "同一项目内一个账号只能绑定一个工位",
                status: .blocked
            ))
        }

        checks.append(runtimeCheck(input.runtime))

        if let setupHint = input.project.setupHint, !setupHint.isEmpty {
            checks.append(Check(
                id: "setup",
                title: "初始化提示",
                detail: setupHint,
                status: .info
            ))
        }

        return Result(checks: checks)
    }

    private static func runtimeCheck(_ runtime: RuntimeContext) -> Check {
        let target = runtime.targetWorktree.standardizedFileURL.path
        let workspaces = runtime.openWorkspaces.map { $0.standardizedFileURL.path }

        if !runtime.isAccountRunning {
            return Check(
                id: "runtime",
                title: "账号实例未运行",
                detail: "将启动该账号的独立实例并打开 worktree",
                status: .pass
            )
        }
        if workspaces.contains(target) {
            return Check(
                id: "runtime",
                title: "工位窗口已打开",
                detail: "将激活已有窗口，不重复启动",
                status: .pass
            )
        }

        let others = workspaces.filter { $0 != target }
        let names = others.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、")
        var detail = "该账号实例正在运行，但目标 worktree 未打开"
        if !names.isEmpty {
            detail += "；当前打开：\(names)"
        }
        if let lane = runtime.runningLaneLabel {
            detail += "；该账号也在\(lane)运行"
        }
        return Check(
            id: "runtime",
            title: "账号已在其他目录运行",
            detail: detail + "。继续会在同一实例新增窗口。",
            status: .warning
        )
    }
}
