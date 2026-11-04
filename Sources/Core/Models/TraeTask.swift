import Foundation

/// 任务状态（来自 TRAE 本地日志里的原始状态值）。
public enum TraeTaskStatus: String, Codable, CaseIterable, Sendable {
    case inProgress = "in_progress"
    case completed = "completed"
    case failed = "failed"
    case interrupted = "interrupted"
    case unknown = "unknown"

    public var displayName: String {
        switch self {
        case .inProgress: return "进行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .interrupted: return "已中断"
        case .unknown: return "状态未知"
        }
    }

    /// 兼容 TRAE 日志里可能出现的同义状态值。
    public init(storedValue: String?) {
        switch (storedValue ?? "").lowercased() {
        case "in_progress", "running", "pending", "active":
            self = .inProgress
        case "completed", "success", "done", "finished":
            self = .completed
        case "failed", "error":
            self = .failed
        case "interrupted", "cancelled", "canceled", "aborted":
            self = .interrupted
        default:
            self = .unknown
        }
    }
}

/// 从 TRAE 本地运行日志采集到的一次 AI 任务（一个对话轮次）。
///
/// 只保存用户输入的首行摘要，不保存完整对话内容；
/// 积分消耗来自日志里该轮任务的 usage 记录，采集不到时保持 nil，绝不写 0。
public struct TraeTask: Codable, Sendable, Identifiable {
    public static let tableName = "trae_tasks"

    /// TRAE 的 agent message id（同一账号内唯一）。
    public var id: String
    public var accountId: UUID
    public var sessionId: String
    /// 用户输入首行摘要；日志里没有用户输入时为 nil。
    public var title: String?
    public var status: TraeTaskStatus
    public var agentName: String?
    public var modelName: String?
    /// 该轮任务消耗的积分；未采集到时为 nil。
    public var credits: Double?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        accountId: UUID,
        sessionId: String,
        title: String? = nil,
        status: TraeTaskStatus = .unknown,
        agentName: String? = nil,
        modelName: String? = nil,
        credits: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.sessionId = sessionId
        self.title = title
        self.status = status
        self.agentName = agentName
        self.modelName = modelName
        self.credits = credits
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let columns = [
        "id", "accountId", "sessionId", "title", "status",
        "agentName", "modelName", "credits", "createdAt", "updatedAt"
    ]

    public init(row: Row) {
        self.id = row.string(at: 0) ?? ""
        self.accountId = UUID(uuidString: row.string(at: 1) ?? "") ?? UUID()
        self.sessionId = row.string(at: 2) ?? ""
        self.title = row.string(at: 3)
        self.status = TraeTaskStatus(storedValue: row.string(at: 4))
        self.agentName = row.string(at: 5)
        self.modelName = row.string(at: 6)
        self.credits = row.double(at: 7)
        self.createdAt = row.double(at: 8).map { Date(timeIntervalSince1970: $0) } ?? Date()
        self.updatedAt = row.double(at: 9).map { Date(timeIntervalSince1970: $0) } ?? Date()
    }

    public var values: [SQLiteValue] {
        [
            .string(id),
            .string(accountId.uuidString),
            .string(sessionId),
            title.sqliteValue,
            .string(status.rawValue),
            agentName.sqliteValue,
            modelName.sqliteValue,
            credits.sqliteValue,
            .double(createdAt.timeIntervalSince1970),
            .double(updatedAt.timeIntervalSince1970)
        ]
    }
}

extension TraeTask {
    /// 列表展示用的任务名，未采集到用户输入时给出明确占位。
    public var titleDisplay: String {
        guard let title, !title.isEmpty else { return "（未获取到任务描述）" }
        return title
    }

    /// 积分消耗展示文本；未采集到时显示「未采集」，不显示 0。
    public var creditsDisplay: String {
        Self.creditsDisplay(credits)
    }

    public static func creditsDisplay(_ value: Double?) -> String {
        guard let value else { return "未采集" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
