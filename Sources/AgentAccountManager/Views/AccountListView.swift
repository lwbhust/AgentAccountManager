import SwiftUI
import Core

struct AccountListView: View {
    @EnvironmentObject private var appState: AppState
    var onAddAccount: () -> Void

    var body: some View {
        if appState.accounts.isEmpty {
            emptyState(
                icon: "person.crop.circle.badge.plus",
                title: "还没有账号",
                message: "添加你的第一个 TRAE 账号，之后就能在这里一键打开独立账号实例。",
                actionTitle: "新增账号",
                action: onAddAccount
            )
        } else if appState.filteredAccounts.isEmpty {
            emptyState(
                icon: emptyIcon,
                title: emptyTitle,
                message: emptyMessage,
                actionTitle: emptyActionTitle,
                action: resetFilters
            )
        } else {
            List {
                ForEach(appState.filteredAccounts) { account in
                    AccountListRow(account: account)
                        .contentShape(Rectangle())
                        .onTapGesture { appState.selectedAccountId = account.id }
                        // 自定义选中/悬停背景，替代系统不透明的选中矩形。
                        .listRowBackground(
                            SelectableRowBackground(
                                isSelected: appState.selectedAccountId == account.id
                            )
                        )
                        .contextMenu {
                            Button("打开账号") {
                                open(account, workspace: appState.quickOpenWorkspace(for: account))
                            }
                            Button("启动空白窗口") {
                                open(account, workspace: nil)
                            }
                            Divider()
                            Button(appState.isFavorite(account.id) ? "取消收藏" : "收藏") {
                                appState.toggleFavorite(account.id)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            // 去掉侧边栏自身的滚动背景，让窗口底层的极光透上来。
            .scrollContentBackground(.hidden)
        }
    }

    private func open(_ account: Account, workspace: URL?) {
        do {
            let activated = try appState.openAccountApp(account, workspace: workspace)
            appState.toast = activated ? "已激活该账号的运行中窗口" : "已打开账号窗口"
        } catch {
            appState.errorMessage = "打开账号失败：\(error.localizedDescription)"
        }
    }

    private var emptyIcon: String {
        if !appState.searchText.isEmpty { return "magnifyingglass" }
        switch appState.accountFilter {
        case .running: return "bolt.slash"
        case .all: return "tray"
        }
    }

    private var emptyTitle: String {
        if !appState.searchText.isEmpty { return "没有匹配的账号" }
        switch appState.accountFilter {
        case .running: return "没有运行中的实例"
        case .all: return "该平台下没有账号"
        }
    }

    private var emptyMessage: String {
        if !appState.searchText.isEmpty {
            return "换个关键字试试，或清空搜索条件。"
        }
        switch appState.accountFilter {
        case .running:
            return "打开账号实例后，它会出现在这里。"
        case .all:
            return "切换到「全部」，或为这个平台新增一个账号。"
        }
    }

    private var emptyActionTitle: String {
        if !appState.searchText.isEmpty { return "清空搜索" }
        return appState.accountFilter == .all ? "新增账号" : "显示全部"
    }

    private func resetFilters() {
        if !appState.searchText.isEmpty {
            appState.searchText = ""
        } else if appState.accountFilter == .all {
            onAddAccount()
        } else {
            appState.accountFilter = .all
        }
    }

    private func emptyState(
        icon: String,
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AccountListRow: View {
    @EnvironmentObject private var appState: AppState
    let account: Account

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            PlatformBadge(platform: account.platform)

            // 左侧：名称 + 手机号/套餐 + 状态小圆点
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(account.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if appState.isFavorite(account.id) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                            .help("已收藏")
                    }
                    Spacer(minLength: 0)
                }

                Text(secondaryLine)
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // 状态小圆点（轻量指示，降低视觉权重）
                HStack(spacing: 6) {
                    statusDots
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右侧：积分数字（等宽对齐，避免列表跳动）
            creditsBlock
        }
        .padding(.vertical, 4)
        .help(account.note ?? "")
    }

    // MARK: - 子视图

    /// 积分数字块：靠右、等宽、半粗——名称是行锚点，数字是辅助扫描目标。
    /// 固定最小宽度 + 尾部对齐，保证整列数字的右边缘在视觉上落在同一条竖线。
    private var creditsBlock: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(creditsValue)
                .font(DS.Font.metricSmall)
                .foregroundStyle(creditsColor)
                .lineLimit(1)
            if creditsSubtitle != nil {
                Text(creditsSubtitle!)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 52, alignment: .trailing)
    }

    /// 名称下方的第二行：手机号 + 套餐
    private var secondaryLine: String {
        var parts = [account.phoneDisplay]
        if let plan = account.planType, !plan.isEmpty {
            parts.append(plan)
        }
        return parts.joined(separator: " · ")
    }

    /// 积分主显示值
    private var creditsValue: String {
        if account.dataStatus == .queryFailed { return "—" }
        if !account.hasCreditRecord { return "—" }
        return Format.credits(appState.displayedCredits(for: account))
    }

    /// 积分下方的小标签（预计/未记录/需校准等）
    private var creditsSubtitle: String? {
        if account.dataStatus == .queryFailed { return "查询失败" }
        if !account.hasCreditRecord { return "未记录" }
        if let estimate = appState.creditBalance(for: account.id), estimate.estimatedCredits < 0 {
            return "需校准"
        }
        let estimate = appState.creditBalance(for: account.id)
        if estimate?.hasDeduction == true { return "预计" }
        return nil
    }

    private var creditsColor: Color {
        if account.dataStatus == .queryFailed { return .red }
        if let estimate = appState.creditBalance(for: account.id), estimate.estimatedCredits < 0 {
            return .orange
        }
        return .primary
    }

    // MARK: - 状态小圆点组

    @ViewBuilder
    private var statusDots: some View {
        // 运行状态优先显示（最有信息量）
        runningDot

        // 登录核对状态
        if isWorkbuddyConflict {
            StatusDot(text: "确认冲突", color: .orange)
                .help("多个 WorkBuddy 账号都标记为已确认，但同一客户端同一时刻只能登录一个账号")
        } else if account.lastLoginStatus == .pendingConfirmation {
            StatusDot(text: "待核对", color: .orange)
                .help("本应用尚未记录该账号的登录核对结果")
        }

        // 额度数据新鲜度：措辞强调"数据待更新"，而不是让用户误以为积分本身失效。
        if account.hasCreditRecord, account.isCreditStale(within: appState.staleInterval) {
            StatusDot(text: "额度待更新", color: .orange)
                .help("最近一次额度录入已超过 \(Int(appState.staleInterval / 3600)) 小时，之后的消耗可能没有完整采集")
        }

        // 任务采集诊断
        if let diagnostics = appState.taskDiagnostics[account.id], diagnostics.hasIssue {
            StatusDot(text: "采集异常", color: .red)
                .help("任务日志解析出现异常，可在详情页的诊断区查看")
        }
    }

    private var isWorkbuddyConflict: Bool {
        account.platform == .workbuddy
            && appState.conflictingWorkBuddyAccountIds.contains(account.id)
    }

    /// 运行状态小圆点：TRAE 按账号实例区分，WorkBuddy 只能平台级提示。
    @ViewBuilder
    private var runningDot: some View {
        switch account.platform {
        case .trae:
            if appState.runningTraeAccountIds.contains(account.id) {
                StatusDot(text: "运行中", color: .green)
                    .help("该账号的独立配置目录有 TRAE 进程在运行（不代表登录身份已验证）")
            }
        case .workbuddy:
            if appState.isWorkBuddyAppRunning {
                StatusDot(text: "客户端已打开", color: .green)
                    .help("WorkBuddy 只有一个客户端实例，无法区分当前登录的是哪个账号")
            }
        }
    }
}

/// 平台标识，帮助用户一眼区分两个平台。
struct PlatformBadge: View {
    let platform: Platform

    var body: some View {
        Text(platform == .workbuddy ? "W" : "T")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            .padding(.top, 1)
            .help(platform.displayName)
    }

    private var color: Color {
        platform == .workbuddy ? .blue : .purple
    }
}
