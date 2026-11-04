import AppKit
import SwiftUI
import Core

/// 桌面快速切换小部件的窗口控制器。
///
/// 使用无边框 `NSPanel` 而不是 WidgetKit：
/// 小部件需要在点击后直接唤醒 TRAE 独立实例或 WorkBuddy 客户端，
/// WidgetKit 扩展无法直接调用这些 AppKit 服务，也会引入额外的扩展签名与
/// 数据共享成本。这里用一个不抢焦点的悬浮面板实现同样的「桌面常驻」体验。
@MainActor
final class QuickSwitchPanelController: ObservableObject {
    static let shared = QuickSwitchPanelController()

    private enum DefaultsKey {
        static let visible = "quickSwitchPanelVisible"
        static let pinned = "quickSwitchPanelPinned"
    }

    private enum Layout {
        static let size = NSSize(width: 340, height: 460)
        static let edgeInset: CGFloat = 20
        static let frameAutosaveName = "QuickSwitchPanelFrame"
    }

    @Published private(set) var isVisible = false
    /// 置顶时小部件浮在其他应用窗口上方；关闭后回到普通窗口层级。
    @Published private(set) var isPinned = true

    private var panel: QuickSwitchPanel?
    private weak var appState: AppState?
    private var didRestoreVisibility = false

    private init() {}

    /// 注入全局状态；可重复调用，不会重复创建窗口。
    func configure(appState: AppState) {
        self.appState = appState
        if let stored = UserDefaults.standard.object(forKey: DefaultsKey.pinned) as? Bool {
            isPinned = stored
        }
    }

    /// 应用启动时恢复上次的小部件可见状态（只执行一次）。
    func restoreIfNeeded(appState: AppState) {
        configure(appState: appState)
        guard !didRestoreVisibility else { return }
        didRestoreVisibility = true
        guard UserDefaults.standard.bool(forKey: DefaultsKey.visible) else { return }
        show()
    }

    func toggle(appState: AppState) {
        configure(appState: appState)
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let appState else { return }
        let panel = panel ?? makePanel(appState: appState)
        self.panel = panel
        panel.level = isPinned ? .floating : .normal
        // 打开面板时刷新一次外部状态，避免显示过期的「运行中」与最近项目。
        appState.refreshRunningState()
        appState.refreshRecentProjects()
        panel.orderFrontRegardless()
        isVisible = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.visible)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        UserDefaults.standard.set(false, forKey: DefaultsKey.visible)
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        UserDefaults.standard.set(pinned, forKey: DefaultsKey.pinned)
        panel?.level = pinned ? .floating : .normal
    }

    /// 根据内容行数调整面板高度；以顶部为锚点，避免内容变化时小部件上下跳动。
    private func resizePanel(to height: CGFloat) {
        guard let panel else { return }
        var frame = panel.frame
        let clamped = min(max(height, 250), 460)
        guard abs(frame.height - clamped) > 0.5 else { return }
        let top = frame.maxY
        frame.size.height = clamped
        frame.origin.y = top - clamped
        panel.setFrame(frame, display: true)
    }

    // MARK: - 窗口

    private func makePanel(appState: AppState) -> QuickSwitchPanel {
        let panel = QuickSwitchPanel(
            contentRect: NSRect(origin: .zero, size: Layout.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = isPinned ? .floating : .normal
        panel.onEscape = { [weak self] in self?.hide() }
        // 先记录窗口，内容视图 onAppear 回调时才能调整高度。
        self.panel = panel

        let root = QuickSwitchView(
            controller: self,
            onPreferredHeightChange: { [weak self] height in
                self?.resizePanel(to: height)
            },
            onClose: { [weak self] in self?.hide() }
        )
        .environmentObject(appState)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: Layout.size)
        panel.contentView = hostingView
        panel.setContentSize(Layout.size)

        if let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let origin = NSPoint(
                x: visibleFrame.maxX - Layout.size.width - Layout.edgeInset,
                y: visibleFrame.maxY - Layout.size.height - Layout.edgeInset
            )
            panel.setFrame(NSRect(origin: origin, size: Layout.size), display: false)
        } else {
            panel.center()
        }
        panel.setFrameAutosaveName(Layout.frameAutosaveName)
        return panel
    }
}

/// 无边框面板需要显式允许成为 key window，同时保留 Esc 关闭行为。
final class QuickSwitchPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
