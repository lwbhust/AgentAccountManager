import SwiftUI
import Core

/// 统一的账号切换流程：确认目标 → 执行 → 核对结果。
/// 平台差异由 SwitchService 封装，界面只呈现统一的步骤与证据。
struct SwitchFlowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let account: Account
    /// 流程结束时回传给详情页的提示（文案, 类型）
    var onFinish: (String, InlineBanner.Kind) -> Void

    @State private var stage: Stage = .review
    @State private var outcome: SwitchService.SwitchOutcome?
    @State private var errorText: String?
    /// 渲染期不做同步 IO：安装检测与上次项目都在视图出现时一次性缓存
    @State private var installProblem: String?
    @State private var lastWorkspaceName: String?

    private enum Stage {
        case review, running, result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    stepIndicator
                    switch stage {
                    case .review:
                        reviewContent
                    case .running:
                        runningContent
                    case .result:
                        resultContent
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 540, height: 470)
        .onAppear {
            installProblem = appState.installProblem(for: account.platform)
            lastWorkspaceName = appState.lastWorkspace(for: account)?.lastPathComponent
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("切换账号")
                    .font(.headline)
                Text("\(account.platform.displayName) · \(account.displayName) · \(account.phoneDisplay)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TagChip(text: account.platform.displayName, color: account.platform == .workbuddy ? .blue : .purple)
        }
        .padding(16)
    }

    /// 三步进度指示，明确当前处在哪一步。
    private var stepIndicator: some View {
        HStack(spacing: 8) {
            stepDot(index: 0, title: "确认目标")
            connector(active: stage != .review)
            stepDot(index: 1, title: "执行切换")
            connector(active: stage == .result)
            stepDot(index: 2, title: "核对结果")
        }
    }

    private func stepDot(index: Int, title: String) -> some View {
        let current = currentStep
        let done = index < current
        let isCurrent = index == current
        return HStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(done || isCurrent ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
                    .frame(width: 16, height: 16)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isCurrent ? .white : .secondary)
                }
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
    }

    private func connector(active: Bool) -> some View {
        Rectangle()
            .fill(active ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var currentStep: Int {
        switch stage {
        case .review: return 0
        case .running: return 1
        case .result: return 2
        }
    }

    // MARK: - 第一步：确认目标

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCard(title: "即将切换到的账号") {
                InfoRow(label: "名称", value: account.displayName)
                InfoRow(label: "手机号", value: account.phoneDisplay)
                InfoRow(label: "套餐", value: account.planType?.isEmpty == false ? account.planType! : "未填写")
                InfoRow(label: "当前状态", value: account.lastLoginStatus.displayName)
                if account.platform == .trae {
                    InfoRow(
                        label: "上次项目",
                        value: lastWorkspaceName ?? "暂无（会停在欢迎页）"
                    )
                }
            }

            InlineBanner(kind: .info, text: platformExplanation)

            if let installProblem {
                InlineBanner(kind: .warning, text: installProblem)
            }

            Text("本流程不会复制或修改 \(account.platform.displayName) 的私有认证文件，也不会把它标记为“已验证”，除非官方工具给出了可验证的身份信息。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var platformExplanation: String {
        switch account.platform {
        case .workbuddy:
            return "WorkBuddy 没有官方自动切换能力。下一步会打开 WorkBuddy，你需要手动退出当前账号并登录目标账号，然后回到这里核对确认。"
        case .trae:
            return "TRAE 会使用这个账号专属的配置目录启动一个独立窗口，不影响已经开着的窗口，并自动打开该账号上次的项目。首次需要登录，之后会复用该目录里保存的会话。"
        }
    }

    // MARK: - 第二步：执行

    private var runningContent: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("正在启动 \(account.platform.displayName)…")
                .font(.callout)
            Text(account.platform.supportsIsolatedInstance
                 ? "正在准备独立配置目录并启动实例"
                 : "正在打开官方应用")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - 第三步：结果

    @ViewBuilder
    private var resultContent: some View {
        if let outcome {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: resultIcon(outcome.result))
                        .font(.title2)
                        .foregroundStyle(resultColor(outcome.result))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(outcome.headline)
                            .font(.headline)
                        Text(outcome.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 6) {
                    TagChip(
                        text: outcome.identityVerified ? "身份已验证" : "身份未验证",
                        color: outcome.identityVerified ? .green : .secondary,
                        systemImage: outcome.identityVerified ? "checkmark.seal.fill" : "questionmark.circle"
                    )
                    if outcome.launched {
                        TagChip(text: "已启动客户端", color: .green, systemImage: "app.badge.checkmark")
                    }
                    Spacer()
                }

                if !outcome.manualSteps.isEmpty {
                    SectionCard(title: "接下来需要你做的事") {
                        ForEach(Array(outcome.manualSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .frame(width: 16, height: 16)
                                    .background(Circle().fill(Color.accentColor))
                                Text(step)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }

                if let advice = outcome.failureAdvice {
                    InlineBanner(kind: .warning, text: advice)
                }

                if let identity = outcome.claimedIdentity {
                    InfoRow(label: "官方返回身份", value: identity)
                }
            }
        } else {
            InlineBanner(kind: .error, text: errorText ?? "切换未完成，请重试。")
        }
    }

    // MARK: - 底部按钮

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            switch stage {
            case .review:
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开始切换") { startSwitch() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(installProblem != nil)

            case .running:
                Button("取消") { dismiss() }
                    .disabled(true)

            case .result:
                if let outcome {
                    if outcome.result == .failed {
                        Button("关闭") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("重试") { startSwitch() }
                            .buttonStyle(.borderedProminent)
                    } else if outcome.identityVerified {
                        Button("完成") {
                            onFinish("已切换到「\(account.displayName)」，身份已验证", .success)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("稍后再说") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("我已核对并登录") {
                            appState.confirmLogin(account)
                            onFinish("已记录你对「\(account.displayName)」的登录确认", .success)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button("关闭") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("重试") { startSwitch() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
    }

    // MARK: - 执行

    private func startSwitch() {
        stage = .running
        errorText = nil
        outcome = nil

        let service = appState.switchService
        let target = account
        Task.detached(priority: .userInitiated) {
            let result = service?.switchTo(account: target)
            await MainActor.run {
                if let result {
                    outcome = result
                } else {
                    errorText = "切换服务不可用，请重启应用后重试。"
                }
                try? appState.reload()
                stage = .result
            }
        }
    }

    private func resultIcon(_ result: SwitchResult) -> String {
        switch result {
        case .success: return "checkmark.circle.fill"
        case .unconfirmed: return "questionmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func resultColor(_ result: SwitchResult) -> Color {
        switch result {
        case .success: return .green
        case .unconfirmed: return .orange
        case .failed: return .red
        }
    }
}
