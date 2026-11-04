import SwiftUI
import AppKit
import Core

/// 账号详情页容器：持有分区状态、刷新与动作，组合 Detail/ 目录下的分区视图。
///
/// 性能约束：body 渲染期间不做任何同步 IO（文件读取、NSWorkspace 查询、
/// 安装检测）。所有依赖外部状态的数据都在 `refresh()` 中计算并写入
/// @State，由 `.task` 与操作回调触发刷新。
/// 分区视图（Views/Detail/）为纯展示层：不做 IO、不做额度计算、不做切换事务。
struct AccountDetailView: View {
    @EnvironmentObject private var appState: AppState
    let account: Account

    /// 历史记录每页加载条数
    private static let pageSize = 50
    /// 折叠状态下首屏展示的条数
    private static let creditPreviewCount = 8
    private static let switchPreviewCount = 6
    private static let taskPreviewCount = 6

    @State private var showingEdit = false
    @State private var showingCreditEntry = false
    @State private var showingSwitchFlow = false
    @State private var showingDeleteConfirm = false
    @State private var deletionImpact: AppState.DeletionImpact?
    @State private var creditHistory: [CreditSnapshot] = []
    @State private var creditTotal = 0
    @State private var switchHistory: [SwitchLog] = []
    @State private var switchTotal = 0
    @State private var tasks: [TraeTask] = []
    @State private var taskTotal = 0
    @State private var taskTodayCredits: Double?
    @State private var installProblem: String?
    @State private var hasTraeDataDir = false
    @State private var openWorkspaces: [URL] = []
    @State private var recentProjects: [AppState.RecentProject] = []
    @State private var showingAllHistory = false
    @State private var showingAllSwitches = false
    @State private var showingAllTasks = false
    @State private var message: DetailMessage?
    @State private var tab: DetailTab = .overview
    @State private var collecting = false

    /// 详情内容的最大宽度：宽窗口不再把内容挤在中间，而是让卡片随窗口展开；
    /// 超过该宽度时保持一行可读的宽度，避免超宽屏上文字行过长。
    private static let contentMaxWidth: CGFloat = 1240

    /// 详情页按日常使用顺序分区：先看状态与项目，再看消耗，最后翻历史。
    enum DetailTab: String, CaseIterable, Identifiable {
        case overview, credits, history

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "概览"
            case .credits: return "积分与任务"
            case .history: return "历史记录"
            }
        }
    }

    struct DetailMessage: Identifiable {
        let id = UUID()
        let kind: InlineBanner.Kind
        let text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailHeader(
                account: account,
                statusChip: statusChip,
                runningChip: runningChip,
                isFavorite: appState.isFavorite(account.id),
                onToggleFavorite: { appState.toggleFavorite(account.id) },
                onEdit: { showingEdit = true },
                onDelete: prepareDelete
            )

            banners

            DetailActionBar(
                platform: account.platform,
                installProblem: installProblem,
                openWorkspaces: openWorkspaces,
                isInstanceRunning: appState.runningTraeAccountIds.contains(account.id),
                quickWorkspace: appState.quickOpenWorkspace(for: account),
                onSwitch: { showingSwitchFlow = true },
                onRecordCredit: { showingCreditEntry = true },
                onOpenApp: openApp,
                onQuickOpen: {
                    do {
                        let activated = try appState.openAccountQuickly(account)
                        message = DetailMessage(
                            kind: .info,
                            text: activated ? "已激活该账号的运行中窗口" : "已打开该账号窗口"
                        )
                        refresh()
                    } catch {
                        message = DetailMessage(kind: .error, text: error.localizedDescription)
                    }
                }
            )

            TranslucentSegment(
                items: DetailTab.allCases.map {
                    TranslucentSegmentItem(value: $0, label: $0.title)
                },
                selection: $tab
            )
            .frame(maxWidth: 360, alignment: .leading)

            Divider()

            ScrollView {
                tabContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 分割线高度参与 VStack 布局时为 1pt，上下各 10pt，保证线两侧留白一致；
            // 不要再给滚动内容加额外上内边距，否则线下方会比上方更宽。
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: account.updatedAt) {
            refresh()
        }
        .onChange(of: appState.taskRevision) { _, _ in
            // 后台采集到新任务或消耗变化时刷新列表
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 用户从 TRAE 切回本应用时，重新读取运行实例的项目与状态
            refresh()
        }
        .sheet(isPresented: $showingEdit) {
            AccountFormView(mode: .edit(account))
        }
        .sheet(isPresented: $showingCreditEntry) {
            CreditEntryView(account: account)
        }
        .sheet(isPresented: $showingSwitchFlow, onDismiss: { refresh() }) {
            SwitchFlowView(account: account) { text, kind in
                message = DetailMessage(kind: kind, text: text)
            }
        }
        .confirmationDialog(
            "删除账号「\(account.displayName)」？",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除并清理本地数据", role: .destructive) { performDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deletionMessage)
        }
    }

    // MARK: - 分区内容

    @ViewBuilder
    private var banners: some View {
        if isWorkBuddyConflict {
            VStack(alignment: .leading, spacing: 6) {
                InlineBanner(
                    kind: .warning,
                    text: "WorkBuddy 同一客户端同一时刻只能登录一个账号。"
                        + "另外还有 \(conflictingNames) 也标记为已确认，这些确认不可能同时成立，请以官方界面为准重新核对。"
                )
                Button("把其他 WorkBuddy 账号标记为未核对") {
                    appState.unconfirmOtherWorkBuddyAccounts(except: account.id)
                    message = DetailMessage(kind: .success, text: "其他 WorkBuddy 账号已标记为未核对。")
                }
                .controlSize(.small)
            }
        }
        if account.lastLoginStatus == .pendingConfirmation {
            PendingConfirmationCard(
                platformName: account.platform.displayName,
                onConfirm: {
                    appState.confirmLogin(account)
                    message = DetailMessage(kind: .success, text: "已记录你的确认结果。")
                },
                onReswitch: { showingSwitchFlow = true }
            )
        }
        if let installProblem {
            InlineBanner(kind: .warning, text: installProblem + " 切换功能暂不可用。")
        }
        if let message {
            InlineBanner(kind: message.kind, text: message.text)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .overview:
            AccountOverviewSection(
                account: account,
                estimate: appState.creditBalance(for: account.id),
                hasTraeDataDir: hasTraeDataDir,
                openWorkspaces: openWorkspaces,
                recentProjects: recentProjects,
                isInstanceRunning: appState.runningTraeAccountIds.contains(account.id),
                onOpenWorkspace: { url in openApp(workspace: url) },
                onRecordCredit: { showingCreditEntry = true }
            )
        case .credits:
            AccountCreditSection(
                account: account,
                estimate: appState.creditBalance(for: account.id),
                staleInterval: appState.staleInterval,
                diagnostics: appState.taskDiagnostics[account.id],
                lastCollectionAt: appState.lastTaskCollectionAt,
                isCollecting: collecting,
                tasks: tasks,
                taskTotal: taskTotal,
                taskTodayCredits: taskTodayCredits,
                hasBalanceBaseline: appState.creditBalance(for: account.id) != nil,
                taskPreviewCount: Self.taskPreviewCount,
                showingAllTasks: $showingAllTasks,
                onLoadMoreTasks: loadMoreTasks,
                onRecordCredit: { showingCreditEntry = true },
                onCollect: { collectNow() }
            )
        case .history:
            AccountHistorySection(
                creditHistory: creditHistory,
                creditTotal: creditTotal,
                creditPreviewCount: Self.creditPreviewCount,
                showingAllCreditHistory: $showingAllHistory,
                onLoadMoreCredits: loadMoreCredits,
                switchHistory: switchHistory,
                switchTotal: switchTotal,
                switchPreviewCount: Self.switchPreviewCount,
                showingAllSwitches: $showingAllSwitches,
                onSwitch: { showingSwitchFlow = true },
                onLoadMoreSwitches: loadMoreSwitches
            )
        }
    }

    // MARK: - 数据加载（仅此处允许 IO）

    private func refresh() {
        creditTotal = appState.creditHistoryCount(for: account.id)
        switchTotal = appState.switchHistoryCount(for: account.id)
        creditHistory = appState.creditHistory(for: account.id, limit: Self.pageSize)
        switchHistory = appState.switchHistory(for: account.id, limit: Self.pageSize)
        tasks = appState.taskHistory(for: account.id, limit: Self.pageSize)
        taskTotal = appState.taskCount(for: account.id)
        taskTodayCredits = appState.taskCreditsConsumed(
            for: account.id,
            since: Calendar.current.startOfDay(for: Date())
        )
        installProblem = appState.installProblem(for: account.platform)
        hasTraeDataDir = account.platform == .trae && appState.traeService.hasUserDataDir(for: account.id)
        openWorkspaces = appState.openWorkspaces(for: account)
        recentProjects = appState.recentProjects(for: account)
        appState.refreshRunningState()
    }

    /// 运行状态标签：TRAE 按账号实例区分，WorkBuddy 只能按平台级展示。
    ///
    /// 两者文案不同，避免让用户误以为 WorkBuddy 的提示代表某个账号正在登录。
    private var runningChip: DetailHeader.RunningChip? {
        switch account.platform {
        case .trae:
            guard appState.runningTraeAccountIds.contains(account.id) else { return nil }
            return DetailHeader.RunningChip(
                text: "本账号实例运行中",
                help: "该账号的独立配置目录有 TRAE 进程在运行（按 --user-data-dir 识别）"
            )
        case .workbuddy:
            guard appState.isWorkBuddyAppRunning else { return nil }
            return DetailHeader.RunningChip(
                text: "客户端已打开",
                help: "WorkBuddy 只有一个客户端实例，该提示只代表应用在运行，不代表当前登录的是这个账号"
            )
        }
    }

    /// 多个 WorkBuddy 账号同时标记为已确认时，说明确认结果互相矛盾。
    private var isWorkBuddyConflict: Bool {
        account.platform == .workbuddy
            && appState.conflictingWorkBuddyAccountIds.contains(account.id)
    }

    private var conflictOthers: [Account] {
        appState.accounts.filter {
            $0.id != account.id
                && $0.platform == .workbuddy
                && $0.lastLoginStatus.isConfirmed
        }
    }

    private var conflictingNames: String {
        conflictOthers.map { "「\($0.displayName)」" }.joined(separator: "、")
    }

    /// 登录状态标签：出现 WorkBuddy 确认冲突时改为「确认冲突」，不显示会误导的绿色已确认。
    private var statusChip: DetailHeader.StatusChip {
        if isWorkBuddyConflict {
            return DetailHeader.StatusChip(
                text: "确认冲突",
                color: .orange,
                icon: "exclamationmark.triangle",
                help: "多个 WorkBuddy 账号都标记为已确认，但同一客户端同一时刻只能登录一个账号"
            )
        }
        return DetailHeader.StatusChip(
            text: account.lastLoginStatus.displayName,
            color: account.lastLoginStatus.tint,
            icon: account.lastLoginStatus.icon,
            help: account.lastLoginStatus.explanation
        )
    }

    private func loadMoreCredits() {
        let more = appState.creditHistory(for: account.id, limit: Self.pageSize, offset: creditHistory.count)
        creditHistory.append(contentsOf: more)
        showingAllHistory = true
    }

    private func loadMoreSwitches() {
        let more = appState.switchHistory(for: account.id, limit: Self.pageSize, offset: switchHistory.count)
        switchHistory.append(contentsOf: more)
        showingAllSwitches = true
    }

    private func loadMoreTasks() {
        let more = appState.taskHistory(for: account.id, limit: Self.pageSize, offset: tasks.count)
        tasks.append(contentsOf: more)
        showingAllTasks = true
    }

    /// 手动采集：采集期间禁用按钮并显示进度，完成后重新读取本页数据。
    /// 「采集已启动」不等于「采集已完成」，所以只在 await 返回后才提示结果。
    private func collectNow() {
        guard !collecting else { return }
        collecting = true
        Task {
            await appState.collectTraeTasks()
            collecting = false
            refresh()
            message = DetailMessage(kind: .success, text: "任务采集已完成，消耗与预计余额已刷新。")
        }
    }

    // MARK: - 动作

    private func openApp(workspace: URL?) {
        do {
            let activated = try appState.openAccountApp(account, workspace: workspace)
            if account.platform == .trae {
                if let workspace {
                    message = DetailMessage(
                        kind: .info,
                        text: activated
                            ? "已激活该账号窗口（「\(workspace.lastPathComponent)」已打开）"
                            : "已切换到「\(workspace.lastPathComponent)」窗口"
                    )
                } else {
                    message = DetailMessage(
                        kind: .info,
                        text: activated ? "已激活该账号窗口" : "已打开该账号窗口（未指定项目）"
                    )
                }
            } else {
                message = DetailMessage(kind: .info, text: "已唤醒 WorkBuddy 客户端（无法区分账号）")
            }
            // 启动后重新读取实例状态与窗口列表，菜单立即反映最新情况
            refresh()
        } catch {
            message = DetailMessage(kind: .error, text: error.localizedDescription)
        }
    }

    private func prepareDelete() {
        deletionImpact = appState.deletionImpact(for: account)
        showingDeleteConfirm = true
    }

    private var deletionMessage: String {
        guard let impact = deletionImpact else {
            return "此操作不可恢复。"
        }
        var parts = [
            "账号档案 1 条",
            "积分记录 \(impact.creditRecords) 条",
            "切换记录 \(impact.switchLogs) 条",
            "任务记录 \(impact.tasks) 条"
        ]
        if impact.traeDataDir {
            parts.append("TRAE 独立配置目录（含该账号本地登录数据）")
        }
        if impact.workstations > 0 {
            let names = impact.workstationNames.prefix(3).joined(separator: "、")
            parts.append("工位引用 \(impact.workstations) 个（\(names)）")
        }
        var message = "将从本机删除：" + parts.joined(separator: "、") + "。不影响官方平台上的账号本身，但此操作不可恢复。"
        if impact.workstations > 0 {
            message += " 删除后这些工位会变为「未分配」，worktree 和已打开的 TRAE 窗口不会被关闭。"
        }
        if impact.isRunning {
            message += " 该账号的客户端实例仍在运行；删除本地档案会移除隔离目录，客户端登录态可能丢失，建议先退出客户端。"
        }
        return message
    }

    private func performDelete() {
        do {
            try appState.deleteAccount(id: account.id)
        } catch {
            message = DetailMessage(kind: .error, text: error.localizedDescription)
        }
    }
}
