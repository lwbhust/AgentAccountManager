import SwiftUI
import Core

/// 账号详情页顶部操作区：标题栏、待核对卡片与主操作栏。
///
/// 纯展示层：所有数据由容器（AccountDetailView）传入，
/// 动作通过回调上抛；这里不做任何 IO 与业务事务。
// MARK: - 顶部

struct DetailHeader: View {
    struct RunningChip {
        let text: String
        let help: String
    }

    struct StatusChip {
        let text: String
        let color: Color
        let icon: String?
        let help: String
    }

    let account: Account
    let statusChip: StatusChip
    let runningChip: RunningChip?
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(account.displayName)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .lineLimit(2)
                    PlatformBadge(platform: account.platform)
                        .help(account.platform.displayName)
                }
                Text(account.phoneDisplay)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    TagChip(
                        text: statusChip.text,
                        color: statusChip.color,
                        systemImage: statusChip.icon
                    )
                    .help(statusChip.help)
                    if let runningChip {
                        // 运行状态是实时信息，用中性色 + 图标表达，
                        // 避免与登录状态胶囊同色并列、主次不分。
                        TagChip(
                            text: runningChip.text,
                            color: .secondary,
                            systemImage: "app.badge.checkmark"
                        )
                        .help(runningChip.help)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 15))
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "取消收藏（⌘D）" : "收藏该账号（⌘D）")

            Menu {
                Button(action: onEdit) {
                    Label("编辑账号", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("删除账号…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作")
        }
    }
}

// MARK: - 待核对

struct PendingConfirmationCard: View {
    let platformName: String
    let onConfirm: () -> Void
    let onReswitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("上次切换后还没有核对结果", systemImage: "clock.badge.questionmark")
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.orange)
            Text("请在 \(platformName) 官方界面确认当前登录的是这个账号，然后再确认。应用不会替你假设登录成功。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("我已核对并登录", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("重新走切换流程", action: onReswitch)
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - 核心操作

struct DetailActionBar: View {
    let platform: Platform
    let installProblem: String?
    let openWorkspaces: [URL]
    let isInstanceRunning: Bool
    let quickWorkspace: URL?
    let onSwitch: () -> Void
    let onRecordCredit: () -> Void
    let onOpenApp: (URL?) -> Void
    let onQuickOpen: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            primaryAction

            Button(action: onRecordCredit) {
                Label("录入积分", systemImage: "square.and.pencil")
            }
            .buttonStyle(TranslucentCapsuleButtonStyle())
            .help("手动录入一次当前看到的积分（按观测时间保存）")

            Spacer()
        }
    }

    /// 主按钮一次点击完成「启动该账号的客户端」：有上次项目就直接恢复，否则打开空白窗口；
    /// 菜单箭头里保留核对登录、切换运行中窗口等低频操作。
    ///
    /// 文案直接说明真实动作（启动 TRAE / 启动 WorkBuddy），
    /// 项目名只作为补充，不再让用户误以为按钮是在"打开本应用"。
    @ViewBuilder
    private var primaryAction: some View {
        if platform == .trae {
            Menu {
                Button(action: onSwitch) {
                    Label("启动并核对登录…", systemImage: "arrow.triangle.2.circlepath")
                }
                if let quickWorkspace {
                    Button {
                        onOpenApp(quickWorkspace)
                    } label: {
                        Label("在「\(quickWorkspace.lastPathComponent)」中重新打开", systemImage: "folder")
                    }
                }
                if isInstanceRunning, !openWorkspaces.isEmpty {
                    Divider()
                    ForEach(openWorkspaces, id: \.self) { url in
                        Button(url.lastPathComponent) { onOpenApp(url) }
                    }
                }
                Divider()
                Button("启动空白窗口") { onOpenApp(nil) }
            } label: {
                HStack(spacing: 6) {
                    Label(primaryTitle, systemImage: "arrow.up.forward.app")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().stroke(DS.Color.cardStroke, lineWidth: 1))
                .frame(minWidth: 96, maxWidth: 230)
            } primaryAction: {
                onQuickOpen()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(installProblem != nil)
            .help(primaryHelp)
        } else {
            Button(action: onSwitch) {
                Label("启动 WorkBuddy", systemImage: "arrow.up.forward.app")
                    .frame(minWidth: 96)
            }
            .buttonStyle(TranslucentCapsuleButtonStyle(isProminent: true))
            .fixedSize()
            .disabled(installProblem != nil)
            .help(installProblem ?? "打开 WorkBuddy 客户端，并引导你在官方界面核对登录")
        }
    }

    private var primaryTitle: String {
        if let quickWorkspace {
            return "启动 TRAE · \(quickWorkspace.lastPathComponent)"
        }
        return "启动 TRAE"
    }

    private var primaryHelp: String {
        if let installProblem { return installProblem }
        if let quickWorkspace {
            return "启动该账号的 TRAE 实例并恢复上次项目「\(quickWorkspace.lastPathComponent)」；实例已在运行时直接激活窗口（⌘↩）"
        }
        return "启动该账号的 TRAE 实例；还没有记录过项目，将打开空白窗口（⌘↩）"
    }
}
