import AppKit
import SwiftUI
import Core

struct ProjectFormView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: WorkbenchStore
    @Environment(\.dismiss) private var dismiss

    let editing: Project?

    @State private var draft: WorkbenchStore.ProjectDraft
    @State private var branches: [String] = []
    @State private var repoIsGit: Bool?
    @State private var errorMessage: String?
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    init(store: WorkbenchStore, editing: Project? = nil) {
        self.store = store
        self.editing = editing
        _draft = State(initialValue: editing.map { WorkbenchStore.ProjectDraft(project: $0) } ?? WorkbenchStore.ProjectDraft())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 580, height: 650)
        .onAppear {
            if draft.repoPath.isEmpty {
                nameFocused = true
            } else {
                refreshBranches()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(editing == nil ? "新建项目" : "编辑项目")
                    .font(.headline)
                Text("项目只保存仓库、分支、命令和工作台配置，不保存源码或对话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TagChip(
                text: draft.orchestrationMode.displayName,
                color: draft.orchestrationMode == .rolePlay ? .purple : .secondary
            )
        }
        .padding(16)
    }

    private var form: some View {
        Form {
            Section("基本信息") {
                LabeledContent("项目名称") {
                    TextField("必填", text: $draft.displayName)
                        .focused($nameFocused)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 320)
                }

                LabeledContent("仓库") {
                    HStack(spacing: 6) {
                        TextField("选择或输入 Git 仓库路径", text: $draft.repoPath)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 320)
                            .onSubmit { refreshBranches() }
                            .disabled(hasWorktrees)
                        Button("选择…") { chooseRepo() }
                            .controlSize(.small)
                            .disabled(hasWorktrees)
                    }
                }

                LabeledContent("基线分支") {
                    HStack(spacing: 6) {
                        TextField("例如 main", text: $draft.baselineBranch)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 240)
                        Menu("选择") {
                            ForEach(branches, id: \.self) { branch in
                                Button(branch) { draft.baselineBranch = branch }
                            }
                        }
                        .controlSize(.small)
                        .disabled(branches.isEmpty)
                    }
                }

                Picker("编排模式", selection: $draft.orchestrationMode) {
                    ForEach(Project.OrchestrationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(draft.orchestrationMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if repoIsGit == false {
                    InlineBanner(
                        kind: .warning,
                        text: "该路径不是 Git 仓库，无法创建 worktree。请选择仓库根目录。"
                    )
                }
            }

            Section {
                LabeledContent("构建命令") {
                    TextField("可选，例如 swift build", text: $draft.buildCommand)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 320)
                }
                LabeledContent("测试命令") {
                    TextField("可选，例如 swift test", text: $draft.testCommand)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 320)
                }
                LabeledContent("初始化提示") {
                    TextField("可选，例如 npm install", text: $draft.setupHint)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 320)
                }
                LabeledContent("worktree 根目录") {
                    TextField("留空使用 ~/Workbench", text: $draft.worktreeRoot)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 320)
                        .disabled(hasWorktrees)
                }
            } header: {
                Text("命令与初始化提示")
            } footer: {
                if hasWorktrees {
                    Text("项目已有工位，仓库路径和 worktree 根目录不可修改；如需更换请新建项目。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("初始化命令只展示和复制，不会自动执行。worktree 根目录不能指向系统目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                TextEditor(text: $draft.projectMemory)
                    .frame(minHeight: 100)
            } header: {
                Text("项目记忆")
            } footer: {
                Text("会写入开工上下文包，三个账号共享。不要填写密码、Token、Cookie 或完整手机号。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("备注（可选）") {
                TextField("项目备注", text: $draft.note)
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
            Button(editing == nil ? "创建项目" : "保存") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !canSave)
        }
        .padding(16)
    }

    private var canSave: Bool {
        !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.repoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.baselineBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && repoIsGit != false
    }

    private var hasWorktrees: Bool {
        guard let editing else { return false }
        return !store.workstations(for: editing.id).isEmpty
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择仓库"
        panel.message = "选择项目仓库的根目录"
        if panel.runModal() == .OK, let url = panel.url {
            draft.repoPath = url.path
            refreshBranches()
        }
    }

    private func refreshBranches() {
        let path = draft.repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let service = appState.workbenchService else {
            repoIsGit = nil
            branches = []
            return
        }
        repoIsGit = service.isRepository(at: path)
        branches = service.localBranches(repoPath: path).sorted()
        if draft.baselineBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let current = service.currentBranch(repoPath: path), !current.isEmpty {
                draft.baselineBranch = current
            } else if let first = branches.first {
                draft.baselineBranch = first
            }
        }
    }

    private func save() {
        guard canSave else { return }
        let normalizedRepo = ProjectService.normalizePath(draft.repoPath)
        if let service = appState.workbenchService,
           !service.isRepository(at: normalizedRepo) {
            errorMessage = "该路径不是 Git 仓库，无法创建 worktree。"
            return
        }
        saving = true
        errorMessage = nil
        do {
            try store.saveProject(draft: draft, editing: editing, appState: appState)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            saving = false
        }
    }
}
