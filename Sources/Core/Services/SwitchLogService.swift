import Foundation

/// 切换事务日志服务。
public final class SwitchLogService: Sendable {
    private let db: DatabaseService

    public init(database: DatabaseService) {
        self.db = database
    }

    private var cols: String { SwitchLog.columns.joined(separator: ", ") }
    private var insertSQL: String {
        let placeholders = Array(repeating: "?", count: SwitchLog.columns.count).joined(separator: ", ")
        return "INSERT INTO switch_logs (\(cols)) VALUES (\(placeholders))"
    }

    private func makeEntry(
        accountId: UUID,
        fromStatus: String,
        toStatus: String,
        result: SwitchResult,
        errorMessage: String?
    ) -> SwitchLog {
        SwitchLog(
            accountId: accountId,
            fromStatus: fromStatus,
            toStatus: toStatus,
            result: result,
            errorMessage: errorMessage.map { Masking.redactPhone(in: $0) }
        )
    }

    /// 记录一次切换事务。
    @discardableResult
    public func log(
        accountId: UUID,
        fromStatus: String,
        toStatus: String,
        result: SwitchResult,
        errorMessage: String? = nil
    ) throws -> SwitchLog {
        let entry = makeEntry(
            accountId: accountId,
            fromStatus: fromStatus,
            toStatus: toStatus,
            result: result,
            errorMessage: errorMessage
        )
        try db.db.execute(insertSQL, entry.values)
        return entry
    }

    /// 事务上下文变体（供 SwitchService 原子提交组合使用）：
    /// SQLiteDatabase.transaction 期间独占数据库队列，闭包内只能走 SQLiteTransaction。
    @discardableResult
    public func log(
        _ tx: SQLiteTransaction,
        accountId: UUID,
        fromStatus: String,
        toStatus: String,
        result: SwitchResult,
        errorMessage: String? = nil
    ) throws -> Int {
        let entry = makeEntry(
            accountId: accountId,
            fromStatus: fromStatus,
            toStatus: toStatus,
            result: result,
            errorMessage: errorMessage
        )
        return try tx.execute(insertSQL, entry.values)
    }

    /// 获取某账号的切换历史（倒序，支持分页）。
    public func history(for accountId: UUID, limit: Int = 50, offset: Int = 0) throws -> [SwitchLog] {
        try db.db.query(
            "SELECT \(cols) FROM switch_logs WHERE accountId = ? ORDER BY createdAt DESC LIMIT ? OFFSET ?",
            [.string(accountId.uuidString), .int(limit), .int(offset)]
        ) { SwitchLog(row: $0) }
    }

    /// 某账号的切换日志条数（用于删除前的数据影响提示）。
    public func count(for accountId: UUID) throws -> Int {
        try db.db.scalar(
            "SELECT COUNT(*) FROM switch_logs WHERE accountId = ?",
            [.string(accountId.uuidString)]
        )
    }

    /// 全部切换日志条数（用于设置页诊断信息）。
    public func countAll() throws -> Int {
        try db.db.scalar("SELECT COUNT(*) FROM switch_logs")
    }
}
