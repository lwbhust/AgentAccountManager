import SwiftUI
import Core

struct AccountFormView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case add
        case edit(Account)
    }

    let mode: Mode

    @State private var platform: Platform = .workbuddy
    @State private var displayName: String = ""
    @State private var fullPhone: String = ""
    @State private var planType: String = ""
    @State private var note: String = ""
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var duplicates: [Account] = []
    @FocusState private var nameFocused: Bool

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var editingAccount: Account? {
        if case .edit(let account) = mode { return account }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 460)
        .onAppear(perform: prefill)
    }

    private var titleBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEdit ? "编辑账号" : "新增账号")
                    .font(.headline)
                Text(isEdit ? "只有名称、手机号、套餐和备注会保存到本机" : "先建立账号档案，积分和登录核对可以稍后补充")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var form: some View {
        Form {
            Section("基本信息") {
                Picker("平台", selection: $platform) {
                    ForEach(Platform.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .disabled(isEdit)
                .help(isEdit ? "账号创建后平台不可更改" : "")

                LabeledContent("账号名称") {
                    TextField("必填", text: $displayName)
                        .focused($nameFocused)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                }

                LabeledContent("套餐类型") {
                    TextField("可选", text: $planType)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                }
            }

            Section {
                LabeledContent("手机号") {
                    TextField(isEdit ? "留空则不修改" : "可选", text: $fullPhone)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .onChange(of: fullPhone) { _, newValue in
                            updateDuplicates(newValue)
                        }
                }
            } header: {
                Text("登录信息")
            } footer: {
                Text(phoneFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !duplicates.isEmpty {
                Section {
                    InlineBanner(
                        kind: .warning,
                        text: "该手机号已用于：\(duplicates.map { "\($0.displayName)（\($0.platform.displayName)）" }.joined(separator: "、"))。同一手机号可能对应不同平台账号，确认无误可继续保存。"
                    )
                }
            }

            Section("备注（可选）") {
                TextEditor(text: $note)
                    .frame(minHeight: 70)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var phoneFooter: String {
        if isEdit {
            return "当前显示为 \(editingAccount?.phoneDisplay ?? "未填写")；留空保持不变，填写新号码会覆盖钥匙串中的完整号码。"
        }
        return "完整号码只写入 macOS 钥匙串，列表中只显示脱敏值（如 138****1234）；留空也能正常使用。"
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEdit ? "保存" : "创建") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
    }

    private func prefill() {
        if case .edit(let account) = mode {
            platform = account.platform
            displayName = account.displayName
            planType = account.planType ?? ""
            note = account.note ?? ""
        } else {
            nameFocused = true
        }
    }

    /// 手机号查重：命中已有账号时给出提示（不禁止保存）。
    private func updateDuplicates(_ phone: String) {
        let trimmed = phone.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            duplicates = []
            return
        }
        duplicates = appState.duplicatePhoneAccounts(fullPhone: trimmed, excluding: editingAccount?.id)
    }

    private func save() {
        saving = true
        errorMessage = nil
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let trimmedPhone = fullPhone.trimmingCharacters(in: .whitespaces)
        let phoneMasked = trimmedPhone.isEmpty ? "" : Masking.maskPhone(trimmedPhone)
        let plan = planType.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let trimmedNote = note.trimmingCharacters(in: .whitespaces).nilIfEmpty

        do {
            switch mode {
            case .add:
                try appState.addAccount(
                    platform: platform,
                    displayName: name,
                    phoneMasked: phoneMasked,
                    fullPhone: trimmedPhone.nilIfEmpty,
                    planType: plan,
                    note: trimmedNote
                )
            case .edit(let account):
                try appState.updateAccount(
                    id: account.id,
                    displayName: name,
                    note: trimmedNote,
                    planType: plan,
                    fullPhone: trimmedPhone.nilIfEmpty
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            saving = false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
