import Foundation

/// 一次合并写入的逐事件落库结果。
///
/// `inserted`/`updated`/`skipped` 通过写前探测 messageId 区分——
/// `ON CONFLICT ... DO UPDATE` 返回的 changes 无法区分新增与更新。
public struct TraeTaskUpsertReport: Sendable, Equatable {
    /// 新写入数据库的任务数
    public var inserted: Int
    /// 实际发生更新的已有任务数
    public var updated: Int
    /// 内容无变化、无需写入的重复事件数
    public var skipped: Int
    /// 写入失败的事件数（不占用数据库行）
    public var failed: Int

    public init(inserted: Int = 0, updated: Int = 0, skipped: Int = 0, failed: Int = 0) {
        self.inserted = inserted
        self.updated = updated
        self.skipped = skipped
        self.failed = failed
    }

    /// 实际写入（新增+更新）的行数。
    public var changedCount: Int { inserted + updated }
}

/// TRAE 任务与单任务积分消耗的本地存储。
public final class TraeTaskService: Sendable {
    private let db: DatabaseService
    private let logger: AppLogger

    public init(database: DatabaseService, logger: AppLogger = AppLogger(category: "task")) {
        self.db = database
        self.logger = logger
    }

    private var columns: String { TraeTask.columns.joined(separator: ", ") }

    /// 合并写入任务事件（同一 messageId 去重，逐步补齐元数据/消耗/状态）。
    /// - Returns: 实际发生变化的行数；重复日志不会产生写入。
    @discardableResult
    public func upsert(_ events: [TraeTaskEvent]) throws -> Int {
        try upsertWithReport(events).changedCount
    }

    /// 合并写入任务事件，并返回逐事件的落库结果。
    ///
    /// 单个事件写失败（如账号已删导致的外键冲突）只计入 `failed` 并继续
    /// 处理后续事件——SQLite 语句级冲突（ABORT）只回滚当前语句，不影响
    /// 事务，其余事件仍会一起提交；事务级失败（数据库关闭、磁盘错误等）
    /// 则整体回滚并抛出，由调用方决定如何呈现。
    @discardableResult
    public func upsertWithReport(_ events: [TraeTaskEvent]) throws -> TraeTaskUpsertReport {
        var report = TraeTaskUpsertReport()
        guard !events.isEmpty else { return report }
        try db.db.transaction { tx in
            for event in events {
                let values: [SQLiteValue] = [
                    .string(event.messageId),
                    .string(event.accountId.uuidString),
                    .string(event.sessionId ?? ""),
                    event.title.sqliteValue,
                    event.status.sqliteValue,
                    event.agentName.sqliteValue,
                    event.modelName.sqliteValue,
                    event.credits.sqliteValue,
                    .double(event.date.timeIntervalSince1970),
                    .double(event.date.timeIntervalSince1970)
                ]
                do {
                    let existed = try tx.queryFirst(
                        "SELECT 1 FROM trae_tasks WHERE id = ?",
                        [.string(event.messageId)]
                    ) { _ in true } ?? false
                    let changed = try tx.execute(Self.upsertSQL, values)
                    switch (existed, changed > 0) {
                    case (false, true): report.inserted += 1
                    case (true, true): report.updated += 1
                    // changes == 0 表示行已存在且内容无变化；新插入必然 changes > 0，
                    // 理论上不会出现「不存在且无变化」，防御性归入 skipped
                    case (_, false): report.skipped += 1
                    }
                } catch {
                    report.failed += 1
                    logger.error(
                        "任务事件写入失败: messageId=\(event.messageId) error=\(error.localizedDescription)"
                    )
                }
            }
        }
        return report
    }

    /// 某账号的任务列表（按任务创建时间倒序，支持分页）。
    public func history(for accountId: UUID, limit: Int = 50, offset: Int = 0) throws -> [TraeTask] {
        try db.db.query(
            "SELECT \(columns) FROM trae_tasks WHERE accountId = ? ORDER BY createdAt DESC LIMIT ? OFFSET ?",
            [.string(accountId.uuidString), .int(limit), .int(offset)]
        ) { TraeTask(row: $0) }
    }

    /// 某账号的任务条数。
    public func count(for accountId: UUID) throws -> Int {
        try db.db.scalar(
            "SELECT COUNT(*) FROM trae_tasks WHERE accountId = ?",
            [.string(accountId.uuidString)]
        )
    }

    /// 全部任务条数（用于设置页诊断信息）。
    public func countAll() throws -> Int {
        try db.db.scalar("SELECT COUNT(*) FROM trae_tasks")
    }

    /// 导出用：按账号与起始时间筛选任务，按创建时间倒序，不分页。
    public func allRows(accountId: UUID?, since: Date?) throws -> [TraeTask] {
        var conditions: [String] = []
        var values: [SQLiteValue] = []
        if let accountId {
            conditions.append("accountId = ?")
            values.append(.string(accountId.uuidString))
        }
        if let since {
            conditions.append("createdAt >= ?")
            values.append(.double(since.timeIntervalSince1970))
        }
        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        return try db.db.query(
            "SELECT \(columns) FROM trae_tasks\(whereClause) ORDER BY createdAt DESC",
            values
        ) { TraeTask(row: $0) }
    }

    /// 指定时间之后解析出的任务积分消耗合计；没有任务时返回 nil。
    ///
    /// 这是按日志里每轮任务记录累加的值，不是官方账户余额。
    public func creditsConsumed(for accountId: UUID, since: Date) throws -> Double? {
        let total: Double?? = try db.db.queryFirst(
            "SELECT SUM(credits) FROM trae_tasks WHERE accountId = ? AND createdAt >= ?",
            [.string(accountId.uuidString), .double(since.timeIntervalSince1970)]
        ) { $0.double(at: 0) }
        return total ?? nil
    }

    // MARK: - SQL

    /// 只在字段确实变化时才更新，避免重复日志造成无意义的写入。
    private static let upsertSQL = """
    INSERT INTO trae_tasks (\(TraeTask.columns.joined(separator: ", ")))
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
        title = COALESCE(excluded.title, trae_tasks.title),
        status = COALESCE(excluded.status, trae_tasks.status),
        agentName = COALESCE(excluded.agentName, trae_tasks.agentName),
        modelName = COALESCE(excluded.modelName, trae_tasks.modelName),
        credits = COALESCE(excluded.credits, trae_tasks.credits),
        createdAt = MIN(trae_tasks.createdAt, excluded.createdAt),
        updatedAt = excluded.updatedAt
    WHERE trae_tasks.credits IS NOT COALESCE(excluded.credits, trae_tasks.credits)
       OR trae_tasks.status IS NOT COALESCE(excluded.status, trae_tasks.status)
       OR trae_tasks.title IS NOT COALESCE(excluded.title, trae_tasks.title)
       OR trae_tasks.agentName IS NOT COALESCE(excluded.agentName, trae_tasks.agentName)
       OR trae_tasks.modelName IS NOT COALESCE(excluded.modelName, trae_tasks.modelName)
       OR excluded.createdAt < trae_tasks.createdAt
    """
}
