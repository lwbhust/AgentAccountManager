import Foundation

/// 单个工位的 worktree 对账结论。
///
/// 数据来源是三份事实的交叉比对：工位表登记（worktreePath/branchName）、
/// `git worktree list` 实际登记、文件系统目录是否存在。
/// 对账只做识别，不做修复；清理类操作仍走 `GitWorktreeService` 的确认流程。
public struct WorkstationReconciliation: Sendable, Equatable {
    /// 工位 worktree 的结构一致性。
    public enum Health: Sendable, Equatable {
        /// 尚未开工：没有激活记录，目录与 Git 登记都不存在（正常状态）
        case notStarted
        /// Git 登记与目录一致，归属本仓库
        case healthy
        /// Git 有登记但目录已丢失（外部删除或异常中断）；需要 prune 才能恢复一致
        case directoryMissing
        /// 目录存在但不被本仓库识别为 worktree（登记丢失，或路径被其他内容占用）
        case registrationMissing
        /// 曾经激活过，但现在目录与 Git 登记都不存在（被外部整体清理或异常退出后清理）
        case vanished
    }

    public let workstationId: UUID
    public let workstationName: String
    /// 数据库登记的 worktree 路径
    public let worktreePath: String?
    /// 数据库登记的目标分支
    public let branchName: String?
    public let health: Health
    /// 实际工作分支与工作区状态（仅「登记且目录存在」时读取；其余情况不做无意义的 IO）
    public let status: GitWorktreeService.WorktreeStatus?

    /// 实际工作分支与数据库登记分支是否不一致。
    public var isBranchMismatch: Bool {
        guard let registered = branchName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !registered.isEmpty,
              let actual = status?.branch else { return false }
        return actual != registered
    }

    /// 是否需要用户留意处理（结构不一致或分支漂移）。
    public var needsAttention: Bool {
        (health != .healthy && health != .notStarted) || isBranchMismatch
    }
}

/// Git 有登记、但没有绑定到任何工位的 worktree。
///
/// 可能是应用异常退出或工位记录被删除后的残留，也可能是用户自行管理的
/// worktree；只报告不处置。目录存在时附带工作区状态，提醒其中可能有
/// 未提交的用户工作。
public struct UnmanagedWorktree: Sendable, Equatable {
    public let path: String
    public let branch: String?
    public let directoryExists: Bool
    public let status: GitWorktreeService.WorktreeStatus?
}

/// 一次对账的完整结果。
public struct WorktreeReconciliationReport: Sendable, Equatable {
    public let workstations: [WorkstationReconciliation]
    public let unmanaged: [UnmanagedWorktree]

    public init(workstations: [WorkstationReconciliation], unmanaged: [UnmanagedWorktree]) {
        self.workstations = workstations
        self.unmanaged = unmanaged
    }

    /// 是否存在需要用户留意的不一致。
    public var needsAttention: Bool {
        workstations.contains(where: \.needsAttention)
    }
}

/// 工位生命周期对账（任务书 5.E：识别异常退出、目录丢失、登记与实际状态不一致）。
public enum WorktreeReconciliation {
    /// 统一的路径归一化：解析符号链接后再标准化。
    ///
    /// `standardizedFileURL` 只在路径完整存在时解析符号链接，`resolvingSymlinksInPath`
    /// 对不存在的尾段也不会解析前缀上的符号链接——目录丢失后数据库里的
    /// `/var/...` 与 git 登记的 `/private/var/...` 会失配。这里先把路径向上
    /// 归约到已存在的前缀，解析符号链接后再拼回缺失的尾段，保证存在/丢失
    /// 两种情况下两侧一致。
    static func normalizedPath(_ raw: String) -> String {
        var url = URL(fileURLWithPath: raw).standardizedFileURL
        var missingTail: [String] = []
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.path) {
            missingTail.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        for component in missingTail {
            resolved = resolved.hasSuffix("/") ? resolved + component : resolved + "/" + component
        }
        return URL(fileURLWithPath: resolved).standardizedFileURL.path
    }

    /// 交叉比对工位登记与实际 Git 状态。
    ///
    /// - Parameters:
    ///   - workstations: 数据库中的工位记录（通常为同一项目下的全部工位）。
    ///   - registered: `git worktree list --porcelain` 的登记记录。
    ///   - repoMainPath: 仓库主工作区路径；它不属于工位管理，不计入未纳管。
    ///   - fileExists: 目录存在性探测（注入以便测试）。
    ///   - statusProvider: 工作区状态读取（注入以便测试）；只在目录存在且
    ///     需要展示状态时调用，不对应读取的路径不会产生 IO。
    public static func reconcile(
        workstations: [Workstation],
        registered: [GitWorktreeService.WorktreeRecord],
        repoMainPath: String? = nil,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        statusProvider: (String) -> GitWorktreeService.WorktreeStatus? = { _ in nil }
    ) -> WorktreeReconciliationReport {
        let mainPath = repoMainPath.map(normalizedPath)
        // git 返回的登记路径统一归一化，避免符号链接导致两侧失配
        let registeredEntries = registered.map { record in
            (record: record, path: normalizedPath(record.path))
        }

        var entries: [WorkstationReconciliation] = []
        var claimedPaths = Set<String>()

        for workstation in workstations {
            let rawPath = workstation.worktreePath?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !rawPath.isEmpty else {
                entries.append(WorkstationReconciliation(
                    workstationId: workstation.id,
                    workstationName: workstation.displayName,
                    worktreePath: nil,
                    branchName: workstation.branchName,
                    health: .notStarted,
                    status: nil
                ))
                continue
            }

            let target = normalizedPath(rawPath)
            let record = registeredEntries.first { $0.path == target }?.record
            let dirExists = fileExists(target)

            let health: WorkstationReconciliation.Health
            let status: GitWorktreeService.WorktreeStatus?
            switch (record, dirExists) {
            case (.some, true):
                health = .healthy
                status = statusProvider(target)
            case (.some, false):
                health = .directoryMissing
                status = nil
            case (nil, true):
                // 目录可能属于其他仓库或普通内容，不读取它的状态以免误报
                health = .registrationMissing
                status = nil
            case (nil, false):
                health = workstation.lastActivatedAt == nil ? .notStarted : .vanished
                status = nil
            }

            if record != nil {
                claimedPaths.insert(target)
            }
            entries.append(WorkstationReconciliation(
                workstationId: workstation.id,
                workstationName: workstation.displayName,
                worktreePath: target,
                branchName: workstation.branchName,
                health: health,
                status: status
            ))
        }

        var unmanaged: [UnmanagedWorktree] = []
        for entry in registeredEntries where !claimedPaths.contains(entry.path) {
            if entry.path == mainPath { continue }
            let dirExists = fileExists(entry.path)
            let status = dirExists ? statusProvider(entry.path) : nil
            unmanaged.append(UnmanagedWorktree(
                path: entry.record.path,
                branch: entry.record.branch,
                directoryExists: dirExists,
                status: status
            ))
        }

        return WorktreeReconciliationReport(workstations: entries, unmanaged: unmanaged)
    }
}
