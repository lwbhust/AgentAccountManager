import SwiftUI
import Core

struct StartupConfirmView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: WorkbenchStore
    @Environment(\.dismiss) private var dismiss

    let preparation: WorkbenchService.StartPreparation

    @State private var task: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    banner
                    summaryCard
                    preflightCard
                    taskCard
                    if let errorMessage {
                        InlineBanner(kind: .error, text: errorMessage)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 700)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("开工确认")
                    .font(.headline)
                Text("\(preparation.project.displayName) · \(preparation.workstation.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TagChip(
                text: preparation.project.orchestrationMode.displayName,
                color: preparation.project.orchestrationMode == .rolePlay ? .purple : .secondary
            )
        }
        .padding(16)
    }

    @ViewBuilder
    private var banner: some View {
        if !preparation.preflight.canProceed {
            InlineBanner(
                kind: .error,
                text: "预检未通过：\(preparation.preflight.summary)。请先处理阻断项。"
            )
        } else if !preparation.preflight.warningChecks.isEmpty {
            InlineBanner(
                kind: .warning,
                text: "\(preparation.preflight.summary)。确认后会继续开工。"
            )
        } else {
            InlineBanner(kind: .success, text: preparation.preflight.summary)
        }
    }

    private var summaryCard: some View {
        SectionCard(title: "工位摘要") {
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(label: "项目", value: preparation.project.displayName)
                InfoRow(label: "工位", value: preparation.workstation.displayName)
                InfoRow(label: "角色", value: preparation.workstation.roleDisplay)
                InfoRow(label: "账号", value: preparation.account.displayName)
                InfoRow(label: "基线分支", value: preparation.project.baselineBranch)
                InfoRow(label: "工位分支", value: preparation.workstation.branchName ?? "未生成")
                InfoRow(label: "worktree", value: preparation.targetWorktree.path)
                InfoRow(label: "本次操作", value: operationTitle)
            }
        }
    }

    private var preflightCard: some View {
        SectionCard(
            title: "预检结果",
            subtitle: preparation.preflight.summary,
            subtitleColor: preparation.preflight.canProceed ? .secondary : .red
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(preparation.preflight.checks) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: check.status))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(color(for: check.status))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                                .font(.subheadline.weight(.medium))
                            if let detail = check.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        TagChip(text: check.status.title, color: color(for: check.status))
                    }
                }
            }
        }
    }

    private var taskCard: some View {
        SectionCard(title: "本次任务（可选）") {
            TextEditor(text: $task)
                .font(.callout)
                .frame(minHeight: 76)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                )
            Text("会写入上下文包；不保存到数据库，也不包含账号凭据。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            if store.isBusy {
                ProgressView()
                    .controlSize(.small)
                Text(store.busyText ?? "正在执行…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(store.isBusy)
            Button(confirmTitle) {
                confirm()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!preparation.preflight.canProceed || store.isBusy)
        }
        .padding(16)
    }

    private var operationTitle: String {
        if preparation.willCreateWorktree {
            return "创建 worktree 并启动"
        }
        if preparation.worktreeAlreadyOpen {
            return "激活已有窗口"
        }
        return "复用 worktree 并启动"
    }

    private var confirmTitle: String {
        if !preparation.preflight.canProceed {
            return "先处理阻断项"
        }
        if preparation.willCreateWorktree {
            return "创建并启动"
        }
        if preparation.worktreeAlreadyOpen {
            return "激活窗口"
        }
        return "复用并启动"
    }

    private func confirm() {
        errorMessage = nil
        Task {
            await store.confirmStart(
                preparation: preparation,
                task: task,
                appState: appState
            )
            if let error = store.errorMessage {
                errorMessage = error
                store.errorMessage = nil
            } else if store.preparation == nil {
                dismiss()
            }
        }
    }

    private func icon(for status: StartupPreflight.Status) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    private func color(for status: StartupPreflight.Status) -> Color {
        switch status {
        case .pass: return .green
        case .info: return .accentColor
        case .warning: return .orange
        case .blocked: return .red
        }
    }
}
