import Foundation

/// 账号切换事务日志。
public struct SwitchLog: Codable, Sendable, Identifiable {
    public static let tableName = "switch_logs"

    public var id: UUID
    public var accountId: UUID
    public var fromStatus: String
    public var toStatus: String
    public var result: SwitchResult
    /// 失败原因（已脱敏）
    public var errorMessage: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        accountId: UUID,
        fromStatus: String,
        toStatus: String,
        result: SwitchResult,
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.fromStatus = fromStatus
        self.toStatus = toStatus
        self.result = result
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }

    public static let columns = [
        "id", "accountId", "fromStatus", "toStatus", "result", "errorMessage", "createdAt"
    ]

    public init(row: Row) {
        self.id = UUID(uuidString: row.string(at: 0) ?? "") ?? UUID()
        self.accountId = UUID(uuidString: row.string(at: 1) ?? "") ?? UUID()
        self.fromStatus = row.string(at: 2) ?? ""
        self.toStatus = row.string(at: 3) ?? ""
        self.result = SwitchResult(rawValue: row.string(at: 4) ?? "") ?? .unconfirmed
        self.errorMessage = row.string(at: 5)
        self.createdAt = row.double(at: 6).map { Date(timeIntervalSince1970: $0) } ?? Date()
    }

    public var values: [SQLiteValue] {
        [
            .string(id.uuidString),
            .string(accountId.uuidString),
            .string(fromStatus),
            .string(toStatus),
            .string(result.rawValue),
            errorMessage.sqliteValue,
            .double(createdAt.timeIntervalSince1970)
        ]
    }
}
