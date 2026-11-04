import SwiftUI
import AppKit
import Core

/// 账号详情页「概览」分区：额度摘要、账号档案信息与项目入口。
///
/// 纯展示层：数据由容器（AccountDetailView）刷新后传入，
/// 打开项目的动作通过回调上抛，这里不做任何 IO。
struct AccountOverviewSection: View {
    let account: Account
    let estimate: CreditBalanceEstimate?
    let hasTraeDataDir: Bool
    let openWorkspaces: [URL]
    let recentProjects: [AppState.RecentProject]
    let isInstanceRunning: Bool
    let onOpenWorkspace: (URL) -> Void
    let onRecordCredit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            CreditSummaryCard(
                account: account,
                estimate: estimate,
                onRecordCredit: onRecordCredit
            )
            AccountInfoCard(
                account: account,
                hasTraeDataDir: hasTraeDataDir,
                openWorkspaces: openWorkspaces,
                recentProjects: recentProjects,
                isInstanceRunning: isInstanceRunning,
                onOpenWorkspace: onOpenWorkspace
            )
        }
    }
}

// MARK: - 额度摘要（概览页首屏）

/// 概览页的额度摘要：把用户最关心的"还剩多少"提到首屏第一张卡。
/// 数字层级 = 大号等宽数字；口径与「积分与任务」页完全一致（同一 estimate 数据源）。
struct CreditSummaryCard: View {
    let account: Account
    let estimate: CreditBalanceEstimate?
    let onRecordCredit: () -> Void

    var body: some View {
        SectionCard(
            title: "额度",
            subtitle: subtitle,
            subtitleColor: .secondary
        ) {
            MetricValue(
                value: Format.credits(displayedCredits),
                unit: estimate?.hasDeduction == true ? "预计积分" : (account.hasCreditRecord ? "积分" : nil),
                footnote: footnote,
                sourceBadge: account.hasCreditRecord ? account.dataStatus.displayName : nil,
                tint: negativeBalance ? DS.Status.needsAttention : .primary
            )
            Button(account.hasCreditRecord ? "重新录入余额" : "录入当前余额", action: onRecordCredit)
                .controlSize(.small)
                .help("以当前观测时间为新基准，之前的任务消耗不会重复扣减")
                .padding(.top, DS.Space.xs)
        }
    }

    private var displayedCredits: Double? {
        estimate?.estimatedCredits ?? account.currentCredits.map(Double.init)
    }

    private var negativeBalance: Bool {
        (estimate?.estimatedCredits ?? 0) < 0
    }

    private var subtitle: String {
        if !account.hasCreditRecord { return "还没有记录，录入一次实际余额后自动开始跟踪消耗" }
        if let estimate, estimate.hasDeduction {
            return "录入 \(Format.credits(estimate.baselineCredits)) − 基准后消耗 \(Format.credits(estimate.consumedCredits))"
        }
        if let observedAt = account.lastCreditQueryAt {
            return "记录于 \(Format.relative(observedAt))"
        }
        return "手动录入数据"
    }

    private var footnote: String? {
        guard let estimate, estimate.pendingTaskCount > 0 else { return nil }
        return "另有 \(estimate.pendingTaskCount) 个任务的消耗暂未计入"
    }
}

// MARK: - 账号信息

struct AccountInfoCard: View {
    let account: Account
    let hasTraeDataDir: Bool
    let openWorkspaces: [URL]
    let recentProjects: [AppState.RecentProject]
    let isInstanceRunning: Bool
    let onOpenWorkspace: (URL) -> Void

    var body: some View {
        SectionCard(title: "账号信息") {
            // MARK: 两列 Grid 布局（原生对齐，比 InfoRow 的 HStack 更整齐）
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("平台")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(account.platform.displayName)
                        .foregroundStyle(.primary)
                }
                GridRow {
                    Text("套餐")
                        .foregroundStyle(.secondary)
                    Text(account.planType?.isEmpty == false ? account.planType! : "未填写")
                        .foregroundStyle(.primary)
                }
                GridRow {
                    Text("备注")
                        .foregroundStyle(.secondary)
                    Text(account.note?.isEmpty == false ? account.note! : "无")
                        .foregroundStyle(.primary)
                }
                GridRow {
                    Text("最近切换")
                        .foregroundStyle(.secondary)
                    Text(account.lastUsedDisplay)
                        .foregroundStyle(.primary)
                        .help("最近一次切换流程成功启动官方客户端的时间；不代表当前登录状态")
                }
                GridRow {
                    Text("档案更新")
                        .foregroundStyle(.secondary)
                    Text(Format.relative(account.updatedAt))
                        .foregroundStyle(.primary)
                }
                if account.platform == .trae {
                    GridRow {
                        Text("独立配置目录")
                            .foregroundStyle(.secondary)
                        Text(hasTraeDataDir ? "已创建" : "首次切换时创建")
                            .foregroundStyle(.primary)
                    }
                }
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)

            if account.platform == .trae {
                if isInstanceRunning, !openWorkspaces.isEmpty {
                    Divider().padding(.vertical, 2)
                    openWorkspacesBlock
                }
                if !recentProjects.isEmpty {
                    Divider().padding(.vertical, 2)
                    recentProjectsBlock
                }
            }
        }
    }

    /// 最近 3 天打开过的项目；点击即在该账号的实例中打开。
    /// 采用横向卡片布局，Finder 风格，紧凑且支持触控板横向滚动。
    private var recentProjectsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("最近 3 天打开")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(recentProjects.count) 个项目")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recentProjects) { project in
                        ProjectCard(
                            icon: "folder",
                            iconColor: .secondary,
                            title: project.url.lastPathComponent,
                            subtitle: recentDetail(project),
                            help: "点击启动并打开「\(project.url.lastPathComponent)」\n\(project.url.path)",
                            action: { onOpenWorkspace(project.url) }
                        )
                    }
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("关于数据来源")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .help("本应用打开的项目为精确记录；在 TRAE 内直接打开的项目按最近活动时间近似，启用前的历史无法追溯。")
        }
    }

    private func recentDetail(_ project: AppState.RecentProject) -> String {
        var text = Format.relative(project.lastVisitedAt)
        if let count = project.visitCount, count > 1 {
            text += " · \(count) 次"
        }
        return text
    }

    /// 运行中实例打开的全部项目：一个账号可以同时开多个窗口。
    /// 点击项目名会把对应窗口带到前台（TRAE 单实例转发，不会新起进程）。
    private var openWorkspacesBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("运行中的项目")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(openWorkspaces.count) 个窗口")
                    .foregroundStyle(.green)
            }
            .font(.subheadline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(openWorkspaces.enumerated()), id: \.element) { index, url in
                        ProjectCard(
                            icon: "macwindow",
                            iconColor: .green,
                            title: url.lastPathComponent,
                            subtitle: index == 0 ? "最近活跃" : nil,
                            subtitleColor: .green,
                            help: "点击启动并切换到「\(url.lastPathComponent)」窗口\n\(url.path)",
                            action: { onOpenWorkspace(url) }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - 横向项目卡片（Finder 风格）

/// 横向滚动的项目卡片，用于运行中/最近项目展示。
/// 相比 ProjectRow 的行内样式更突出，支持 hover 交互和材质背景。
struct ProjectCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    var subtitleColor: Color = .secondary
    let help: String
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(iconColor)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }
            }
            .frame(width: 180, height: 96, alignment: .topLeading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(cardFillOpacity))
                    .shadow(color: .black.opacity(isHovering ? 0.10 : 0.04),
                            radius: isHovering ? 6 : 3,
                            y: isHovering ? 2 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .light ? 0.45 : 0.22),
                                Color.white.opacity(colorScheme == .light ? 0.08 : 0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }

    /// 卡片玻璃底色：不用系统材质，避免浅色模式下变成一块不透明白板。
    private var cardFillOpacity: Double {
        if colorScheme == .light {
            return isHovering ? 0.22 : 0.13
        }
        return isHovering ? 0.10 : 0.06
    }
}
