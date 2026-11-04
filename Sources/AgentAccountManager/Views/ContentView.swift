import SwiftUI
import AppKit
import Core

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var showingAddAccount = false
    @FocusState private var searchFieldFocused: Bool
    @AppStorage(AppearanceSetting.backgroundKey) private var immersiveBackground = true
    @AppStorage(BackgroundPhoto.storageKey) private var backgroundPhotoRaw = BackgroundPhoto.defaultValue.rawValue

    var body: some View {
        ZStack {
            // 整窗唯一的背景：一张图铺满窗口，左右面板共用同一透射源，
            // 不再有系统分栏材质、缝隙或独立裁切造成的白块与断层。
            WindowBackground()

            // 左右无缝拼接：spacing 为 0，中间只有一条贯穿上下的极细分割线。
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 280)

                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 1)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingAddAccount) {
                AccountFormView(mode: .add)
            }
            .overlay(alignment: .top) { toastOverlay }
            .onChange(of: appState.isSearchPresented) { _, presented in
                // ⌘F 或其他入口请求搜索时，把焦点交给自定义搜索框。
                if presented { searchFieldFocused = true }
            }
            .onChange(of: searchFieldFocused) { _, focused in
                appState.isSearchPresented = focused
            }
            .task {
                // 后台刷新由 AppState 统一调度；主窗口和工作台共享同一个循环。
                appState.startAutoRefreshIfNeeded()
                // 首次出现时注入全局状态，并按上次退出时的状态恢复桌面小部件。
                QuickSwitchPanelController.shared.restoreIfNeeded(appState: appState)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                appState.refreshRunningState()
                appState.refreshRecentProjects()
                Task { await appState.collectTraeTasks() }
            }
            .onOpenURL { url in
                _ = appState.handleWidgetDeepLink(url)
            }
            .alert("操作失败", isPresented: errorPresented) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(appState.errorMessage ?? "")
            }
        }
        // 主窗口标记：获取 NSWindow 以便在全屏下统一处理标题栏背景。
        .background(WindowAccessor { WindowRouter.tagMainWindow($0) })
    }

    // MARK: - 侧边栏

    /// 侧边栏采用 Finder/System Settings 标准布局：
    /// 主体是 List.sidebar（自动填满剩余空间），
    /// 顶部用 safeAreaInset 吸住筛选/排序控件，
    /// 底部用 safeAreaInset 吸住"最近项目"面板。
    private var sidebar: some View {
        AccountListView(onAddAccount: { showingAddAccount = true })
            .safeAreaInset(edge: .top, spacing: 0) {
                sidebarHeader
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsRecentProjectPanel {
                    RecentProjectPanel()
                }
            }
    }

    /// 最近项目面板只在「全部」范围、无搜索、且非纯 WorkBuddy 视图时展示。
    private var showsRecentProjectPanel: Bool {
        appState.accountFilter == .all
            && appState.searchText.isEmpty
            && appState.selectedPlatform != .workbuddy
            && !appState.recentProjectShortcuts.isEmpty
    }

    /// 侧边栏头部：平台筛选 + 排序 + 显示范围。
    /// 作为 safeAreaInset 吸顶，padding 紧凑，与上方 List 用分隔线隔开。
    private var sidebarHeader: some View {
        VStack(spacing: 6) {
            translucentSearchField
            HStack(spacing: 6) {
                Menu {
                    Picker("平台筛选", selection: $appState.selectedPlatform) {
                        Text("TRAE \(appState.count(of: .trae))").tag(Platform?.some(.trae))
                        Text("WorkBuddy \(appState.count(of: .workbuddy))").tag(Platform?.some(.workbuddy))
                        Divider()
                        Text("全部 \(appState.count(of: nil))").tag(Platform?.none)
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 4) {
                        Text(platformLabel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Spacer()

                Menu {
                    Picker("排序", selection: $appState.accountSort) {
                        ForEach(AppState.AccountSort.allCases) { sort in
                            Text(sort.displayName).tag(sort)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("排序方式：\(appState.accountSort.displayName)")
            }

            TranslucentSegment(
                items: AppState.AccountFilter.allCases.map {
                    TranslucentSegmentItem(value: $0, label: $0.shortName)
                },
                selection: $appState.accountFilter
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// 通透的搜索框：替代系统 .searchable 的不透明 NSSearchField，
    /// 与整体磨砂背景融为一体；⌘F 焦点通过 isSearchPresented 同步。
    private var translucentSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索名称、手机号、套餐、备注", text: $appState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFieldFocused)
            if !appState.searchText.isEmpty {
                Button {
                    appState.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(DS.Color.cardStroke, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { searchFieldFocused = true }
    }

    private var platformLabel: String {
        switch appState.selectedPlatform {
        case .trae: return "TRAE \(appState.count(of: .trae))"
        case .workbuddy: return "WorkBuddy \(appState.count(of: .workbuddy))"
        case nil: return "全部 \(appState.count(of: nil))"
        }
    }

    // MARK: - 详情

    @ViewBuilder
    private var detail: some View {
        // 背景由窗口根级统一提供，内容保持透明以免遮住极光。
        detailContent
    }

    @ViewBuilder
    private var detailContent: some View {
        if !appState.isDatabaseReady {
            ContentUnavailableView {
                Label("数据库不可用", systemImage: "exclamationmark.triangle")
            } description: {
                Text(appState.errorMessage ?? "请重启应用后重试。")
            }
        } else if let account = appState.selectedAccount {
            AccountDetailView(account: account)
                .id(account.id)
        } else if appState.accounts.isEmpty {
            ContentUnavailableView {
                Label("添加第一个账号", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("账号档案、积分记录和切换历史都只保存在这台 Mac 上，不会改动 WorkBuddy 或 TRAE 的登录配置。")
            } actions: {
                Button("新增账号") { showingAddAccount = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if appState.filteredAccounts.isEmpty && !appState.searchText.trimmed.isEmpty {
            ContentUnavailableView {
                Label("没有匹配的账号", systemImage: "magnifyingglass")
            } description: {
                Text("试试其他关键字，或清空搜索条件。")
            } actions: {
                Button("清空搜索") { appState.searchText = "" }
            }
        } else {
            ContentUnavailableView(
                "选择一个账号",
                systemImage: "person.crop.circle",
                description: Text("在左侧列表选择账号查看详情；⌘↩ 可直接打开所选账号。")
            )
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                ForEach(BackgroundPhoto.allCases) { photo in
                    Button {
                        backgroundPhotoRaw = photo.rawValue
                    } label: {
                        if photo.rawValue == backgroundPhotoRaw {
                            Label(photo.displayName, systemImage: "checkmark")
                        } else {
                            Text(photo.displayName)
                        }
                    }
                }
            } label: {
                Label("背景", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(!immersiveBackground)
            .help("选择沉浸式背景照片")
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
                openWindow(id: "workbench")
            } label: {
                Label("工作台", systemImage: "rectangle.3.group")
            }
            .help("打开三工位工作台（⌥⌘B）")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                Task { await appState.collectTraeTasks() }
            } label: {
                Label("采集任务", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("立即读取 TRAE 日志，采集任务与单任务消耗（⌘R）")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                appState.openSelectedAccount()
            } label: {
                Label("打开所选账号", systemImage: "play.circle")
            }
            .disabled(appState.selectedAccount == nil)
            .help("打开所选账号：优先恢复上次项目，实例已在运行则直接激活（⌘↩）")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAddAccount = true
            } label: {
                Label("新增账号", systemImage: "plus")
            }
            // 工具栏唯一的主操作：高强调样式区分于其余低频图标按钮。
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: [.command, .option])
            .help("新增账号（⌥⌘N）")
        }
    }

    // MARK: - 轻提示

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = appState.toast {
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
                        appState.toast = nil
                    }
                }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { appState.errorMessage != nil && appState.isDatabaseReady },
            set: { newValue in if !newValue { appState.errorMessage = nil } }
        )
    }
}

// MARK: - 最近项目面板

/// 侧边栏底部的固定区域：近 7 天最多 15 条，行高固定，超出可视区域可滚动。
private struct RecentProjectPanel: View {
    @EnvironmentObject private var appState: AppState

    /// 单行固定高度；可视高度取整行数，避免边缘出现半行裁切。
    private static let rowHeight: CGFloat = 28
    private var visibleHeight: CGFloat {
        min(Self.rowHeight * CGFloat(appState.recentProjectShortcuts.count), Self.rowHeight * 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("最近项目")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("近 7 天 · \(appState.recentProjectShortcuts.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 3)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(appState.recentProjectShortcuts) { item in
                        Button {
                            openProject(item)
                        } label: {
                            RecentProjectRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .help("在「\(item.accountName)」的独立实例中打开「\(item.url.lastPathComponent)」")
                    }
                }
            }
            .frame(height: visibleHeight)
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 不再垫整块材质：侧栏本身已是半透明玻璃，垫材质会变成更白的实心底板。
    }

    private func openProject(_ item: AppState.RecentProjectShortcut) {
        guard let account = appState.account(id: item.accountId) else {
            appState.errorMessage = "该项目的账号已不存在"
            return
        }
        do {
            let activated = try appState.openAccountApp(account, workspace: item.url)
            appState.toast = activated
                ? "已在该账号窗口中打开「\(item.url.lastPathComponent)」"
                : "正在打开「\(item.url.lastPathComponent)」"
        } catch {
            appState.errorMessage = "打开项目失败：\(error.localizedDescription)"
        }
    }
}

private struct RecentProjectRow: View {
    let item: AppState.RecentProjectShortcut

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(item.url.lastPathComponent)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.accountName)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        .contentShape(Rectangle())
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
