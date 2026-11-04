import AppKit
import SwiftUI

enum MainWindowID {
    static let identifier = NSUserInterfaceItemIdentifier("main.accountManager")
}

/// 给主窗口设置稳定 identifier，不改变现有布局。
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

@MainActor
enum WindowRouter {
    private static var fullScreenObservers: [NSObjectProtocol] = []
    private static weak var observedWindow: NSWindow?

    static func tagMainWindow(_ window: NSWindow?) {
        window?.identifier = MainWindowID.identifier
        // 标题栏透明化：让窗口背景图直接延伸到窗口顶部，
        // 工具栏按钮悬浮在背景上，避免顶部出现一条不透明的材质带。
        window?.titlebarAppearsTransparent = true

        guard let window, window !== observedWindow else { return }
        observedWindow = window

        // 全屏时系统会在窗口顶部绘制一条不透明的工具栏底色带，
        // 与沉浸式背景冲突；进入全屏时隐藏工具栏，退出时恢复显示。
        fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        fullScreenObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { _ in window.toolbar?.isVisible = false },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { _ in window.toolbar?.isVisible = true }
        ]

    }

    static func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier == MainWindowID.identifier }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
