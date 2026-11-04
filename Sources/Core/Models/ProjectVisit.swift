import Foundation

/// 项目打开记录（仅 TRAE：账号按独立 `--user-data-dir` 隔离）。
///
/// 只保存项目目录路径与打开时间，不读取项目内容或会话数据。
public struct ProjectVisit: Codable, Sendable, Identifiable {
    public static let tableName = "project_visits"

    public var id: UUID
    public var accountId: UUID
    /// 项目目录的标准化绝对路径
    public var workspacePath: String
    public var lastVisitedAt: Date
    public var visitCount: Int
    /// app = 本应用发起的打开；trae = 从 TRAE 本地状态推断
    public var source: String

    public init(
        id: UUID = UUID(),
        accountId: UUID,
        workspacePath: String,
        lastVisitedAt: Date = Date(),
        visitCount: Int = 1,
        source: String = "app"
    ) {
        self.id = id
        self.accountId = accountId
        self.workspacePath = workspacePath
        self.lastVisitedAt = lastVisitedAt
        self.visitCount = visitCount
        self.source = source
    }

    public static let columns = [
        "id", "accountId", "workspacePath", "lastVisitedAt", "visitCount", "source"
    ]

    public init(row: Row) {
        self.id = UUID(uuidString: row.string(at: 0) ?? "") ?? UUID()
        self.accountId = UUID(uuidString: row.string(at: 1) ?? "") ?? UUID()
        self.workspacePath = row.string(at: 2) ?? ""
        self.lastVisitedAt = row.double(at: 3).map { Date(timeIntervalSince1970: $0) } ?? Date()
        self.visitCount = row.int(at: 4) ?? 1
        self.source = row.string(at: 5) ?? "app"
    }

    public var values: [SQLiteValue] {
        [
            .string(id.uuidString),
            .string(accountId.uuidString),
            .string(workspacePath),
            .double(lastVisitedAt.timeIntervalSince1970),
            .int(visitCount),
            .string(source)
        ]
    }
}
