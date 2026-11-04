import SwiftUI
import Core

/// 积分快速录入：自动关联当前账号，尽量少输入，保存即产生一条历史快照。
struct CreditEntryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let account: Account
    /// 工作台校准入口传入的参考估算；只读展示，不预填输入框。
    var referenceEstimate: CreditBalanceEstimate? = nil
    /// 工作台校准后的本地提示，不写入主窗口 toast。
    var onSaved: ((String) -> Void)? = nil

    @State private var creditsText: String = ""
    @State private var totalText: String = ""
    @State private var creditType: String = ""
    @State private var observedAt: Date = Date()
    @State private var errorText: String?
    @State private var saving = false
    @FocusState private var creditsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 440)
        .onAppear {
            creditType = account.creditType ?? ""
            creditsFocused = true
        }
    }

    // MARK: - 子视图

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("录入积分")
                    .font(.headline)
                Text("\(account.platform.displayName) · \(account.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let latest = account.lastCreditQueryAt {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("上次记录")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(Format.dateTime(latest))
                        .font(.caption2)
                }
            }
        }
        .padding(16)
    }

    private var form: some View {
        Form {
            if let referenceEstimate {
                Section {
                    LabeledContent("当前估算") {
                        Text("约 \(Format.credits(referenceEstimate.estimatedCredits))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("仅供参考，不代表官方余额。请以 TRAE 官方界面显示的数值为准，并在下方输入实际值。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("剩余积分") {
                    TextField("必填", text: $creditsText)
                        .focused($creditsFocused)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .frame(maxWidth: 200)
                        .onSubmit { save() }
                }
            } header: {
                Text("本次记录")
            } footer: {
                Text("积分与 Token、人民币余额是不同单位，请确认填写的是积分数值。保存后将以该余额为基准，之后的任务消耗会实时扣减。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("总额度") {
                    TextField("未知可留空", text: $totalText)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .frame(maxWidth: 200)
                }
                LabeledContent("积分类型") {
                    TextField("可选", text: $creditType)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .frame(maxWidth: 200)
                }
                if !suggestedTypes.isEmpty {
                    HStack(spacing: 6) {
                        Text("常用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(suggestedTypes, id: \.self) { type in
                            Button(type) { creditType = type }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .help("点击填入该类型")
                        }
                        Spacer()
                    }
                }
                DatePicker(
                    "观测时间",
                    selection: $observedAt,
                    in: ...Date(),
                    displayedComponents: [.date, .hourAndMinute]
                )
            } header: {
                Text("补充信息（可选）")
            } footer: {
                Text("观测时间默认现在，可改为之前查看到的时刻；历史按观测时间排序。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || creditsText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
    }

    private var suggestedTypes: [String] {
        switch account.platform {
        case .workbuddy: return ["积分"]
        case .trae: return ["会员积分", "奖励积分"]
        }
    }

    // MARK: - 保存

    private func save() {
        let creditsRaw = creditsText.trimmingCharacters(in: .whitespaces)
        guard let credits = Int(creditsRaw), credits >= 0 else {
            errorText = "请输入有效的非负整数积分"
            return
        }

        var totalCredits: Int?
        let totalRaw = totalText.trimmingCharacters(in: .whitespaces)
        if !totalRaw.isEmpty {
            guard let total = Int(totalRaw), total >= 0 else {
                errorText = "总额度需要是非负整数，未知时请留空"
                return
            }
            totalCredits = total
        }

        let type = creditType.trimmingCharacters(in: .whitespaces)

        saving = true
        errorText = nil
        do {
            try appState.recordManualCredits(
                accountId: account.id,
                credits: credits,
                totalCredits: totalCredits,
                creditType: type.isEmpty ? nil : type,
                observedAt: observedAt,
                announce: referenceEstimate == nil
            )
            onSaved?("积分已校准")
            dismiss()
        } catch {
            errorText = "保存失败：\(error.localizedDescription)（已保留你的输入）"
            saving = false
        }
    }
}
