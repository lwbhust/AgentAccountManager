import Combine
import Foundation
import SwiftUI
import Core

/// 应用全局状态与装配层。
///
/// 领域状态与逻辑拆分在 Stores/ 下的各 Store（AccountStore / CreditStore /
/// TaskStore / RunningStore / QuickSwitchStore），服务统一由 ServiceRegistry
/// 装配（数据库重建时整体替换，Store 经 registry 取当前实例）。
/// 本类保留为兼容门面：转发既有公开 API（视图零改动），并把 Store 的
/// objectWillChange 统一转发，让 @EnvironmentObject AppState 订阅点不变；
/// 同时负责跨领域编排——列表刷新组合、账号启动/切换流程、后台刷新循环、
/// 小组件深链与数据管理。
@MainActor
public final class AppState: ObservableObject {
    // MARK: - 公共类型（保持既有 API 位置不变）

    /// 账号列表的显示范围（视图层筛选，不改变数据库）。
    public enum AccountFilter: String, CaseIterable, Identifiable, Sendable {
        case all, running

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .all: return "全部账号"
            case .running: return "运行中"
            }
        }

        /// 侧边栏分段控件使用的短标签。
        public var shortName: String {
            switch self {
            case .all: return "全部"
            case .running: return "运行中"
            }
        }
    }

    /// 账号列表排序方式。
    public enum AccountSort: String, CaseIterable, Identifiable, Sendable {
        case recent, name, favorite

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .recent: return "最近使用"
            case .name: return "账号名称"
            case .favorite: return "收藏优先"
            }
        }
    }

    /// 删除账号前的影响评估。
    public struct DeletionImpact {
        public let creditRecords: Int
        public let switchLogs: Int
        public let tasks: Int
        public let traeDataDir: Bool
        public let workstations: Int
        public let workstationNames: [String]
        public let isRunning: Bool
    }

    /// 最近打开的项目（账号信息卡展示用）。
    public struct RecentProject: Identifiable, Sendable {
        public let url: URL
        public let lastVisitedAt: Date
        /// nil 表示只从 TRAE 的活动时间推断，具体打开次数未知
        public let visitCount: Int?

        public var id: String { url.standardizedFileURL.path }
    }

    /// 侧边栏「最近项目」快捷入口：项目 + 所属账号，点击即可打开对应实例。
    public struct RecentProjectShortcut: Identifiable, Sendable {
        public let accountId: UUID
        public let accountName: String
        public let url: URL
        public let lastVisitedAt: Date

        public var id: String { accountId.uuidString + "|" + url.standardizedFileURL.path }
    }

    // MARK: - 全局提示与装配状态

    @Published public var errorMessage: String?
    @Published public var toast: String?
    @Published public private(set) var isDatabaseReady: Bool = false

    // MARK: - 领域 Store（惰性创建：默认值表达式可互相引用）

    private(set) lazy var registry = ServiceRegistry()
    private(set) lazy var accountStore = AccountStore()
    private(set) lazy var creditStore = CreditStore(registry: registry, logger: logger)
    private(set) lazy var taskStore = TaskStore(registry: registry, logger: logger)
    private(set) lazy var runningStore = RunningStore()
    private(set) lazy var quickSwitchStore = QuickSwitchStore(registry: registry, logger: logger)
    private lazy var logger = AppLogger(category: "app")

    private var autoRefreshTask: Task<Void, Never>?
    /// 正在启动的账号，防止同一账号重复拉起客户端。
    private var launchingAccountIds: Set<UUID> = []
    private var changeCancellables: Set<AnyCancellable> = []

    public init() {
        wireStores()
        do {
            try openDatabase()
        } catch {
            self.errorMessage = "数据库初始化失败: \(error.localizedDescription)"
        }
    }

    /// 注入指定数据库（用于测试与预览，避免触碰真实数据库文件）。
    public init(database: DatabaseService) throws {
        wireStores()
        try install(database)
    }

    /// 建立 Store 之间的注入点与 objectWillChange 转发（两个初始化路径共用）。
    private func wireStores() {
        accountStore.isRunningProvider = { [weak self] account in
            self?.runningStore.isRunning(account) ?? false
        }
        // 运行状态异步更新完成后同步小组件快照
        runningStore.onUpdate = { [weak self] in self?.refreshWidgetSnapshot() }
        // Store 的变化统一转发，既有视图只订阅 AppState
        forwardChange(from: accountStore)
        forwardChange(from: creditStore)
        forwardChange(from: taskStore)
        forwardChange(from: runningStore)
        forwardChange(from: quickSwitchStore)
    }

    private func forwardChange<P: ObservableObject>(from store: P) where P.ObjectWillChangePublisher == ObservableObjectPublisher {
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &changeCancellables)
    }

    // MARK: - 数据库装配

    private func openDatabase() throws {
        try install(try DatabaseService())
    }

    /// 用指定数据库完成装配：重建服务、清理过期记录并首载账号列表。
    private func install(_ db: DatabaseService) throws {
        registry.install(db)
        self.isDatabaseReady = true
        accountStore.loadFavorites()
        // 控制表体积：只保留最近 90 天的项目打开记录（展示只用 3 天）
        do {
            _ = try registry.projectVisitService?.prune(olderThan: Date(timeIntervalSinceNow: -90 * 24 * 3600))
        } catch {
            logger.error("清理过期项目打开记录失败: \(error.localizedDescription)")
        }
        try reload()
    }

    /// 重新加载账号列表（保持当前选中项仍然有效），
    /// 并联动刷新预计余额、运行状态与最近项目。
    public func reload() throws {
        guard registry.accountService != nil else { return }
        try accountStore.reload(service: registry.accountService)
        creditStore.refreshBalances(for: accountStore.accounts)
        refreshRunningState()
        refreshRecentProjects()
    }

    /// 启动唯一的后台刷新循环，供主窗口与工作台窗口共同调用。
    ///
    /// 刷新内容与原先 `ContentView.task` 一致：运行状态 + 任务采集，每 5 秒一次。
    public func startAutoRefreshIfNeeded() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshRunningState()
                await self.collectTraeTasks()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: - 兼容门面：账号列表状态（真实来源 AccountStore）

    public var accounts: [Account] { accountStore.accounts }
    public var selectedPlatform: Platform? {
        get { accountStore.selectedPlatform }
        set { accountStore.selectedPlatform = newValue }
    }
    public var selectedAccountId: UUID? {
        get { accountStore.selectedAccountId }
        set { accountStore.selectedAccountId = newValue }
    }
    public var searchText: String {
        get { accountStore.searchText }
        set { accountStore.searchText = newValue }
    }
    public var isSearchPresented: Bool {
        get { accountStore.isSearchPresented }
        set { accountStore.isSearchPresented = newValue }
    }
    public var accountFilter: AccountFilter {
        get { accountStore.accountFilter }
        set { accountStore.accountFilter = newValue }
    }
    public var accountSort: AccountSort {
        get { accountStore.accountSort }
        set { accountStore.accountSort = newValue }
    }
    public var favoriteAccountIds: Set<UUID> { accountStore.favoriteAccountIds }
    /// 账号数据版本号：账号新增/编辑/删除/登录核对后递增，工作台据此刷新。
    public var accountRevision: Int { accountStore.revision }

    /// 当前平台 + 显示范围 + 搜索关键字过滤后的账号，并按所选方式排序。
    public var filteredAccounts: [Account] { accountStore.filteredAccounts }

    public var selectedAccount: Account? { accountStore.selectedAccount }

    public func account(id: UUID) -> Account? {
        accountStore.account(id: id)
    }

    /// 跨窗口导航：选中指定账号；如果它被当前筛选或搜索挡住，先恢复可见范围。
    ///
    /// 只在用户显式点击「在账号管理器中查看」时调用，后台同步不使用。
    public func selectAccount(id: UUID) {
        accountStore.selectAccount(id: id)
    }

    /// 指定平台下的账号数量（nil 表示全部）。
    public func count(of platform: Platform?) -> Int {
        accountStore.count(of: platform)
    }

    // MARK: - 兼容门面：运行状态（真实来源 RunningStore）

    /// 正在运行的 TRAE 独立实例对应的账号 ID（按 `--user-data-dir` 区分）。
    public var runningTraeAccountIds: Set<UUID> { runningStore.runningTraeAccountIds }
    /// WorkBuddy 客户端是否在运行（平台级，无法区分账号）。
    public var isWorkBuddyAppRunning: Bool { runningStore.isWorkBuddyAppRunning }

    /// 刷新「哪些账号的 TRAE 独立实例正在运行」。
    ///
    /// 这是一次外部进程查询（`ps`），只应在 `reload()`、切换完成后、
    /// 应用激活或定时刷新时调用，渲染路径不得直接调用。
    public func refreshRunningState() {
        runningStore.refresh(traeService: registry.traeService)
    }

    /// 账号是否处于「运行中」。
    /// TRAE 按账号实例判断；WorkBuddy 只有一个客户端，只能按平台级提示。
    public func isRunning(_ account: Account) -> Bool {
        runningStore.isRunning(account)
    }

    // MARK: - 兼容门面：任务采集（真实来源 TaskStore）

    /// 任务采集版本号：有新任务或消耗更新时递增，详情页据此重新加载。
    public var taskRevision: Int { taskStore.revision }
    /// 各账号的任务采集诊断（最近扫描、最近成功解析、格式异常等）。
    public var taskDiagnostics: [UUID: TraeTaskScanDiagnostics] { taskStore.diagnostics }
    /// 最近一次后台采集完成的时间。
    public var lastTaskCollectionAt: Date? { taskStore.lastCollectionAt }
    /// 最近一次采集的六元组统计（发现/解析/新增/更新/跳过/失败），
    /// 用于区分「没有新任务」和「采集出现问题」。
    public var lastCollectionStats: TraeTaskCollectionStats? { taskStore.lastCollectionStats }

    /// 采集 TRAE 本地日志里的任务与单任务积分消耗；有实际写入时联动刷新预计余额。
    public func collectTraeTasks() async {
        let ids = accountStore.accounts.filter { $0.platform == .trae }.map(\.id)
        let changed = await taskStore.collect(traeAccountIds: ids)
        if changed > 0 {
            creditStore.refreshBalances(for: accountStore.accounts)
        }
    }

    public func taskHistory(for accountId: UUID, limit: Int = 50, offset: Int = 0) -> [TraeTask] {
        taskStore.history(for: accountId, limit: limit, offset: offset)
    }

    /// 某账号最新一条任务（工作台工位卡片摘要用）。
    public func latestTask(for accountId: UUID) -> TraeTask? {
        taskStore.latest(for: accountId)
    }

    public func taskCount(for accountId: UUID) -> Int {
        taskStore.count(for: accountId)
    }

    /// 某时间之后解析出的任务积分消耗合计（来自日志，不是官方余额）。
    public func taskCreditsConsumed(for accountId: UUID, since: Date) -> Double? {
        taskStore.creditsConsumed(for: accountId, since: since)
    }

    // MARK: - 兼容门面：积分（真实来源 CreditStore）

    /// 各账号的预计余额（最近一次录入 − 之后的任务消耗），随账号列表与任务采集刷新。
    public var creditBalances: [UUID: CreditBalanceEstimate] { creditStore.balances }

    /// 重新计算各账号的预计余额（基准余额减去之后的任务消耗）。
    public func refreshCreditBalances() {
        creditStore.refreshBalances(for: accountStore.accounts)
    }

    /// 该账号的预计余额；还没有成功录入过余额时为 nil。
    public func creditBalance(for accountId: UUID) -> CreditBalanceEstimate? {
        creditStore.balance(for: accountId)
    }

    /// 界面上展示的当前积分：有预计余额时优先用它，否则退回最近录入值。
    public func displayedCredits(for account: Account) -> Double? {
        creditStore.displayedCredits(for: account)
    }

    public func creditHistory(for accountId: UUID, limit: Int = 50, offset: Int = 0) -> [CreditSnapshot] {
        creditStore.history(for: accountId, limit: limit, offset: offset)
    }

    public func creditHistoryCount(for accountId: UUID) -> Int {
        creditStore.historyCount(for: accountId)
    }

    public var staleInterval: TimeInterval {
        creditStore.staleInterval
    }

    // MARK: - 兼容门面：服务装配（真实来源 ServiceRegistry）

    public var database: DatabaseService? { registry.database }
    public var accountService: AccountService? { registry.accountService }
    public var creditService: CreditService? { registry.creditService }
    public var switchLogService: SwitchLogService? { registry.switchLogService }
    public var switchService: SwitchService? { registry.switchService }
    public var taskService: TraeTaskService? { registry.taskService }
    public var projectVisitService: ProjectVisitService? { registry.projectVisitService }
    public var projectService: ProjectService? { registry.projectService }
    public var workstationService: WorkstationService? { registry.workstationService }
    public var workbenchService: WorkbenchService? { registry.workbenchService }
    public var keychain: KeychainService { registry.keychain }
    public var traeService: TraeService { registry.traeService }

    // MARK: - 收藏与状态

    /// 该账号是否被收藏（视图层快捷标记，不写入账号表）。
    public func isFavorite(_ accountId: UUID) -> Bool {
        accountStore.isFavorite(accountId)
    }

    /// 切换收藏状态；收藏变化会立即影响列表排序与筛选，并同步小组件快照。
    public func toggleFavorite(_ accountId: UUID) {
        accountStore.toggleFavorite(accountId)
        refreshWidgetSnapshot()
    }

    /// 需要用户处理的状态原因（用于列表徽标与「待处理」筛选）。
    public func attentionReasons(for account: Account) -> [String] {
        var reasons: [String] = []
        if account.lastLoginStatus == .pendingConfirmation {
            reasons.append("登录待核对")
        }
        if account.platform == .workbuddy,
           conflictingWorkBuddyAccountIds.contains(account.id) {
            reasons.append("确认冲突")
        }
        if account.hasCreditRecord, account.isCreditStale(within: staleInterval) {
            reasons.append("积分记录过期")
        }
        if let estimate = creditBalances[account.id], estimate.estimatedCredits < 0 {
            reasons.append("余额需校准")
        }
        if let diagnostics = taskDiagnostics[account.id], diagnostics.hasIssue {
            reasons.append("任务采集异常")
        }
        return reasons
    }

    // MARK: - 桌面小组件与快速切换

    /// 桌面快速切换小部件的账号排序：收藏优先，其次运行中的 TRAE 实例，
    /// 最后按最近使用时间；其余情况按平台与名称稳定排列。
    ///
    /// 只读缓存，不查询进程或数据库，可在 SwiftUI 渲染路径使用。
    public var quickSwitchAccounts: [Account] {
        quickSwitchStore.quickSwitchAccounts(
            accounts: accounts,
            favorites: favoriteAccountIds,
            runningTraeAccountIds: runningTraeAccountIds
        )
    }

    /// 把小组件渲染所需的只读快照写入共享 JSON，并通知 WidgetKit 刷新。
    /// 只透传原始数据；排序与组装统一在 Core 的 QuickSwitchSnapshotBuilder。
    public func refreshWidgetSnapshot() {
        quickSwitchStore.refreshWidgetSnapshot(QuickSwitchStore.WidgetContext(
            accounts: accounts,
            favorites: favoriteAccountIds,
            runningTraeAccountIds: runningTraeAccountIds,
            isWorkBuddyRunning: runningStore.isWorkBuddyAppRunning,
            recentProjectShortcuts: recentProjectShortcuts,
            isDatabaseReady: isDatabaseReady
        ))
    }

    /// 侧边栏「最近项目」快捷入口：项目 + 所属账号，点击即可打开对应实例。
    public var recentProjectShortcuts: [RecentProjectShortcut] {
        quickSwitchStore.recentProjectShortcuts
    }

    /// 重新计算侧边栏的最近项目入口，并同步小组件快照。
    ///
    /// 读取文件系统有一定成本，只在列表重新加载或应用回到前台时调用，
    /// 不在 SwiftUI 渲染路径中计算。
    public func refreshRecentProjects() {
        quickSwitchStore.refreshRecentProjects(for: accounts)
        refreshWidgetSnapshot()
    }

    /// 合并两类来源，得到最近一段时间打开过的项目：
    /// 1. 本应用精确记录的打开事件（含次数）
    /// 2. TRAE 隔离目录里 `workspace.json` 的最近活动时间（近似）
    public func recentProjects(
        for account: Account,
        within interval: TimeInterval = 3 * 24 * 3600,
        limit: Int = 20
    ) -> [RecentProject] {
        quickSwitchStore.recentProjects(for: account, within: interval, limit: limit)
    }

    /// 处理桌面小组件点击产生的深链。
    ///
    /// 小组件运行在独立进程，点击只能通过 URL 唤起主应用；
    /// 这里重新做一次账号/目录校验，再走与主界面相同的打开逻辑。
    @discardableResult
    public func handleWidgetDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == WidgetDeepLink.scheme else { return false }
        guard let action = WidgetDeepLink.parse(url) else {
            // agentaccountmanager://open 只负责唤起 App。
            return url.host?.lowercased() == "open"
        }

        let now = Date()
        if let lastHandled = lastHandledWidgetDeepLink,
           lastHandled.url == url,
           now.timeIntervalSince(lastHandled.at) < 1.0 {
            return false
        }
        lastHandledWidgetDeepLink = (url, now)

        switch action {
        case .account(let id):
            guard let account = account(id: id) else {
                toast = "小组件指向的账号已不存在"
                return false
            }
            do {
                let activated = try openAccountQuickly(account)
                toast = activated ? "已激活「\(account.displayName)」" : "已打开「\(account.displayName)」"
                return true
            } catch {
                errorMessage = "打开账号失败：\(error.localizedDescription)"
                return false
            }

        case .project(let accountId, let path):
            guard let account = account(id: accountId) else {
                toast = "小组件项目的所属账号已不存在"
                return false
            }
            let workspace = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: workspace.path) else {
                toast = "项目目录已不存在：\(workspace.lastPathComponent)"
                return false
            }
            do {
                let activated = try openAccountApp(
                    account,
                    workspace: workspace,
                    visitSource: "widget"
                )
                toast = activated
                    ? "已激活「\(account.displayName)」· \(workspace.lastPathComponent)"
                    : "已打开「\(account.displayName)」· \(workspace.lastPathComponent)"
                return true
            } catch {
                errorMessage = "打开项目失败：\(error.localizedDescription)"
                return false
            }
        }
    }

    /// 防止主窗口与工作台同时收到同一个深链时重复执行。
    private var lastHandledWidgetDeepLink: (url: URL, at: Date)?

    // MARK: - 账号操作

    public func addAccount(
        platform: Platform,
        displayName: String,
        phoneMasked: String,
        fullPhone: String?,
        planType: String?,
        note: String?
    ) throws {
        guard let service = accountService else { throw AppError.databaseUnavailable }
        let phoneHash = fullPhone.map { Masking.phoneHash($0) }
        let account = try service.create(
            platform: platform,
            displayName: displayName,
            phoneMasked: phoneMasked,
            phoneHash: phoneHash,
            planType: planType,
            note: note
        )
        var keychainSaved = false
        if let phone = fullPhone, !phone.isEmpty {
            keychainSaved = keychain.setPhone(phone, for: account.id)
        }
        try reload()
        selectedAccountId = account.id
        if fullPhone?.isEmpty == false {
            toast = keychainSaved
                ? "账号已创建，完整手机号已存入 macOS 钥匙串"
                : "账号已创建，但完整手机号未能写入钥匙串"
        } else {
            toast = "账号已创建"
        }
    }

    public func updateAccount(
        id: UUID,
        displayName: String,
        note: String?,
        planType: String?,
        fullPhone: String?
    ) throws {
        guard let service = accountService else { throw AppError.databaseUnavailable }
        try service.update(id: id, displayName: displayName, note: note, planType: planType)
        if let phone = fullPhone, !phone.isEmpty {
            _ = keychain.setPhone(phone, for: id)
            try service.updatePhone(
                id: id,
                phoneMasked: Masking.maskPhone(phone),
                phoneHash: Masking.phoneHash(phone)
            )
        }
        try reload()
        toast = "账号信息已保存"
    }

    public func deletionImpact(for account: Account) -> DeletionImpact {
        var credits = 0
        var logs = 0
        var tasks = 0
        var workstationNames: [String] = []
        do {
            credits = try creditService?.count(for: account.id) ?? 0
            logs = try switchLogService?.count(for: account.id) ?? 0
            tasks = try taskService?.count(for: account.id) ?? 0
        } catch {
            logger.error("统计删除影响失败: account=\(account.id.uuidString.prefix(8)) error=\(error.localizedDescription)")
        }
        do {
            let refs = try workstationService?.references(forAccountId: account.id) ?? []
            workstationNames = refs.map { "\($0.projectName) / \($0.workstationName)" }
        } catch {
            logger.error("统计工位引用失败: account=\(account.id.uuidString.prefix(8)) error=\(error.localizedDescription)")
        }
        let hasDir = account.platform == .trae && traeService.hasUserDataDir(for: account.id)
        return DeletionImpact(
            creditRecords: credits,
            switchLogs: logs,
            tasks: tasks,
            traeDataDir: hasDir,
            workstations: workstationNames.count,
            workstationNames: workstationNames,
            isRunning: isRunning(account)
        )
    }

    public func deleteAccount(id: UUID) throws {
        guard let service = accountService else { throw AppError.databaseUnavailable }
        if let account = account(id: id), account.platform == .trae {
            traeService.removeUserDataDir(for: id)
        }
        keychain.deletePhone(for: id)
        try service.delete(id: id)
        if selectedAccountId == id {
            selectedAccountId = nil
        }
        try reload()
        toast = "账号及其关联记录已删除"
    }

    // MARK: - 积分录入

    public func recordManualCredits(
        accountId: UUID,
        credits: Int,
        totalCredits: Int?,
        creditType: String?,
        observedAt: Date,
        announce: Bool = true
    ) throws {
        guard let service = creditService else { throw AppError.databaseUnavailable }
        try service.recordManualEntry(
            accountId: accountId,
            credits: credits,
            totalCredits: totalCredits,
            creditType: creditType,
            observedAt: observedAt
        )
        try reload()
        if announce {
            toast = "积分已保存，之后的任务消耗会从这里实时扣减"
        }
    }

    // MARK: - 切换

    /// 执行账号切换，返回切换结果与提示信息。
    public func switchAccount(_ account: Account) -> SwitchService.SwitchOutcome? {
        guard let service = switchService else { return nil }
        let outcome = service.switchTo(account: account)
        reloadAfterMutation(failurePrefix: "切换后刷新账号列表失败")
        return outcome
    }

    /// 用户核对官方界面后手动确认登录。
    public func confirmLogin(_ account: Account) {
        switchService?.confirmLogin(account: account)
        reloadAfterMutation(failurePrefix: "确认后刷新账号列表失败")
        toast = "已记录你的确认结果"
    }

    /// 标记为「已确认」但互相冲突的 WorkBuddy 账号。
    ///
    /// WorkBuddy 只有一个客户端实例，同一时刻只可能登录一个账号；
    /// 如果多个 WorkBuddy 账号都保存了确认结果，说明这些确认不可能同时成立。
    /// 这里只做提示，不自动改写用户填过的状态。
    public var conflictingWorkBuddyAccountIds: Set<UUID> {
        let confirmed = accounts.filter {
            $0.platform == .workbuddy && $0.lastLoginStatus.isConfirmed
        }
        guard confirmed.count > 1 else { return [] }
        return Set(confirmed.map(\.id))
    }

    /// 把其他 WorkBuddy 账号的确认结果标记为「未记录」。
    ///
    /// 由用户主动触发（详情页冲突提示里的按钮），不做静默改写。
    public func unconfirmOtherWorkBuddyAccounts(except id: UUID) {
        guard let service = accountService else { return }
        let others = accounts.filter {
            $0.platform == .workbuddy && $0.id != id && $0.lastLoginStatus.isConfirmed
        }
        guard !others.isEmpty else { return }
        do {
            for other in others {
                _ = try service.updateLoginStatus(id: other.id, status: .unknown)
            }
            try reload()
            toast = "其他 WorkBuddy 账号已标记为未核对"
        } catch {
            logger.error("清理其他 WorkBuddy 确认状态失败: \(error.localizedDescription)")
            errorMessage = "清理其他 WorkBuddy 确认状态失败：\(error.localizedDescription)"
        }
    }

    private func reloadAfterMutation(failurePrefix: String) {
        do {
            try reload()
        } catch {
            logger.error("\(failurePrefix): \(error.localizedDescription)")
            errorMessage = "\(failurePrefix)：\(error.localizedDescription)"
        }
    }

    public func switchHistory(for accountId: UUID, limit: Int = 50, offset: Int = 0) -> [SwitchLog] {
        (try? switchLogService?.history(for: accountId, limit: limit, offset: offset)) ?? []
    }

    public func switchHistoryCount(for accountId: UUID) -> Int {
        (try? switchLogService?.count(for: accountId)) ?? 0
    }

    /// 查找使用了相同完整手机号的其他账号（表单查重提示，不禁止保存）。
    public func duplicatePhoneAccounts(fullPhone: String, excluding id: UUID? = nil) -> [Account] {
        let hash = Masking.phoneHash(fullPhone)
        let matches = (try? accountService?.find(byPhoneHash: hash)) ?? []
        return matches.filter { $0.id != id }
    }

    // MARK: - 项目与启动

    /// TRAE 账号上次打开的项目（来自该账号自己的独立配置目录）。
    public func lastWorkspace(for account: Account) -> URL? {
        guard account.platform == .trae else { return nil }
        return traeService.lastWorkspace(for: account.id)
    }

    /// TRAE 账号运行中实例当前打开的所有项目（最近活跃的在前）。
    public func openWorkspaces(for account: Account) -> [URL] {
        guard account.platform == .trae else { return [] }
        return traeService.openWorkspaces(for: account.id)
    }

    /// 打开该账号对应的官方客户端。
    ///
    /// - TRAE：使用该账号自己的 `--user-data-dir` 实例，不再打开默认实例；
    ///   传入 `workspace` 时在该实例中打开指定项目，为 nil 时启动空白窗口。
    ///   若该账号实例已经在运行且已有窗口（目标项目也已打开），则直接激活
    ///   原实例，避免重复拉起 `trae-cn` 产生一个短命的转发进程。
    /// - WorkBuddy：只有一个实例，只能唤醒应用。
    /// - Parameter visitSource: 记录项目打开来源，默认 "app"；工作台传 "workbench"。
    /// - Returns: 是否只是激活了已在运行的实例（没有重新启动客户端）。
    @discardableResult
    public func openAccountApp(
        _ account: Account,
        workspace: URL?,
        visitSource: String = "app"
    ) throws -> Bool {
        guard !launchingAccountIds.contains(account.id) else {
            throw AppError.launchInProgress
        }
        launchingAccountIds.insert(account.id)
        defer { launchingAccountIds.remove(account.id) }

        let activated: Bool
        if account.platform == .trae {
            // 运行中的实例只激活，不再启动 CLI；目标项目未打开时才需要真正启动一次
            if traeService.activateRunningInstance(for: account.id, workspace: workspace) {
                activated = true
            } else {
                try traeService.launchIsolated(account: account, workspace: workspace)
                activated = false
            }
        } else {
            NSWorkspace.shared.open(
                account.platform.installedApplicationURL ?? account.platform.applicationURL
            )
            activated = false
        }
        recordProjectVisit(account: account, workspace: workspace, source: visitSource)
        _ = try? accountService?.markUsed(id: account.id)
        reloadAfterMutation(failurePrefix: "打开账号后刷新列表失败")
        return activated
    }

    /// 账号「一键打开」时要恢复的项目：优先上次项目，其次最近项目。
    ///
    /// 没有可用项目时返回 nil，调用方会打开空白窗口。
    public func quickOpenWorkspace(for account: Account) -> URL? {
        guard account.platform == .trae else { return nil }
        if let last = lastWorkspace(for: account),
           FileManager.default.fileExists(atPath: last.path) {
            return last
        }
        return recentProjects(for: account, limit: 1).first?.url
    }

    /// 主操作：一次点击恢复上次项目并打开/激活该账号实例。
    @discardableResult
    public func openAccountQuickly(_ account: Account) throws -> Bool {
        try openAccountApp(account, workspace: quickOpenWorkspace(for: account))
    }

    /// 菜单命令「打开所选账号」（⌘↩）。
    public func openSelectedAccount() {
        guard let account = selectedAccount else {
            toast = "请先选择一个账号"
            return
        }
        do {
            let activated = try openAccountQuickly(account)
            toast = activated ? "已激活该账号的运行中窗口" : "已打开该账号窗口"
        } catch {
            errorMessage = "打开账号失败：\(error.localizedDescription)"
        }
    }

    /// 菜单命令「收藏/取消收藏所选账号」（⌘D）。
    public func toggleFavoriteSelected() {
        guard let account = selectedAccount else { return }
        toggleFavorite(account.id)
        toast = isFavorite(account.id) ? "已收藏「\(account.displayName)」" : "已取消收藏"
    }

    /// 记录用户通过本应用打开的项目（只用于「最近打开」，不作为登录证据）。
    private func recordProjectVisit(account: Account, workspace: URL?, source: String = "app") {
        guard let workspace else { return }
        do {
            _ = try projectVisitService?.record(
                accountId: account.id,
                workspace: workspace,
                at: Date(),
                source: source
            )
        } catch {
            logger.error("记录项目打开失败: account=\(account.id.uuidString.prefix(8)) error=\(error.localizedDescription)")
        }
    }

    /// 平台官方应用是否可用（nil 表示可用）。
    public func installProblem(for platform: Platform) -> String? {
        switchService?.installProblem(for: platform)
    }

    // MARK: - 数据管理（设置页使用）

    public var databasePath: String {
        database?.databaseURL.path ?? "—"
    }

    public var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    public var dataCounts: (accounts: Int, credits: Int, switches: Int, tasks: Int) {
        (
            accounts.count,
            (try? creditService?.countAll()) ?? 0,
            (try? switchLogService?.countAll()) ?? 0,
            (try? taskService?.countAll()) ?? 0
        )
    }

    /// 已建立独立配置目录的 TRAE 账号数量（清空数据提示用）。
    public var traeUserDataDirCount: Int {
        accounts.filter { $0.platform == .trae && traeService.hasUserDataDir(for: $0.id) }.count
    }

    /// 导出 CSV 文本；不包含手机号或任何认证信息。
    public func exportCSV(
        type: CSVExportType,
        accountId: UUID?,
        since: Date?
    ) throws -> String {
        switch type {
        case .tasks:
            let rows = try taskService?.allRows(accountId: accountId, since: since) ?? []
            return CSVExport.taskCSV(rows)
        case .credits:
            let rows = try creditService?.allRows(accountId: accountId, since: since) ?? []
            return CSVExport.creditCSV(rows)
        }
    }

    @discardableResult
    public func backupDatabase(to directory: URL) throws -> URL {
        guard let db = database else { throw AppError.databaseUnavailable }
        return try BackupRestore(database: db, keychain: keychain).backup(to: directory)
    }

    /// 从备份恢复：校验 → 自动安全备份 → 覆盖当前数据库 → 重建服务。
    /// - Returns: 恢复前自动生成的安全备份路径。
    @discardableResult
    public func restoreDatabase(from backupURL: URL) throws -> URL {
        guard let db = database else { throw AppError.databaseUnavailable }
        let safety = try BackupRestore(database: db, keychain: keychain).restore(from: backupURL)
        try install(try DatabaseService())
        selectedAccountId = nil
        toast = "已从备份恢复"
        return safety
    }

    /// 清空所有本地数据（数据库、切换/积分记录、钥匙串中的手机号）。
    public func wipeAllLocalData() throws {
        guard let db = database else { throw AppError.databaseUnavailable }
        try BackupRestore(database: db, keychain: keychain).deleteAllData()
        try install(try DatabaseService())
        selectedAccountId = nil
        toast = "本地数据已清空"
    }
}

public enum AppError: Error, LocalizedError {
    case databaseUnavailable
    case launchInProgress

    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable: return "数据库不可用，请重启应用后重试。"
        case .launchInProgress: return "该账号正在启动，请稍候再试。"
        }
    }
}
