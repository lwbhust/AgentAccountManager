import Foundation

/// 最近一次登录/切换的核对状态。
///
/// 刻意区分“用户确认”与“技术验证”，避免把打开客户端或历史确认表述为已验证身份。
public enum LoginStatus: String, Codable, CaseIterable, Sendable {
    /// 未知（尚未记录过任何核对结果）
    case unknown = "unknown"
    /// 已退出
    case loggedOut = "logged_out"
    /// 已发起切换，等待用户在官方界面核对
    case pendingConfirmation = "switch_unconfirmed"
    /// 用户已人工确认登录
    case userConfirmed = "user_confirmed"
    /// 通过官方 CLI 等经过验证的方式确认了当前身份
    case verified = "verified"

    public var displayName: String {
        switch self {
        case .unknown: return "状态未记录"
        case .loggedOut: return "已退出"
        case .pendingConfirmation: return "等待核对"
        case .userConfirmed: return "已人工确认"
        case .verified: return "已验证身份"
        }
    }

    /// 是否为有事实依据的“已登录”状态（用于列表筛选与视觉强调）。
    public var isConfirmed: Bool {
        self == .userConfirmed || self == .verified
    }

    /// 兼容旧版本数据：历史值 `logged_in` 视为“用户已人工确认”。
    public init(storedValue: String) {
        switch storedValue {
        case "logged_in", "user_confirmed":
            self = .userConfirmed
        case "verified":
            self = .verified
        case "switch_unconfirmed":
            self = .pendingConfirmation
        case "logged_out":
            self = .loggedOut
        default:
            self = .unknown
        }
    }
}

/// 额度数据来源。
public enum DataSource: String, Codable, CaseIterable, Sendable {
    case officialAPI = "official_api"
    case officialCLI = "official_cli"
    case manualEntry = "manual_entry"

    public var displayName: String {
        switch self {
        case .officialAPI: return "官方接口"
        case .officialCLI: return "官方 CLI"
        case .manualEntry: return "手动录入"
        }
    }
}

/// 额度数据状态。
public enum DataStatus: String, Codable, CaseIterable, Sendable {
    case latest = "latest"
    case stale = "stale"
    case manual = "manual"
    case queryFailed = "query_failed"

    public var displayName: String {
        switch self {
        case .latest: return "最新"
        case .stale: return "已过期"
        case .manual: return "手动录入"
        case .queryFailed: return "查询失败"
        }
    }
}

/// 额度快照查询状态。
public enum SnapshotStatus: String, Codable, CaseIterable, Sendable {
    case success = "success"
    case failed = "failed"
    case stale = "stale"
}

/// 切换事务结果。
public enum SwitchResult: String, Codable, CaseIterable, Sendable {
    case success = "success"
    case unconfirmed = "unconfirmed"
    case failed = "failed"

    public var displayName: String {
        switch self {
        case .success: return "已启动"
        case .unconfirmed: return "等待核对"
        case .failed: return "未完成"
        }
    }
}
