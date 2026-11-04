import Foundation
import WidgetKit

/// 只在真实 App 进程里通知 WidgetKit 刷新，测试进程不触发系统服务。
enum WidgetCenterBridge {
    static func reloadTimelines() {
        guard Bundle.main.bundleIdentifier == "com.agentaccountmanager.app" else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
