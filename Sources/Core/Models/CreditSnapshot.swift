import Foundation

/// 积分额度历史快照。每次查询或手动录入都保存一条。
public struct CreditSnapshot: Codable, Sendable, Identifiable {
    public static let tableName = "credit_snapshots"

    public var id: UUID
    public var accountId: UUID
    public var credits: Int?
    public var totalCredits: Int?
    public var queryAt: Date
    public var source: DataSource
    public var status: SnapshotStatus
    /// 查询失败原因（已脱敏）
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        accountId: UUID,
        credits: Int?,
        totalCredits: Int? = nil,
        queryAt: Date = Date(),
        source: DataSource,
        status: SnapshotStatus,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.credits = credits
        self.totalCredits = totalCredits
        self.queryAt = queryAt
        self.source = source
        self.status = status
        self.errorMessage = errorMessage
    }

    public static let columns = [
        "id", "accountId", "credits", "totalCredits", "queryAt",
        "source", "status", "errorMessage"
    ]

    public init(row: Row) {
        self.id = UUID(uuidString: row.string(at: 0) ?? "") ?? UUID()
        self.accountId = UUID(uuidString: row.string(at: 1) ?? "") ?? UUID()
        self.credits = row.int(at: 2)
        self.totalCredits = row.int(at: 3)
        self.queryAt = row.double(at: 4).map { Date(timeIntervalSince1970: $0) } ?? Date()
        self.source = DataSource(rawValue: row.string(at: 5) ?? "") ?? .manualEntry
        self.status = SnapshotStatus(rawValue: row.string(at: 6) ?? "") ?? .failed
        self.errorMessage = row.string(at: 7)
    }

    public var values: [SQLiteValue] {
        [
            .string(id.uuidString),
            .string(accountId.uuidString),
            credits.sqliteValue,
            totalCredits.sqliteValue,
            .double(queryAt.timeIntervalSince1970),
            .string(source.rawValue),
            .string(status.rawValue),
            errorMessage.sqliteValue
        ]
    }
}
