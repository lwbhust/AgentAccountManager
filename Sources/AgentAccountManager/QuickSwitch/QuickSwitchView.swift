import AppKit
import SwiftUI
import Core

enum QuickSwitchTab: String, CaseIterable, Identifiable {
    case accounts
    case projects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: return "账号"
        case .projects: return "项目"
        }
    }
}

/// 桌面快速切换小部件的内容。
///
/// 结构保持紧凑：顶部状态与关闭/置顶，中部页签，底部回到主窗口。
/// 账号点击即恢复上次项目；项目点击即在所属账号实例中打开。
struct QuickSwitchView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: QuickSwitchPanelController
    let onPreferredHeightChange: (CGFloat) -> Void
    let onClose: () -> Void

    @AppStorage("quickSwitchPanelTab") private var tabRawValue = QuickSwitchTab.accounts.rawValue
    @State private var feedback: Feedback?
    @State private var searchText = ""

    private struct Feedback: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    private var tab: QuickSwitchTab {
        QuickSwitchTab(rawValue: tabRawValue) ?? .accounts
    }

    private var tabBinding: Binding<QuickSwitchTab> {
        Binding(
            get: { tab },
            set: { tabRawValue = $0.rawValue }
        )
    }

    // MARK: - 搜索过滤

    private var filteredAccounts: [Account] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return appState.quickSwitchAccounts }
        return appState.quickSwitchAccounts.filter { account in
            account.displayName.localizedCaseInsensitiveContains(query)
                || account.phoneDisplay.localizedCaseInsensitiveContains(query)
                || (account.planType?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var filteredProjects: [AppState.RecentProjectShortcut] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return appState.recentProjectShortcuts }
        return appState.recentProjectShortcuts.filter { item in
            item.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                || item.accountName.localizedCaseInsensitiveContains(query)
        }
    }

    /// 搜索命中的第一个结果，Enter 直达（键盘切换的主要路径）。
    private var primaryHitAction: (() -> Void)? {
        switch tab {
        case .accounts:
            guard let first = filteredAccounts.first else { return nil }
            return { [weak appState] in
                guard let appState else { return }
                _ = try? appState.openAccountApp(
                    first,
                    workspace: appState.quickOpenWorkspace(for: first),
                    visitSource: "widget"
                )
            }
        case .projects:
            guard let first = filteredProjects.first else { return nil }
            return { [weak appState] in
                guard let appState,
                      let account = appState.account(id: first.accountId) else { return }
                _ = try? appState.openAccountApp(account, workspace: first.url, visitSource: "widget")
            }
        }
    }

    private var runningCount: Int {
        appState.accounts.filter { appState.isRunning($0) }.count
    }

    /// 按当前页签的行数计算面板高度：列表最多展示 8 行，其余滚动。
    private var preferredHeight: CGFloat {
        let rows = tab == .accounts
            ? max(filteredAccounts.count, searchText.isEmpty ? 0 : 1)
            : max(filteredProjects.count, searchText.isEmpty ? 0 : 1)
        guard rows > 0 else { return 338 }
        let visibleRows = min(rows, 8)
        // 头部 51 + 页签 29 + 搜索 30 + 两条分隔线 + 列表（标题 27 + 每行 40）+ 底部 30
        let height = 51 + 29 + 30 + 2 + (27 + CGFloat(visibleRows) * 40) + 30
        return min(CGFloat(height), 500)
    }

    private var summaryText: String {
        if appState.accounts.isEmpty {
            return "还没有账号"
        }
        var parts = ["\(appState.accounts.count) 个账号"]
        if runningCount > 0 { parts.append("\(runningCount) 个运行中") }
        parts.append("\(appState.recentProjectShortcuts.count) 个最近项目")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            searchBar
            Divider().opacity(0.55)
            content
            Divider().opacity(0.55)
            footer
        }
        .frame(width: 340, height: preferredHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.8)
        )
        .overlay(alignment: .bottom) { feedbackOverlay }
        .animation(.easeOut(duration: 0.18), value: feedback?.id)
        .onAppear {
            onPreferredHeightChange(preferredHeight)
        }
        .onChange(of: preferredHeight) { _, newValue in
            onPreferredHeightChange(newValue)
        }
        .task {
            appState.refreshRunningState()
            appState.refreshRecentProjects()
        }
        .task(id: feedback?.id) {
            guard feedback != nil else { return }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                feedback = nil
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("快速切换")
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 4) {
                    if runningCount > 0 {
                        Circle()
                            .fill(.green)
                            .frame(width: 5, height: 5)
                    }
                    Text(summaryText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button {
                controller.setPinned(!controller.isPinned)
            } label: {
                Image(systemName: controller.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(controller.isPinned ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.isPinned ? "取消置顶：小部件会随其他窗口一起被遮挡" : "置顶：始终浮在其他窗口上方")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭小部件（Esc）")
        }
        .padding(.horizontal, 13)
        .padding(.top, 11)
        .padding(.bottom, 9)
        .background(WindowDragArea())
    }

    private var tabPicker: some View {
        Picker("快速切换范围", selection: tabBinding) {
            Text("\(QuickSwitchTab.accounts.title) \(appState.accounts.count)")
                .tag(QuickSwitchTab.accounts)
            Text("\(QuickSwitchTab.projects.title) \(appState.recentProjectShortcuts.count)")
                .tag(QuickSwitchTab.projects)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
    }

    /// 搜索框：键盘切换的主入口。Enter 打开第一个命中结果，Esc 语义交给面板层。
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField("搜索账号或项目", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    primaryHitAction?()
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.8)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        Group {
            switch tab {
            case .accounts:
                accountContent
            case .projects:
                projectContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var accountContent: some View {
        if appState.accounts.isEmpty {
            emptyState(
                icon: "person.crop.circle.badge.plus",
                title: "还没有账号",
                message: "在账号管理器中新增账号后，就能在这里一键切换。"
            )
        } else if filteredAccounts.isEmpty {
            emptyState(
                icon: "magnifyingglass",
                title: "没有匹配的账号",
                message: "换个关键字试试，或清空搜索。"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    sectionCaption("点击打开，优先恢复该账号的上次项目；⏎ 打开第一个结果")
                    ForEach(filteredAccounts) { account in
                        QuickAccountRow(
                            account: account,
                            isFavorite: appState.isFavorite(account.id),
                            isRunning: appState.isRunning(account),
                            onOpen: {
                                openAccount(account, workspace: appState.quickOpenWorkspace(for: account))
                            },
                            onOpenBlank: {
                                openAccount(account, workspace: nil)
                            },
                            onToggleFavorite: {
                                toggleFavorite(account)
                            },
                            onReveal: {
                                reveal(account)
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }
        }
    }

    @ViewBuilder
    private var projectContent: some View {
        if appState.recentProjectShortcuts.isEmpty {
            emptyState(
                icon: "folder.badge.questionmark",
                title: "还没有最近项目",
                message: "在 TRAE 或工作台中打开项目后，会出现在这里。"
            )
        } else if filteredProjects.isEmpty {
            emptyState(
                icon: "magnifyingglass",
                title: "没有匹配的项目",
                message: "换个关键字试试，或清空搜索。"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    sectionCaption("近 7 天 · 点击在所属账号中打开")
                    ForEach(filteredProjects) { item in
                        QuickProjectRow(item: item) {
                            openProject(item)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }
        }
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.bottom, 3)
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                WindowRouter.activateMainWindow()
            } label: {
                Label("账号管理器", systemImage: "person.crop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("打开账号管理器主窗口")

            Spacer()

            Text("⌥ ⌘ K 呼出")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help("显示 / 隐藏快速切换小部件")

            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("刷新运行状态与最近项目")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035))
    }

    @ViewBuilder
    private var feedbackOverlay: some View {
        if let feedback {
            Text(feedback.text)
                .font(.system(size: 10.5))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thickMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
                .padding(.horizontal, 16)
                .padding(.bottom, 46)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 操作

    private func openAccount(_ account: Account, workspace: URL?) {
        guard appState.isDatabaseReady else {
            announce("数据库不可用，请打开账号管理器检查")
            return
        }
        let target = workspace?.lastPathComponent ?? "空白窗口"
        announce("正在打开「\(account.displayName)」· \(target)…")
        do {
            let activated = try appState.openAccountApp(account, workspace: workspace, visitSource: "widget")
            announce(activated ? "已激活「\(account.displayName)」" : "已打开「\(account.displayName)」")
        } catch {
            announce("打开失败：\(error.localizedDescription)")
        }
    }

    private func openProject(_ item: AppState.RecentProjectShortcut) {
        guard let account = appState.account(id: item.accountId) else {
            announce("该项目的所属账号已不存在")
            return
        }
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            announce("项目目录已不存在，请刷新最近项目")
            return
        }
        openAccount(account, workspace: item.url)
    }

    private func toggleFavorite(_ account: Account) {
        appState.toggleFavorite(account.id)
        announce(appState.isFavorite(account.id)
            ? "已收藏「\(account.displayName)」"
            : "已取消收藏「\(account.displayName)」")
    }

    private func reveal(_ account: Account) {
        appState.selectAccount(id: account.id)
        WindowRouter.activateMainWindow()
        announce("已在账号管理器中选中「\(account.displayName)」")
    }

    private func refresh() {
        appState.refreshRunningState()
        appState.refreshRecentProjects()
        announce("已刷新运行状态与最近项目")
    }

    private func announce(_ text: String) {
        withAnimation(.easeOut(duration: 0.16)) {
            feedback = Feedback(text: text)
        }
    }
}

// MARK: - 账号行

private struct QuickAccountRow: View {
    let account: Account
    let isFavorite: Bool
    let isRunning: Bool
    let onOpen: () -> Void
    let onOpenBlank: () -> Void
    let onToggleFavorite: () -> Void
    let onReveal: () -> Void

    @State private var isHovering = false

    private var platformColor: Color {
        account.platform == .workbuddy ? .blue : .purple
    }

    private var detailText: String {
        var parts = [account.platform.displayName]
        if let plan = account.planType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty {
            parts.append(plan)
        }
        if isRunning {
            parts.append(account.platform == .workbuddy ? "客户端已打开" : "运行中")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                avatar

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(account.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.yellow)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 5) {
                        Text(detailText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        // 待核对是真正需要行动的状态，从灰色串里拆出来单独标记。
                        if account.lastLoginStatus == .pendingConfirmation {
                            Text("待核对")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(DS.Status.needsAttention)
                        }
                    }
                }

                Spacer(minLength: 6)

                if isRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                        .help(account.platform == .workbuddy
                            ? "WorkBuddy 客户端在运行（不代表登录的是该账号）"
                            : "该账号的独立实例正在运行")
                }

                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundStyle(isHovering ? Color.accentColor : Color.secondary.opacity(0.7))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("打开并恢复上次项目", action: onOpen)
            Button("启动空白窗口", action: onOpenBlank)
            Divider()
            Button(isFavorite ? "取消收藏" : "收藏", action: onToggleFavorite)
            Divider()
            Button("在账号管理器中查看", action: onReveal)
        }
        .help("打开「\(account.displayName)」；右键查看更多操作")
    }

    private var avatar: some View {
        Text(String(account.displayName.prefix(1)))
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(platformColor)
            .frame(width: 26, height: 26)
            .background(platformColor.opacity(0.14), in: Circle())
            .overlay(Circle().stroke(platformColor.opacity(0.25), lineWidth: 0.6))
    }
}

// MARK: - 项目行

private struct QuickProjectRow: View {
    let item: AppState.RecentProjectShortcut
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.lastPathComponent)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(item.accountName) · \(Format.relative(item.lastVisitedAt))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundStyle(isHovering ? Color.accentColor : Color.secondary.opacity(0.7))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("在「\(item.accountName)」的独立实例中打开「\(item.url.lastPathComponent)」")
    }
}

// MARK: - 窗口拖动

/// 隐藏标题栏后，用透明区域承担拖动，避免只能从边缘移动小部件。
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
