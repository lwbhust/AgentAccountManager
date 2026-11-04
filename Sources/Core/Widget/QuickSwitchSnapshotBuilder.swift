import Foundation

/// 快速切换快照生成器：账号排序、副标题与快照组装的唯一实现（纯函数）。
///
/// Widget（WidgetKit 扩展）与桌面 NSPanel 使用同一数据来源：
/// 主应用经本 builder 生成快照写入 JSON，Widget 只读快照；
/// NSPanel 直接复用 `orderedAccounts` 的同一条排序规则。
/// 这里不做任何文件 IO 与进程查询，便于边界矩阵测试。
public enum QuickSwitchSnapshotBuilder {
    /// 桌面快速切换的账号排序：收藏优先，其次运行中的 TRAE 实例，
    /// 最后按最近使用时间；其余情况按平台与名称稳定排列。
    ///
    /// 只读输入数据，不查询进程或数据库，可在渲染路径使用。
    public static func orderedAccounts(
        _ list: [Account],
        favorites: Set<UUID>,
        runningTraeAccountIds: Set<UUID>
    ) -> [Account] {
        list.sorted { lhs, rhs in
            let lhsFavorite = favorites.contains(lhs.id)
            let rhsFavorite = favorites.contains(rhs.id)
            if lhsFavorite != rhsFavorite { return lhsFavorite }

            // WorkBuddy 的运行状态是平台级，不参与账号排序，避免所有 W 账号一起上浮。
            let lhsRunning = lhs.platform == .trae && runningTraeAccountIds.contains(lhs.id)
            let rhsRunning = rhs.platform == .trae && runningTraeAccountIds.contains(rhs.id)
            if lhsRunning != rhsRunning { return lhsRunning }

            let lhsUsed = lhs.lastUsedAt ?? .distantPast
            let rhsUsed = rhs.lastUsedAt ?? .distantPast
            if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }

            if lhs.platform != rhs.platform { return lhs.platform == .trae }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// 组装小组件快照。
    ///
    /// - Parameters:
    ///   - accounts: 全部账号（未排序；排序在本函数内完成，只维护这一份规则）。
    ///   - runningTraeAccountIds: 正在运行的 TRAE 独立实例账号 ID。
    ///   - isWorkBuddyRunning: WorkBuddy 客户端是否在运行（平台级，无法区分账号）。
    ///   - recentProjects: 最近项目快捷入口（已按最近活动排序）。
    ///   - now: 快照生成时间（注入以便测试）。
    ///   - maxAccounts/maxProjects: 快照保留条数上限（Widget 只渲染前几条）。
    public static func build(
        accounts: [Account],
        favorites: Set<UUID>,
        runningTraeAccountIds: Set<UUID>,
        isWorkBuddyRunning: Bool,
        recentProjects: [WidgetProjectSnapshot],
        now: Date = Date(),
        maxAccounts: Int = 8,
        maxProjects: Int = 6
    ) -> WidgetSnapshot {
        let ordered = orderedAccounts(accounts, favorites: favorites, runningTraeAccountIds: runningTraeAccountIds)
        let widgetAccounts = ordered.prefix(maxAccounts).map { account in
            WidgetAccountSnapshot(
                id: account.id,
                name: account.displayName,
                platform: account.platform,
                isRunning: isRunning(account, runningIds: runningTraeAccountIds, workbuddy: isWorkBuddyRunning),
                isFavorite: favorites.contains(account.id),
                subtitle: subtitle(for: account, isRunning: isRunning(account, runningIds: runningTraeAccountIds, workbuddy: isWorkBuddyRunning))
            )
        }
        return WidgetSnapshot(
            updatedAt: now,
            runningCount: accounts.filter {
                isRunning($0, runningIds: runningTraeAccountIds, workbuddy: isWorkBuddyRunning)
            }.count,
            accounts: Array(widgetAccounts),
            projects: Array(recentProjects.prefix(maxProjects))
        )
    }

    /// 账号是否处于「运行中」。
    /// TRAE 按账号实例判断；WorkBuddy 只有一个客户端，只能按平台级提示。
    private static func isRunning(_ account: Account, runningIds: Set<UUID>, workbuddy: Bool) -> Bool {
        switch account.platform {
        case .trae:
            return runningIds.contains(account.id)
        case .workbuddy:
            return workbuddy
        }
    }

    /// 套餐、运行状态等一行副标题；不含手机号或任何凭据。
    static func subtitle(for account: Account, isRunning: Bool) -> String {
        var parts: [String] = []
        if let plan = account.planType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty {
            parts.append(plan)
        }
        if isRunning {
            parts.append(account.platform == .workbuddy ? "客户端已打开" : "运行中")
        }
        if parts.isEmpty {
            parts.append(account.platform == .workbuddy ? "客户端未打开" : "未运行")
        }
        return parts.joined(separator: " · ")
    }
}

extension WidgetSnapshot {
    /// 快照是否已过期（主应用长时间未运行时，小组件展示的数据可能失真）。
    /// 默认 24 小时；过期只是提示，不影响深链打开逻辑（打开时会重新校验）。
    public func isStale(now: Date = Date(), maxAge: TimeInterval = 24 * 3600) -> Bool {
        now.timeIntervalSince(updatedAt) > maxAge
    }
}
