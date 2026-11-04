import Foundation

/// 支持的平台。首期仅 WorkBuddy 与 TRAE（国内版）。
public enum Platform: String, Codable, CaseIterable, Sendable, Identifiable {
    public var id: String { rawValue }
    case workbuddy = "workbuddy"
    case trae = "trae"

    /// 人类可读名称
    public var displayName: String {
        switch self {
        case .workbuddy: return "WorkBuddy"
        case .trae: return "TRAE"
        }
    }

    /// 官方应用在 /Applications 中的名称（用于打开官方应用）
    public var appFileName: String {
        switch self {
        case .workbuddy: return "WorkBuddy AI.app"
        case .trae: return "Trae CN.app"
        }
    }

    /// Bundle ID
    public var bundleIdentifier: String {
        switch self {
        case .workbuddy: return "com.workbuddy.workbuddy-ai"
        case .trae: return "cn.trae.app"
        }
    }

    /// 官方应用在 /Applications 中的完整路径（首选位置）。
    public var applicationURL: URL {
        URL(fileURLWithPath: "/Applications").appendingPathComponent(appFileName)
    }

    /// LaunchServices 兜底查询的应用适配层注入点（避免 Core 依赖 AppKit）。
    ///
    /// 正式应用启动时由装配层设置为 NSWorkspace 实现；未注入时（如单元测试）
    /// 只探测 /Applications 固定路径。
    nonisolated(unsafe) public static var launchServicesApplicationResolver: ((String) -> URL?)?

    /// 实际找到的应用位置：先看 /Applications，再用注入的 LaunchServices 兜底
    /// （用户可能装在 ~/Applications 或改过应用名）。
    public var installedApplicationURL: URL? {
        if FileManager.default.fileExists(atPath: applicationURL.path) {
            return applicationURL
        }
        return Self.launchServicesApplicationResolver?(bundleIdentifier)
    }

    /// 本机是否已安装官方应用。
    public var isInstalled: Bool {
        installedApplicationURL != nil
    }

    /// 该平台是否支持启动独立配置实例（决定切换流程的说明文案）。
    public var supportsIsolatedInstance: Bool {
        self == .trae
    }
}
