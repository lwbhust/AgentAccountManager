import SwiftUI
import Core

/// 单个工位卡片：状态 → 账号 → 分支/工作树 → 上次开工 → 最近任务 → 积分 → 操作。
///
/// 视觉规则（DESIGN_SYSTEM.md）：
/// - 状态 = 颜色 + 文字，普通数据状态一律中性色，警示色只留给真实异常；
/// - 数字使用等宽字阶，标签行距统一 4pt 网格；
/// - 分支与路径单行截断，保证同一行工位卡片高度一致。
struct WorkstationCardView: View {
    @EnvironmentObject private var appState: AppState

    let project: Project
    let workstation: Workstation
    let account: Account?
    let runtime: WorkbenchStore.RuntimeSnapshot?
    let latestTask: TraeTask?
    let accounts: [Account]

    let onSelectAccount: (UUID?) -> Void
    let onStart: () -> Void
    let onCalibrate: (Account) -> Void
    let onSwitchFlow: (Account) -> Void
    let onOpenAccount: (Account) -> Void
    let onSettings: () -> Void

    private var isRunning: Bool {
        runtime?.isRunning == true
    }

    var body: some View {
        SectionCard(
            title: workstation.displayName,
            subtitle: workstation.roleDisplay
        ) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                statusRow
                accountRow
                pathBlock

                InfoRow(
                    label: "上次开工",
                    value: workstation.lastActivatedAt.map { Format.relative($0) } ?? "从未"
                )

                taskRow
                creditRow

                HStack(spacing: DS.Space.s) {
                    Button(action: onStart) {
                        Label("一键开工", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(account == nil || !workstation.isEnabled)

                    Spacer()

                    Menu {
                        if let account {
                            Button("启动并核对登录…") { onSwitchFlow(account) }
                            Button("校准积分") { onCalibrate(account) }
                            Button("在账号管理器中查看") { onOpenAccount(account) }
                            Divider()
                        }
                        Button("工位设置…", action: onSettings)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("更多工位操作")
                }
                .padding(.top, DS.Space.xs)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            TagChip(
                text: isRunning ? "运行中" : "空闲",
                color: isRunning ? DS.Status.running : .secondary,
                systemImage: isRunning ? "app.badge.checkmark" : nil
            )
            if !workstation.isEnabled {
                // 停用是用户自己的设置，属中性状态：图标 + 文字表达，不用警示色。
                TagChip(text: "已停用", color: .secondary, systemImage: "pause.circle")
            }
            if let account {
                TagChip(text: account.displayName, color: .secondary, systemImage: "person.fill")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var accountRow: some View {
        if project.orchestrationMode == .freeLane {
            HStack(spacing: 6) {
                Text("账号")
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                Picker("账号", selection: Binding(
                    get: { account?.id },
                    set: { onSelectAccount($0) }
                )) {
                    Text("未分配").tag(UUID?.none)
                    ForEach(accounts) { item in
                        Text(item.displayName).tag(UUID?.some(item.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer(minLength: 0)
            }
        } else if let account {
            HStack(spacing: 6) {
                Text("账号")
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                Text(account.displayName)
                    .font(DS.Font.secondary.weight(.medium))
                Menu("更换") {
                    ForEach(accounts) { item in
                        Button(item.displayName) { onSelectAccount(item.id) }
                    }
                }
                .controlSize(.small)
                .disabled(accounts.isEmpty)
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 6) {
                Text("账号")
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                Text("未分配")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Status.needsAttention)
                Menu("选择") {
                    ForEach(accounts) { item in
                        Button(item.displayName) { onSelectAccount(item.id) }
                    }
                }
                .controlSize(.small)
                .disabled(accounts.isEmpty)
                Spacer(minLength: 0)
            }
        }
    }

    /// 分支与工作树路径：统一单行截断（悬停看全量），保证卡片高度一致。
    private var pathBlock: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            pathLine(label: "分支", value: workstation.branchName ?? "未生成", mono: true)
            pathLine(label: "工作树", value: workstation.worktreePath ?? "未生成", mono: true)
        }
    }

    private func pathLine(label: String, value: String, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(mono ? DS.Font.caption.monospaced() : DS.Font.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
            Spacer(minLength: 0)
        }
    }

    private var taskRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text("任务")
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            if let latestTask {
                Text(latestTask.titleDisplay)
                    .font(DS.Font.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(latestTask.titleDisplay)
                Spacer(minLength: 6)
                Text(latestTask.credits == nil ? "未采集" : latestTask.creditsDisplay)
                    .font(DS.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                TagChip(
                    text: latestTask.status.displayName,
                    color: statusColor(latestTask.status)
                )
            } else {
                Text("暂无任务")
                    .font(DS.Font.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var creditRow: some View {
        if let account {
            let credit = CreditPresentation(
                account: account,
                estimate: appState.creditBalance(for: account.id),
                staleInterval: appState.staleInterval
            )
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text("积分")
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                if let valueText = credit.valueText {
                    Text(valueText)
                        .font(DS.Font.metricSmall)
                        .foregroundStyle(credit.needsAttention ? DS.Status.needsAttention : .primary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(credit.label)
                        .font(DS.Font.caption)
                        .foregroundStyle(credit.needsAttention ? DS.Status.needsAttention : .secondary)
                    if let detail = credit.detail {
                        Text(detail)
                            .font(DS.Font.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                Button("校准") { onCalibrate(account) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        } else {
            HStack(spacing: DS.Space.s) {
                Text("积分")
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                Text("未分配账号，暂无积分信息")
                    .font(DS.Font.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
    }

    private func statusColor(_ status: TraeTaskStatus) -> Color {
        switch status {
        case .completed: return DS.Status.running
        case .failed: return DS.Status.failure
        case .interrupted: return DS.Status.needsAttention
        case .inProgress: return .accentColor
        case .unknown: return .secondary
        }
    }
}
