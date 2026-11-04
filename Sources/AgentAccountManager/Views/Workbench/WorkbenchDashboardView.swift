import SwiftUI
import Core

struct WorkbenchDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: WorkbenchStore
    let project: Project

    private var lanes: [Workstation] {
        store.workstations(for: project.id)
    }

    private var traeAccounts: [Account] {
        appState.accounts.filter { $0.platform == .trae }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                banners

                if lanes.isEmpty {
                    ContentUnavailableView(
                        "还没有工位",
                        systemImage: "rectangle.3.group",
                        description: Text("打开工位设置，配置 2-3 个工位后再开工。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 330), spacing: 14)],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(lanes) { workstation in
                            let account = store.account(for: workstation.accountId, in: appState)
                            WorkstationCardView(
                                project: project,
                                workstation: workstation,
                                account: account,
                                runtime: store.runtimeSnapshot(for: workstation.accountId),
                                latestTask: store.latestTask(for: workstation.accountId),
                                accounts: traeAccounts,
                                onSelectAccount: { accountId in
                                    selectAccount(accountId, for: workstation)
                                },
                                onStart: {
                                    guard let account else { return }
                                    Task {
                                        await store.prepareStart(
                                            workstation: workstation,
                                            project: project,
                                            account: account,
                                            appState: appState
                                        )
                                    }
                                },
                                onCalibrate: { store.showCalibration($0) },
                                onSwitchFlow: { store.showSwitchFlow($0) },
                                onOpenAccount: { store.openAccountInManager($0, appState: appState) },
                                onSettings: { store.showingWorkstationSettings = true }
                            )
                        }
                    }
                }

                projectInfo
                if let memory = project.projectMemory?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !memory.isEmpty {
                    SectionCard(title: "项目记忆") {
                        Text(memory)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(project.displayName)
                        .font(.title2.weight(.semibold))
                    TagChip(
                        text: project.modeBadge,
                        color: project.orchestrationMode == .rolePlay ? .purple : .secondary
                    )
                }
                Text(project.repoPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(project.repoPath)
                Text("基线分支：\(project.baselineBranch)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    store.projectFormMode = .edit(project)
                } label: {
                    Label("编辑项目", systemImage: "square.and.pencil")
                }

                Button {
                    store.showingWorkstationSettings = true
                } label: {
                    Label("工位设置", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if traeAccounts.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                InlineBanner(
                    kind: .warning,
                    text: "还没有可用的 TRAE 账号。请先在账号管理器中添加账号，再为工位绑定。"
                )
                Button("打开账号管理器") {
                    WindowRouter.activateMainWindow()
                }
                .controlSize(.small)
            }
        }
        if !lanes.contains(where: \.isEnabled) {
            InlineBanner(
                kind: .info,
                text: "当前没有启用的工位。打开工位设置启用至少一个工位后再开工。"
            )
        }
    }

    private var projectInfo: some View {
        SectionCard(title: "项目信息") {
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(label: "仓库", value: project.repoPath)
                InfoRow(label: "基线分支", value: project.baselineBranch)
                InfoRow(label: "编排模式", value: project.orchestrationMode.displayName)
                InfoRow(
                    label: "工作树根目录",
                    value: project.worktreeRoot ?? WorkstationService.defaultWorktreeRoot.path
                )
                if let build = project.buildCommand, !build.isEmpty {
                    InfoRow(label: "构建命令", value: build)
                }
                if let test = project.testCommand, !test.isEmpty {
                    InfoRow(label: "测试命令", value: test)
                }
                if let setup = project.setupHint, !setup.isEmpty {
                    InfoRow(label: "初始化提示", value: setup)
                }
                if let note = project.note, !note.isEmpty {
                    InfoRow(label: "备注", value: note)
                }
            }
        }
    }

    private func selectAccount(_ accountId: UUID?, for workstation: Workstation) {
        do {
            try store.assignAccount(
                workstation: workstation,
                accountId: accountId,
                appState: appState
            )
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}
