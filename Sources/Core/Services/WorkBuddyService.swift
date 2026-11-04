import Foundation
import AppKit

/// WorkBuddy 官方能力封装。
///
/// 阶段 A 结论：WorkBuddy 无官方 CLI、无自动切换 API，
/// 仅支持「退出登录 → 重新登录」的人工流程。
/// 本服务只负责打开官方应用与运行状态检测，绝不把“打开应用”当作“已登录”。
public struct WorkBuddyService: Sendable {
    public let appPath: String

    /// - Parameter appPath: 显式指定应用路径；传 nil 时自动查找（/Applications 优先，LaunchServices 兜底）。
    public init(appPath: String? = nil) {
        self.appPath = appPath
            ?? Platform.workbuddy.installedApplicationURL?.path
            ?? Platform.workbuddy.applicationURL.path
    }

    /// 本机是否已安装 WorkBuddy。
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: appPath)
    }

    /// 检查 WorkBuddy 是否正在运行（仅代表进程存在，不代表已登录目标账号）。
    public func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Platform.workbuddy.bundleIdentifier
        }
    }

    /// 打开 WorkBuddy 官方应用。
    @discardableResult
    public func openApp() -> Bool {
        NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
    }
}
