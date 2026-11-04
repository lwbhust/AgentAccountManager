import AppKit
import SwiftUI
import Core

@main
struct AgentAccountManagerApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Core 不依赖 AppKit：LaunchServices 兜底查询由装配层注入。
        // 必须在 AppState 创建前完成（首个窗口渲染前 init 一定先执行）。
        Platform.launchServicesApplicationResolver = { bundleId in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.contentMinSize)
        // 隐藏标题栏：避免侧边栏与标题栏交界的圆角缺口和悬浮标题，
        // 窗口拖动由顶部工具条承担，应用名在菜单栏 / Dock 仍然可见。
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("工作台") {
                Button("打开工作台") {
                    openWindow(id: "workbench")
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
            }

            CommandMenu("快速切换") {
                Button("显示 / 隐藏桌面小部件") {
                    QuickSwitchPanelController.shared.toggle(appState: appState)
                }
                .keyboardShortcut("k", modifiers: [.command, .option])
            }

            CommandMenu("账号") {
                Button("打开所选账号") {
                    appState.openSelectedAccount()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(appState.selectedAccount == nil)

                Button("启动空白窗口") {
                    guard let account = appState.selectedAccount else { return }
                    do {
                        _ = try appState.openAccountApp(account, workspace: nil)
                        appState.toast = "已打开该账号空白窗口"
                    } catch {
                        appState.errorMessage = "打开账号失败：\(error.localizedDescription)"
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(appState.selectedAccount == nil)

                Divider()

                Button(appState.selectedAccount.map {
                    appState.isFavorite($0.id) ? "取消收藏所选账号" : "收藏所选账号"
                } ?? "收藏所选账号") {
                    appState.toggleFavoriteSelected()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(appState.selectedAccount == nil)

                Divider()

                Button("聚焦搜索") {
                    appState.isSearchPresented = true
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("立即采集任务") {
                    Task { await appState.collectTraeTasks() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Window("三工位工作台", id: "workbench") {
            WorkbenchRootView()
                .environmentObject(appState)
        }
        .defaultSize(width: 1100, height: 740)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
