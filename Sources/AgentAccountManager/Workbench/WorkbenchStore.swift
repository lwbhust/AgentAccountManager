import AppKit
import Foundation
import SwiftUI
import Core

/// 工作台窗口的 UI 状态。
///
/// 项目/工位列表由这里懒加载；账号、运行状态、任务和积分仍从 `AppState` 只读。
@MainActor
final class WorkbenchStore: ObservableObject {
    enum ProjectFormMode: Identifiable {
        case create
        case edit(Project)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let project): return project.id.uuidString
            }
        }
    }

    struct RuntimeSnapshot: Sendable, Equatable {
        let isRunning: Bool
        let openWorkspaces: [URL]
    }

    struct ProjectDraft {
        var displayName: String = ""
        var repoPath: String = ""
        var baselineBranch: String = ""
        var orchestrationMode: Project.OrchestrationMode = .freeLane
        var buildCommand: String = ""
        var testCommand: String = ""
        var setupHint: String = ""
        var worktreeRoot: String = ""
        var projectMemory: String = ""
        var note: String = ""

        init() {}

        init(project: Project) {
            displayName = project.displayName
            repoPath = project.repoPath
            baselineBranch = project.baselineBranch
            orchestrationMode = project.orchestrationMode
            buildCommand = project.buildCommand ?? ""
            testCommand = project.testCommand ?? ""
            setupHint = project.setupHint ?? ""
            worktreeRoot = project.worktreeRoot ?? ""
            projectMemory = project.projectMemory ?? ""
            note = project.note ?? ""
        }
    }

    @Published var projects: [Project] = []
    @Published var workstations: [Workstation] = []
    @Published var selectedProjectId: UUID?
    @Published var latestTasks: [UUID: TraeTask] = [:]
    @Published var runtime: [UUID: RuntimeSnapshot] = [:]

    @Published var projectFormMode: ProjectFormMode?
    @Published var showingWorkstationSettings = false
    @Published var preparation: WorkbenchService.StartPreparation?
    @Published var calibrationAccount: Account?
    @Published var switchFlowAccount: Account?
    @Published var toast: String?
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var busyText: String?

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId }
    }

    func workstations(for projectId: UUID) -> [Workstation] {
        workstations
            .filter { $0.projectId == projectId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func enabledWorkstations(for projectId: UUID) -> [Workstation] {
        workstations(for: projectId).filter(\.isEnabled)
    }

    func runtimeSnapshot(for accountId: UUID?) -> RuntimeSnapshot? {
        guard let accountId else { return nil }
        return runtime[accountId]
    }

    func latestTask(for accountId: UUID?) -> TraeTask? {
        guard let accountId else { return nil }
        return latestTasks[accountId]
    }

    func account(for id: UUID?, in appState: AppState) -> Account? {
        guard let id else { return nil }
        return appState.account(id: id)
    }

    func traeAccounts(in appState: AppState) -> [Account] {
        appState.accounts.filter { $0.platform == .trae }
    }

    // MARK: - 加载

    func load(from appState: AppState) {
        guard let projectService = appState.projectService,
              let workstationService = appState.workstationService else {
            errorMessage = "项目/工位服务不可用，请重启应用后重试。"
            return
        }
        do {
            projects = try projectService.listAll()
            workstations = try workstationService.listAll()
            if let selectedProjectId,
               projects.contains(where: { $0.id == selectedProjectId }) {
                // 保持当前选择
            } else {
                selectedProjectId = projects.first?.id
            }
            refreshDynamicData(from: appState)
        } catch {
            errorMessage = "加载工作台失败：\(error.localizedDescription)"
        }
    }

    func refreshDynamicData(from appState: AppState) {
        var tasks: [UUID: TraeTask] = [:]
        var snapshots: [UUID: RuntimeSnapshot] = [:]
        for account in appState.accounts where account.platform == .trae {
            if let task = appState.latestTask(for: account.id) {
                tasks[account.id] = task
            }
            snapshots[account.id] = RuntimeSnapshot(
                isRunning: appState.runningTraeAccountIds.contains(account.id),
                openWorkspaces: appState.openWorkspaces(for: account)
            )
        }
        latestTasks = tasks
        runtime = snapshots
    }

    // MARK: - 项目

    /// 通过注入的 AppState 保存；由视图调用时使用。
    func saveProject(
        draft: ProjectDraft,
        editing project: Project?,
        appState: AppState
    ) throws {
        guard let projectService = appState.projectService,
              let workstationService = appState.workstationService else {
            throw WorkbenchStoreError.servicesUnavailable
        }
        if let project {
            let updated = try projectService.update(
                id: project.id,
                displayName: draft.displayName,
                repoPath: draft.repoPath,
                baselineBranch: draft.baselineBranch,
                orchestrationMode: draft.orchestrationMode,
                buildCommand: draft.buildCommand,
                testCommand: draft.testCommand,
                setupHint: draft.setupHint,
                worktreeRoot: draft.worktreeRoot,
                projectMemory: draft.projectMemory,
                note: draft.note
            )
            guard updated != nil else { throw WorkbenchStoreError.projectNotFound }
            selectedProjectId = project.id
            toast = "项目已保存"
        } else {
            let created = try projectService.create(
                displayName: draft.displayName,
                repoPath: draft.repoPath,
                baselineBranch: draft.baselineBranch,
                orchestrationMode: draft.orchestrationMode,
                buildCommand: draft.buildCommand,
                testCommand: draft.testCommand,
                setupHint: draft.setupHint,
                worktreeRoot: draft.worktreeRoot,
                projectMemory: draft.projectMemory,
                note: draft.note
            )
            do {
                _ = try workstationService.createDefaults(for: created)
            } catch {
                _ = try? projectService.delete(id: created.id)
                throw error
            }
            selectedProjectId = created.id
            toast = "项目已创建，已生成默认工位"
        }
        projectFormMode = nil
        load(from: appState)
    }

    func deleteProject(_ project: Project, appState: AppState) {
        do {
            _ = try appState.projectService?.delete(id: project.id)
            load(from: appState)
            toast = "项目已删除；worktree 目录仍保留在磁盘上"
        } catch {
            errorMessage = "删除项目失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 工位

    func saveWorkstations(
        _ items: [Workstation],
        project: Project,
        appState: AppState
    ) throws {
        guard let service = appState.workstationService else {
            throw WorkbenchStoreError.servicesUnavailable
        }
        try service.updateBatch(project: project, workstations: items)
        load(from: appState)
        showingWorkstationSettings = false
        toast = "工位设置已保存"
    }

    func assignAccount(
        workstation: Workstation,
        accountId: UUID?,
        appState: AppState
    ) throws {
        guard let service = appState.workstationService else {
            throw WorkbenchStoreError.servicesUnavailable
        }
        try service.assignAccount(workstationId: workstation.id, accountId: accountId)
        workstations = try service.listAll()
        refreshDynamicData(from: appState)
    }

    // MARK: - 开工

    func prepareStart(
        workstation: Workstation,
        project: Project,
        account: Account,
        appState: AppState
    ) async {
        guard let service = appState.workbenchService else {
            errorMessage = "工作台服务不可用，请重启应用后重试。"
            return
        }
        let runtime = makeRuntimeContext(
            workstation: workstation,
            account: account,
            appState: appState
        )
        isBusy = true
        busyText = "正在检查仓库与工位状态…"
        defer {
            isBusy = false
            busyText = nil
        }
        do {
            let prep = try await Task.detached(priority: .userInitiated) {
                try service.prepareStart(
                    project: project,
                    workstation: workstation,
                    account: account,
                    runtime: runtime
                )
            }.value
            preparation = prep
        } catch {
            errorMessage = "预检失败：\(error.localizedDescription)"
        }
    }

    func confirmStart(
        preparation: WorkbenchService.StartPreparation,
        task: String,
        appState: AppState
    ) async {
        guard let service = appState.workbenchService else {
            errorMessage = "工作台服务不可用，请重启应用后重试。"
            return
        }
        isBusy = true
        busyText = preparation.willCreateWorktree ? "正在创建 worktree…" : "正在准备工位…"
        defer {
            isBusy = false
            busyText = nil
        }
        do {
            let plan = try await Task.detached(priority: .userInitiated) {
                try service.executeStart(preparation: preparation, task: task)
            }.value

            let activated = try appState.openAccountApp(
                plan.account,
                workspace: plan.worktreeURL,
                visitSource: "workbench"
            )
            try? appState.workstationService?.touchLastActivated(id: plan.workstation.id)

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(plan.contextPack, forType: .string)

            self.preparation = nil
            toast = activated
                ? "已激活工位窗口，上下文包已复制到剪贴板"
                : "工位已启动，上下文包已复制到剪贴板"
            load(from: appState)
        } catch {
            errorMessage = "开工失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 跨窗口导航

    func openAccountInManager(_ account: Account, appState: AppState) {
        appState.selectAccount(id: account.id)
        WindowRouter.activateMainWindow()
    }

    func showCalibration(_ account: Account) {
        calibrationAccount = account
    }

    func showSwitchFlow(_ account: Account) {
        switchFlowAccount = account
    }

    // MARK: - 私有

    private func makeRuntimeContext(
        workstation: Workstation,
        account: Account,
        appState: AppState
    ) -> StartupPreflight.RuntimeContext {
        let open = appState.openWorkspaces(for: account)
        let target = workstation.worktreeURL ?? URL(fileURLWithPath: "")
        let openPaths = Set(open.map { $0.standardizedFileURL.path })
        let other = workstations.first { item in
            guard item.id != workstation.id,
                  item.isEnabled,
                  item.accountId == account.id,
                  let path = item.worktreePath else { return false }
            return openPaths.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
        }
        var laneLabel: String?
        if let other,
           let project = projects.first(where: { $0.id == other.projectId }) {
            laneLabel = "「\(project.displayName) / \(other.displayName)」"
        }
        return StartupPreflight.RuntimeContext(
            isAccountRunning: appState.runningTraeAccountIds.contains(account.id),
            openWorkspaces: open,
            targetWorktree: target,
            runningLaneLabel: laneLabel
        )
    }
}

enum WorkbenchStoreError: LocalizedError {
    case servicesUnavailable
    case projectNotFound

    var errorDescription: String? {
        switch self {
        case .servicesUnavailable: return "项目/工位服务不可用，请重启应用后重试。"
        case .projectNotFound: return "项目不存在"
        }
    }
}
