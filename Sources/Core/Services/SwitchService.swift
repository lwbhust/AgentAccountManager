import Foundation
import os

// MARK: - 切换阶段状态机

/// 切换事务的阶段标记（Phase 1a 状态机）。
///
/// 正常流转：idle → preflight → launching → verifying → committing → completed；
/// 任意阶段失败进入 failed，由 `SwitchOutcome.failedAtPhase` 记录停在哪一步。
///
/// 未引入 Cancelled：switchTo 是同步流程，外部进程启动之后没有可安全取消的
/// 暂停点，贸然取消只会留下半启动状态——因此保持「要么做完，要么如实记失败」。
public enum SwitchPhase: String, Sendable, CaseIterable {
    case idle
    case preflight
    case launching
    case verifying
    case committing
    case completed
    case failed
}

// MARK: - 可注入的平台能力边界
//
// 任务书 Phase 1a-E/F：外部进程启动与身份核验是有副作用的边界，
// 协议化后测试可注入 Mock/Stub 覆盖异常路径，无需真实安装官方应用。

/// WorkBuddy 平台能力（官方无 CLI，只能打开应用）。
public protocol WorkBuddySwitching: Sendable {
    /// 官方应用是否已安装。
    var isInstalled: Bool { get }
    /// 打开官方应用。返回系统是否接受启动请求（不代表已登录）。
    @discardableResult
    func openApp() -> Bool
}

/// TRAE 平台能力（独立实例启动 + traecli 身份核验）。
public protocol TraeSwitching: Sendable {
    /// 官方应用包能否在本机解析（用于区分「应用未安装」与「CLI 不可用」）。
    var isApplicationBundleResolvable: Bool { get }
    /// 内置命令行是否可执行。
    var isInstalled: Bool { get }
    /// 读取该账号上次打开的工作区。
    func lastWorkspace(for accountId: UUID) -> URL?
    /// 启动独立配置实例（有副作用：创建 user-data-dir、拉起进程）。
    @discardableResult
    func launchIsolated(account: Account, workspace: URL?) throws -> Bool
    /// 该账号隔离目录是否已有会话数据（辅助信号，不构成身份核验）。
    func hasPersistedSession(accountId: UUID) -> Bool
    /// 通过官方 traecli 读取当前登录身份；无法核验时返回 nil。
    func verifyLoginIdentity() -> String?
}

extension WorkBuddyService: WorkBuddySwitching {}
extension TraeService: TraeSwitching {}

/// 账号切换事务编排。
///
/// 设计原则（与产品要求一致）：
/// 1. 只使用经过验证的官方能力，不静默修改平台私有文件。
/// 2. 「打开了客户端」≠「已登录目标账号」，结果必须与真实证据一致。
/// 3. 无法自动核验身份时，交给用户在官方界面核对后确认。
/// 4. 平台差异封装在服务层（协议边界），UI 只消费统一的 SwitchOutcome。
/// 5. 同一时间只允许一个切换事务（服务级互斥）；状态账目在一个事务内提交。
public final class SwitchService: Sendable {
    private let accountService: AccountService
    private let switchLogService: SwitchLogService
    private let workbuddy: any WorkBuddySwitching
    private let trae: any TraeSwitching
    private let projectVisitService: ProjectVisitService?
    /// 共享数据库。提供后成功路径的状态提交（登录状态/lastUsedAt/ProjectVisit/SwitchLog）
    /// 在单个事务内落库；为 nil 时退化为逐项写入并单独容错（与历史行为一致）。
    private let database: DatabaseService?
    private let logger = AppLogger(category: "switch")

    /// 切换事务互斥（Phase 1a-C）：同一时间仅允许一个 switchTo 事务执行。
    private let inFlight = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// 当前是否有切换事务正在执行（供 UI 与诊断观察）。
    public var isSwitching: Bool { inFlight.withLock { $0 } }

    public init(
        accountService: AccountService,
        switchLogService: SwitchLogService,
        database: DatabaseService? = nil,
        workbuddy: any WorkBuddySwitching = WorkBuddyService(),
        trae: any TraeSwitching = TraeService(),
        projectVisitService: ProjectVisitService? = nil
    ) {
        self.accountService = accountService
        self.switchLogService = switchLogService
        self.database = database
        self.workbuddy = workbuddy
        self.trae = trae
        self.projectVisitService = projectVisitService
    }

    /// 一次切换事务的结果。
    public struct SwitchOutcome: Sendable {
        public let result: SwitchResult
        /// 一句话结论，例如「已打开 WorkBuddy，等待你核对」
        public let headline: String
        /// 补充说明（结果依据、限制说明）
        public let detail: String
        /// 是否通过官方手段技术验证了当前身份
        public let identityVerified: Bool
        /// 技术验证得到的身份文本（仅 verified 时有值）
        public let claimedIdentity: String?
        /// 需要用户在官方界面完成的步骤
        public let manualSteps: [String]
        /// 失败时的下一步建议
        public let failureAdvice: String?
        /// 是否已成功启动官方应用/实例（外部事实，即使提交失败也如实保留）
        public let launched: Bool
        /// 事务终态阶段：completed / failed
        public let phase: SwitchPhase
        /// 失败时停在哪个阶段；成功为 nil
        public let failedAtPhase: SwitchPhase?

        public init(
            result: SwitchResult,
            headline: String,
            detail: String,
            identityVerified: Bool,
            claimedIdentity: String?,
            manualSteps: [String],
            failureAdvice: String?,
            launched: Bool,
            phase: SwitchPhase = .completed,
            failedAtPhase: SwitchPhase? = nil
        ) {
            self.result = result
            self.headline = headline
            self.detail = detail
            self.identityVerified = identityVerified
            self.claimedIdentity = claimedIdentity
            self.manualSteps = manualSteps
            self.failureAdvice = failureAdvice
            self.launched = launched
            self.phase = phase
            self.failedAtPhase = failedAtPhase
        }

        /// 复制结果并盖上终态阶段标记（内部收尾用）。
        func stamped(phase: SwitchPhase, failedAtPhase: SwitchPhase?) -> SwitchOutcome {
            SwitchOutcome(
                result: result,
                headline: headline,
                detail: detail,
                identityVerified: identityVerified,
                claimedIdentity: claimedIdentity,
                manualSteps: manualSteps,
                failureAdvice: failureAdvice,
                launched: launched,
                phase: phase,
                failedAtPhase: failedAtPhase
            )
        }
    }

    /// 执行切换事务。
    ///
    /// 服务级互斥：同一时间仅允许一个切换事务。已有事务在执行时立即拒绝；
    /// 被拒绝的尝试不写入切换日志——它什么都没有发生，重复记录只会污染历史。
    public func switchTo(account: Account) -> SwitchOutcome {
        let acquired = inFlight.withLock { busy -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard acquired else {
            logger.info("拒绝并发切换: 目标=\(account.id.uuidString.prefix(8)) 已有切换事务在执行")
            return SwitchOutcome(
                result: .failed,
                headline: "已有切换正在进行",
                detail: "上一次账号切换尚未结束，为避免重复启动与状态互相覆盖，本次未执行。",
                identityVerified: false,
                claimedIdentity: nil,
                manualSteps: [],
                failureAdvice: "请等待当前切换完成（通常只需数秒），或在官方应用窗口完成核对后重试。",
                launched: false,
                phase: .failed,
                failedAtPhase: .idle
            )
        }
        defer { inFlight.withLock { $0 = false } }
        return performSwitch(account: account)
    }

    /// 切换事务主体：preflight → launching → verifying → committing。
    private func performSwitch(account: Account) -> SwitchOutcome {
        // ---- 1. Preflight：目标账号仍存在、平台一致、官方应用可用 ----
        var phase: SwitchPhase = .preflight
        let current: Account
        do {
            guard let fetched = try accountService.get(id: account.id) else {
                return failedOutcome(
                    account: account,
                    phase: phase,
                    detail: "目标账号不存在或已被删除。",
                    advice: "请刷新账号列表后重试。"
                )
            }
            guard fetched.platform == account.platform else {
                return failedOutcome(
                    account: fetched,
                    phase: phase,
                    detail: "目标账号的平台信息已变化（\(account.platform.displayName) → \(fetched.platform.displayName)），已中止切换。",
                    advice: "请刷新账号列表后重试。"
                )
            }
            current = fetched
        } catch {
            return failedOutcome(
                account: account,
                phase: phase,
                detail: "读取目标账号失败：\(error.localizedDescription)",
                advice: "请重试；若持续失败请检查数据库文件是否可访问。"
            )
        }

        if let problem = installProblem(for: current.platform) {
            return failedOutcome(
                account: current,
                phase: phase,
                detail: problem,
                advice: "请先安装 \(current.platform.displayName) 官方应用后重试。"
            )
        }

        // ---- 2. Launching：平台专属启动（外部副作用，不可回滚） ----
        phase = .launching
        let launchOutcome: SwitchOutcome
        switch current.platform {
        case .workbuddy:
            launchOutcome = openWorkBuddy()
        case .trae:
            launchOutcome = launchTrae(account: current)
        }
        guard launchOutcome.result != .failed else {
            return finish(
                account: current,
                fromStatus: current.lastLoginStatus,
                outcome: launchOutcome,
                phase: .failed,
                failedAtPhase: phase
            )
        }

        // ---- 3. Verifying：启动成功 ≠ 登录成功，仅用官方手段核验 ----
        phase = .verifying
        let verifiedOutcome = verifyIdentity(account: current, outcome: launchOutcome)

        // ---- 4. Committing：提交登录状态/lastUsedAt/ProjectVisit/SwitchLog ----
        phase = .committing
        let nextStatus = resolveStatus(account: current, outcome: verifiedOutcome)
        switch commitState(
            account: current,
            fromStatus: current.lastLoginStatus,
            nextStatus: nextStatus,
            outcome: verifiedOutcome
        ) {
        case .committedAtomically:
            return finish(
                account: current,
                fromStatus: current.lastLoginStatus,
                outcome: verifiedOutcome,
                nextStatus: nextStatus,
                phase: .completed,
                logCommittedInTransaction: true
            )
        case .committedIndividually:
            return finish(
                account: current,
                fromStatus: current.lastLoginStatus,
                outcome: verifiedOutcome,
                nextStatus: nextStatus,
                phase: .completed
            )
        case .failed(let reason):
            // 提交失败：事务已回滚，不留成功痕迹；结果如实降级为失败，
            // 但保留「应用已启动」这一外部事实，便于用户核对现场。
            let failed = SwitchOutcome(
                result: .failed,
                headline: "切换状态保存失败",
                detail: "应用已启动，但保存切换状态时出错：\(reason)。账号状态未被修改。",
                identityVerified: verifiedOutcome.identityVerified,
                claimedIdentity: verifiedOutcome.claimedIdentity,
                manualSteps: verifiedOutcome.manualSteps,
                failureAdvice: "可重试切换；若反复失败，请检查数据文件夹中的数据库文件。",
                launched: verifiedOutcome.launched,
                phase: .failed,
                failedAtPhase: .committing
            )
            return finish(
                account: current,
                fromStatus: current.lastLoginStatus,
                outcome: failed,
                nextStatus: current.lastLoginStatus,
                phase: .failed,
                failedAtPhase: .committing
            )
        }
    }

    /// 用户核对官方界面后手动确认登录。
    public func confirmLogin(account: Account) {
        do {
            _ = try accountService.updateLoginStatus(id: account.id, status: .userConfirmed)
            logger.info("用户确认登录: account=\(account.id.uuidString.prefix(8))")
        } catch {
            logger.error("保存用户确认失败: account=\(account.id.uuidString.prefix(8)) error=\(error.localizedDescription)")
        }
    }

    /// 切换前检查官方应用可用性。
    /// - Returns: 存在问题时的说明；nil 表示可用。
    public func installProblem(for platform: Platform) -> String? {
        switch platform {
        case .workbuddy:
            return workbuddy.isInstalled
                ? nil
                : "未找到 WorkBuddy 官方应用（已检查 /Applications 与系统已安装应用列表）。"
        case .trae:
            guard trae.isApplicationBundleResolvable else {
                return "未找到 Trae CN 官方应用（已检查 /Applications 与系统已安装应用列表）。"
            }
            guard trae.isInstalled else {
                return "TRAE 内置命令行不可用，无法启动独立配置实例。请确认应用为完整安装版本。"
            }
            return nil
        }
    }

    // MARK: - 平台实现

    private func openWorkBuddy() -> SwitchOutcome {
        guard workbuddy.openApp() else {
            return SwitchOutcome(
                result: .failed,
                headline: "无法打开 WorkBuddy",
                detail: "系统拒绝启动 WorkBuddy AI.app。",
                identityVerified: false,
                claimedIdentity: nil,
                manualSteps: [],
                failureAdvice: "请在 Finder 中手动打开 WorkBuddy 后重试，或在「设置」中确认应用安装位置。",
                launched: false
            )
        }
        return SwitchOutcome(
            result: .unconfirmed,
            headline: "已打开 WorkBuddy，等待你核对",
            detail: "WorkBuddy 不支持自动切换账号，需要你在官方界面完成退出与登录。",
            identityVerified: false,
            claimedIdentity: nil,
            manualSteps: [
                "在 WorkBuddy 头像菜单中点击「退出登录」",
                "用目标账号完成登录",
                "回到本应用点击「我已核对并登录」"
            ],
            failureAdvice: nil,
            launched: true
        )
    }

    private func launchTrae(account: Account) -> SwitchOutcome {
        // 沿用该账号上次打开的项目，避免每次切换都要重新选择文件夹
        let workspace = trae.lastWorkspace(for: account.id)
        do {
            try trae.launchIsolated(account: account, workspace: workspace)
        } catch {
            return SwitchOutcome(
                result: .failed,
                headline: "启动 TRAE 独立实例失败",
                detail: error.localizedDescription,
                identityVerified: false,
                claimedIdentity: nil,
                manualSteps: [],
                failureAdvice: "可点击「打开官方应用」使用默认配置启动，或检查 TRAE 是否安装在 /Applications。",
                launched: false
            )
        }

        let hasSession = trae.hasPersistedSession(accountId: account.id)
        let workspaceNote = workspace.map { "已自动打开上次的项目：\($0.lastPathComponent)。" } ?? ""
        return SwitchOutcome(
            result: .unconfirmed,
            headline: hasSession ? "已启动 TRAE 独立实例" : "已启动 TRAE 独立实例，需要首次登录",
            detail: hasSession
                ? "该账号此前保存过登录会话，实例会尝试恢复。\(workspaceNote)本次未做身份验证，请确认窗口内显示的是目标账号。"
                : "这个账号的独立配置目录里还没有登录数据，请在刚打开的 TRAE 窗口中登录目标账号。\(workspaceNote)",
            identityVerified: false,
            claimedIdentity: nil,
            manualSteps: [
                "在刚打开的 TRAE 窗口中确认或登录目标账号",
                "核对窗口内显示的账号与目标账号一致",
                "回到本应用点击「我已核对并登录」"
            ],
            failureAdvice: nil,
            launched: true
        )
    }

    // MARK: - 身份核验

    private func verifyIdentity(account: Account, outcome: SwitchOutcome) -> SwitchOutcome {
        guard outcome.launched, account.platform == .trae else { return outcome }
        guard let identity = trae.verifyLoginIdentity() else { return outcome }

        return SwitchOutcome(
            result: .success,
            headline: "已启动 TRAE，身份已验证",
            detail: "通过 traecli 读取到当前登录身份：\(identity)",
            identityVerified: true,
            claimedIdentity: identity,
            manualSteps: [],
            failureAdvice: nil,
            launched: true
        )
    }

    // MARK: - 状态决策

    /// 根据真实证据决定切换后的登录状态。
    ///
    /// 规则（保证"状态"和"证据"一致）：
    /// - 未启动或失败：保持原状态，不制造任何"成功"痕迹。
    /// - 本次通过官方手段验证：写 `.verified`。
    /// - 上次是 `.verified` 但本次没验证：降级为 `.userConfirmed`
    ///   （验证只对当时那一刻有效，不能沿用）。
    /// - 已人工确认过：保留确认结果，但本次未核对会记入切换日志。
    /// - 其余情况：置为"等待核对"。
    public static func resolveStatus(
        current: LoginStatus,
        platform: Platform,
        launched: Bool,
        failed: Bool,
        identityVerified: Bool,
        hasPersistedSession: Bool
    ) -> LoginStatus {
        guard launched, !failed else { return current }
        if identityVerified { return .verified }
        if current == .verified {
            return .userConfirmed
        }
        if current.isConfirmed {
            // TRAE 依赖独立目录里的持久化会话；WorkBuddy 无法验证，保留此前确认结果
            return platform == .trae && !hasPersistedSession ? .pendingConfirmation : current
        }
        return .pendingConfirmation
    }

    private func resolveStatus(account: Account, outcome: SwitchOutcome) -> LoginStatus {
        let hasSession = account.platform == .trae
            && trae.hasPersistedSession(accountId: account.id)
        return Self.resolveStatus(
            current: account.lastLoginStatus,
            platform: account.platform,
            launched: outcome.launched,
            failed: outcome.result == .failed,
            identityVerified: outcome.identityVerified,
            hasPersistedSession: hasSession
        )
    }

    // MARK: - 状态提交

    private enum CommitResult {
        /// 已在单个事务内提交（含切换日志）。
        case committedAtomically
        /// 已逐项提交（未注入共享数据库的兼容路径），切换日志由 finish 写入。
        case committedIndividually
        /// 提交失败（事务已回滚，数据库未留下任何改动）。
        case failed(String)
    }

    /// 提交切换状态（Phase 1a-D）：登录状态、lastUsedAt、ProjectVisit、SwitchLog
    /// 是同一次切换的账目，注入共享数据库时在一个事务内落库；中途失败整体回滚，
    /// 不留半套状态。
    ///
    /// 注意：外部进程启动是不可回滚的真实副作用，事务只保证「账目」一致，
    /// 不声称能撤销已启动的应用。
    private func commitState(
        account: Account,
        fromStatus: LoginStatus,
        nextStatus: LoginStatus,
        outcome: SwitchOutcome
    ) -> CommitResult {
        let now = Date()
        // 工作区读取是无副作用的查询，放在事务外，避免在持锁期间做文件 IO
        let workspace: URL? = (outcome.launched && account.platform == .trae)
            ? trae.lastWorkspace(for: account.id)
            : nil

        // 兼容路径：未注入数据库（历史调用方），逐项写入并逐项容错。
        guard let database else {
            if nextStatus != fromStatus {
                do {
                    _ = try accountService.updateLoginStatus(id: account.id, status: nextStatus)
                } catch {
                    logger.error("更新登录状态失败: account=\(account.id.uuidString.prefix(8)) error=\(error.localizedDescription)")
                }
            }
            if outcome.launched {
                do {
                    _ = try accountService.markUsed(id: account.id, at: now)
                } catch {
                    logger.error("更新最近使用时间失败: account=\(account.id.uuidString.prefix(8)) error=\(error.localizedDescription)")
                }
                if let workspace {
                    do {
                        _ = try projectVisitService?.record(accountId: account.id, workspace: workspace, at: now)
                    } catch {
                        logger.error("记录项目打开失败: account=\(account.id.uuidString.prefix(8)) error=\(error.localizedDescription)")
                    }
                }
            }
            return .committedIndividually
        }

        // 事务路径：一次提交全部账目。
        do {
            try database.db.transaction { tx in
                if nextStatus != fromStatus {
                    try accountService.updateLoginStatus(tx, id: account.id, status: nextStatus)
                }
                if outcome.launched {
                    try accountService.markUsed(tx, id: account.id, at: now)
                    if let workspace {
                        try projectVisitService?.record(tx, accountId: account.id, workspace: workspace, at: now)
                    }
                }
                try switchLogService.log(
                    tx,
                    accountId: account.id,
                    fromStatus: fromStatus.rawValue,
                    toStatus: nextStatus.rawValue,
                    result: outcome.result,
                    errorMessage: outcome.result == .failed ? outcome.detail : nil
                )
            }
            return .committedAtomically
        } catch {
            logger.error("切换状态事务提交失败: account=\(account.id.uuidString.prefix(8)) error=\(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - 收尾

    /// 预检阶段失败的统一出口：不写成功痕迹，仍记录一次失败尝试。
    private func failedOutcome(
        account: Account,
        phase: SwitchPhase,
        detail: String,
        advice: String
    ) -> SwitchOutcome {
        finish(
            account: account,
            fromStatus: account.lastLoginStatus,
            outcome: SwitchOutcome(
                result: .failed,
                headline: "无法开始切换",
                detail: detail,
                identityVerified: false,
                claimedIdentity: nil,
                manualSteps: [],
                failureAdvice: advice,
                launched: false
            ),
            phase: .failed,
            failedAtPhase: phase
        )
    }

    /// 写入切换日志（事务路径已写时跳过）、记录阶段日志，并给结果盖上终态标记。
    private func finish(
        account: Account,
        fromStatus: LoginStatus,
        outcome: SwitchOutcome,
        nextStatus: LoginStatus? = nil,
        phase: SwitchPhase,
        failedAtPhase: SwitchPhase? = nil,
        logCommittedInTransaction: Bool = false
    ) -> SwitchOutcome {
        let toStatus = nextStatus ?? account.lastLoginStatus
        if !logCommittedInTransaction {
            do {
                _ = try switchLogService.log(
                    accountId: account.id,
                    fromStatus: fromStatus.rawValue,
                    toStatus: toStatus.rawValue,
                    result: outcome.result,
                    errorMessage: outcome.result == .failed ? outcome.detail : nil
                )
            } catch {
                logger.error("写入切换日志失败: account=\(account.id.uuidString.prefix(8)) error=\(error.localizedDescription)")
            }
        }
        if outcome.result == .failed {
            logger.error("切换未完成: account=\(account.id.uuidString.prefix(8)) phase=\(failedAtPhase.map { $0.rawValue } ?? "-") reason=\(outcome.detail)")
        } else {
            logger.info("切换完成: account=\(account.id.uuidString.prefix(8)) result=\(outcome.result.rawValue) verified=\(outcome.identityVerified)")
        }
        return outcome.stamped(phase: phase, failedAtPhase: failedAtPhase)
    }
}
