import Foundation
import Core

/// 快速切换与小组件领域状态：账号排序、Widget 快照写盘与最近项目快捷入口。
@MainActor
final class QuickSwitchStore: ObservableObject {
    /// 侧边栏「最近项目」快捷入口：项目 + 所属账号，点击即可打开对应实例。
    @Published private(set) var recentProjectShortcuts: [AppState.RecentProjectShortcut] = []

    /// 最近一次写入小组件的快照内容，用于避免每 5 秒重复写文件。
    private var lastWidgetSnapshot: WidgetSnapshot?
    private let registry: ServiceRegistry
    private let logger: AppLogger

    init(registry: ServiceRegistry, logger: AppLogger) {
        self.registry = registry
        self.logger = logger
    }

    /// 快照构建所需的跨领域输入（由 AppState 组装，Store 之间不互相依赖）。
    /// 排序与组装统一交给 Core 的 `QuickSwitchSnapshotBuilder`，这里只透传原始数据。
    struct WidgetContext {
        /// 全部账号（未排序；排序在 builder 内完成，只维护一份规则）。
        let accounts: [Account]
        let favorites: Set<UUID>
        /// 正在运行的 TRAE 独立实例账号 ID。
        let runningTraeAccountIds: Set<UUID>
        /// WorkBuddy 客户端是否在运行（平台级，无法区分账号）。
        let isWorkBuddyRunning: Bool
        let recentProjectShortcuts: [AppState.RecentProjectShortcut]
        let isDatabaseReady: Bool
    }

    func quickSwitchAccounts(
        accounts: [Account],
        favorites: Set<UUID>,
        runningTraeAccountIds: Set<UUID>
    ) -> [Account] {
        QuickSwitchSnapshotBuilder.orderedAccounts(accounts, favorites: favorites, runningTraeAccountIds: runningTraeAccountIds)
    }

    // MARK: - 小组件快照

    /// 把小组件渲染所需的只读快照写入共享 JSON，并通知 WidgetKit 刷新。
    ///
    /// 只在正式 App 进程中写入；单元测试使用临时数据库时不应污染真实快照文件。
    func refreshWidgetSnapshot(_ context: WidgetContext) {
        guard Bundle.main.bundleIdentifier == "com.agentaccountmanager.app" else { return }
        guard context.isDatabaseReady else { return }

        let widgetProjects = context.recentProjectShortcuts.map { item in
            WidgetProjectSnapshot(
                accountId: item.accountId,
                accountName: item.accountName,
                name: item.url.lastPathComponent,
                path: item.url.path,
                lastVisitedAt: item.lastVisitedAt
            )
        }
        // 排序、副标题、条数上限统一由 Core 的 builder 负责（与 Widget/NSPanel 同一份规则）。
        let snapshot = QuickSwitchSnapshotBuilder.build(
            accounts: context.accounts,
            favorites: context.favorites,
            runningTraeAccountIds: context.runningTraeAccountIds,
            isWorkBuddyRunning: context.isWorkBuddyRunning,
            recentProjects: widgetProjects
        )
        if let lastWidgetSnapshot, lastWidgetSnapshot.hasSameContent(as: snapshot) {
            return
        }

        lastWidgetSnapshot = snapshot
        do {
            try WidgetSnapshotStore.save(snapshot)
            WidgetCenterBridge.reloadTimelines()
        } catch {
            // 下一次状态变化时重试，避免文件系统临时问题时永久跳过同步。
            lastWidgetSnapshot = nil
            logger.error("写入小组件快照失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 最近项目

    /// 重新计算侧边栏的最近项目入口。
    ///
    /// 读取文件系统有一定成本，只在列表重新加载或应用回到前台时调用，
    /// 不在 SwiftUI 渲染路径中计算。
    func refreshRecentProjects(for accounts: [Account]) {
        var items: [AppState.RecentProjectShortcut] = []
        for account in accounts where account.platform == .trae {
            for project in recentProjects(for: account, within: 7 * 24 * 3600, limit: 6) {
                items.append(AppState.RecentProjectShortcut(
                    accountId: account.id,
                    accountName: account.displayName,
                    url: project.url,
                    lastVisitedAt: project.lastVisitedAt
                ))
            }
        }
        recentProjectShortcuts = Array(
            items.sorted { $0.lastVisitedAt > $1.lastVisitedAt }.prefix(15)
        )
    }

    /// 合并两类来源，得到最近一段时间打开过的项目：
    /// 1. 本应用精确记录的打开事件（含次数）
    /// 2. TRAE 隔离目录里 `workspace.json` 的最近活动时间（近似）
    func recentProjects(
        for account: Account,
        within interval: TimeInterval = 3 * 24 * 3600,
        limit: Int = 20
    ) -> [AppState.RecentProject] {
        guard account.platform == .trae else { return [] }
        let since = Date(timeIntervalSinceNow: -interval)
        var merged: [String: AppState.RecentProject] = [:]

        let visits = (try? registry.projectVisitService?.recent(
            accountId: account.id,
            since: since,
            limit: 200
        )) ?? []
        for visit in visits {
            let url = URL(fileURLWithPath: visit.workspacePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            merged[url.standardizedFileURL.path] = AppState.RecentProject(
                url: url,
                lastVisitedAt: visit.lastVisitedAt,
                visitCount: visit.visitCount
            )
        }

        for activity in registry.traeService.workspaceActivity(for: account.id) where activity.modifiedAt >= since {
            guard FileManager.default.fileExists(atPath: activity.url.path) else { continue }
            let key = activity.url.standardizedFileURL.path
            if let existing = merged[key] {
                if activity.modifiedAt > existing.lastVisitedAt {
                    merged[key] = AppState.RecentProject(
                        url: existing.url,
                        lastVisitedAt: activity.modifiedAt,
                        visitCount: existing.visitCount
                    )
                }
            } else {
                merged[key] = AppState.RecentProject(
                    url: activity.url,
                    lastVisitedAt: activity.modifiedAt,
                    visitCount: nil
                )
            }
        }

        return Array(
            merged.values
                .sorted { $0.lastVisitedAt > $1.lastVisitedAt }
                .prefix(limit)
        )
    }
}
