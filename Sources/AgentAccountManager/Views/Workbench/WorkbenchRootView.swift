import SwiftUI
import Core

struct WorkbenchRootView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var store = WorkbenchStore()

    var body: some View {
        NavigationSplitView {
            ProjectSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .navigationTitle("三工位工作台")
        .toolbar { toolbar }
        .task {
            store.load(from: appState)
            appState.startAutoRefreshIfNeeded()
        }
        .onChange(of: appState.accountRevision) { _, _ in
            store.load(from: appState)
        }
        .onChange(of: appState.taskRevision) { _, _ in
            store.refreshDynamicData(from: appState)
        }
        .onChange(of: appState.runningTraeAccountIds) { _, _ in
            store.refreshDynamicData(from: appState)
        }
        .onOpenURL { url in
            _ = appState.handleWidgetDeepLink(url)
        }
        .sheet(item: $store.projectFormMode) { mode in
            ProjectFormView(store: store, editing: mode.project)
        }
        .sheet(isPresented: $store.showingWorkstationSettings) {
            if let project = store.selectedProject {
                WorkstationSettingsView(project: project, store: store)
            }
        }
        .sheet(item: $store.preparation) { preparation in
            StartupConfirmView(store: store, preparation: preparation)
        }
        .sheet(item: $store.calibrationAccount) { account in
            CreditEntryView(
                account: account,
                referenceEstimate: appState.creditBalance(for: account.id),
                onSaved: { message in store.toast = message }
            )
        }
        .sheet(item: $store.switchFlowAccount) { account in
            SwitchFlowView(account: account) { text, _ in
                store.toast = text
            }
        }
        .alert("操作失败", isPresented: errorPresented) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .overlay(alignment: .top) { toastOverlay }
        .overlay { busyOverlay }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder
    private var detail: some View {
        if !appState.isDatabaseReady {
            ContentUnavailableView {
                Label("数据库不可用", systemImage: "exclamationmark.triangle")
            } description: {
                Text(appState.errorMessage ?? "请重启应用后重试。")
            }
        } else if store.projects.isEmpty {
            ContentUnavailableView {
                Label("新建第一个项目", systemImage: "square.grid.2x2")
            } description: {
                Text("把仓库、基线分支和 2-3 个工位组合成一套可复用的工作台。")
            } actions: {
                Button("新建项目") {
                    store.projectFormMode = .create
                }
                .buttonStyle(.borderedProminent)
                Button("打开账号管理器") {
                    WindowRouter.activateMainWindow()
                }
            }
        } else if let project = store.selectedProject {
            WorkbenchDashboardView(store: store, project: project)
        } else {
            ContentUnavailableView(
                "选择一个项目",
                systemImage: "folder",
                description: Text("在左侧选择项目查看工位。")
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button {
                store.load(from: appState)
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("重新加载项目与工位")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                QuickSwitchPanelController.shared.toggle(appState: appState)
            } label: {
                Label("快速切换", systemImage: "bolt.horizontal.circle")
            }
            .help("显示 / 隐藏桌面快速切换小部件（⌥⌘K）")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                WindowRouter.activateMainWindow()
            } label: {
                Label("账号管理器", systemImage: "person.crop.circle")
            }
            .help("切换到账号管理器窗口")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.projectFormMode = .create
            } label: {
                Label("新建项目", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("新建项目（⇧⌘N）")
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = store.toast {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.6)))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    withAnimation(.easeOut(duration: 0.2)) {
                        store.toast = nil
                    }
                }
        }
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if store.isBusy && store.preparation == nil {
            ZStack {
                Color.black.opacity(0.06)
                    .ignoresSafeArea()
                VStack(spacing: 8) {
                    ProgressView()
                    Text(store.busyText ?? "正在处理…")
                        .font(.callout)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { newValue in if !newValue { store.errorMessage = nil } }
        )
    }
}

extension WorkbenchStore.ProjectFormMode {
    var project: Project? {
        if case .edit(let project) = self { return project }
        return nil
    }
}
