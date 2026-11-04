import SwiftUI
import Core

struct WorkstationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: WorkbenchStore
    @Environment(\.dismiss) private var dismiss

    let project: Project

    @State private var items: [Workstation]
    @State private var errorMessage: String?
    @State private var saving = false

    init(project: Project, store: WorkbenchStore) {
        self.project = project
        self.store = store
        _items = State(initialValue: store.workstations(for: project.id))
    }

    private var accounts: [Account] {
        appState.accounts.filter { $0.platform == .trae }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 640, height: 580)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("工位设置")
                    .font(.headline)
                Text("\(project.displayName) · \(project.orchestrationMode.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TagChip(
                text: "最多 3 个启用工位",
                color: .secondary
            )
        }
        .padding(16)
    }

    private var form: some View {
        Form {
            if accounts.isEmpty {
                Section {
                    InlineBanner(
                        kind: .warning,
                        text: "还没有 TRAE 账号。请先在账号管理器中添加账号，再为工位绑定。"
                    )
                }
            }

            ForEach($items) { $item in
                Section {
                    HStack {
                        Toggle("启用", isOn: $item.isEnabled)
                        Spacer()
                        Text(item.worktreePath ?? "尚未生成路径")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    LabeledContent("名称") {
                        TextField("工位名称", text: $item.displayName)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 260)
                    }

                    if project.orchestrationMode == .rolePlay {
                        LabeledContent("角色") {
                            TextField("例如 开发 / 评审", text: Binding(
                                get: { item.roleTag ?? "" },
                                set: { item.roleTag = $0.isEmpty ? nil : $0 }
                            ))
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 260)
                        }
                    }

                    LabeledContent("账号") {
                        Picker("账号", selection: Binding(
                            get: { item.accountId },
                            set: { item.accountId = $0 }
                        )) {
                            Text("未分配").tag(UUID?.none)
                            ForEach(accounts) { account in
                                Text(account.displayName).tag(UUID?.some(account.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }

                    if let branch = item.branchName {
                        LabeledContent("分支") {
                            Text(branch)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 320, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
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
            Button("保存") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
        }
        .padding(16)
    }

    private func save() {
        saving = true
        errorMessage = nil
        do {
            try store.saveWorkstations(items, project: project, appState: appState)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            saving = false
        }
    }
}
