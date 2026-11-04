import Foundation

/// 积分额度录入与历史查询。
public final class CreditService: Sendable {
    private let db: DatabaseService
    private let logger: AppLogger

    /// 超过此时间的数据视为过期（单位：秒）。默认 12 小时。
    nonisolated(unsafe) public var staleInterval: TimeInterval = 12 * 3600

    public init(database: DatabaseService, logger: AppLogger = AppLogger(category: "credit")) {
        self.db = database
        self.logger = logger
    }

    private var accountCols: String { Account.columns.joined(separator: ", ") }
    private var snapshotCols: String { CreditSnapshot.columns.joined(separator: ", ") }

    // MARK: - 手动录入

    /// 手动录入积分。保存快照并更新账号当前积分。
    /// - Parameters:
    ///   - observedAt: 用户实际观察到该积分的时间，默认为当前时间。
    /// - Important: 查询失败时不要调用此方法写 0，应调用 recordQueryFailure。
    ///   总额度/积分类型留空时保留账号原有值，避免一次录入把旧信息抹掉。
    @discardableResult
    public func recordManualEntry(
        accountId: UUID,
        credits: Int,
        totalCredits: Int? = nil,
        creditType: String? = nil,
        observedAt: Date = Date()
    ) throws -> CreditSnapshot {
        var snapshot = CreditSnapshot(
            accountId: accountId,
            credits: credits,
            totalCredits: totalCredits,
            queryAt: observedAt,
            source: .manualEntry,
            status: .success
        )

        try db.db.transaction { tx in
            try insertSnapshot(&snapshot, in: tx)

            if var account = try tx.queryFirst(
                "SELECT \(accountCols) FROM accounts WHERE id = ?",
                [.string(accountId.uuidString)],
                { Account(row: $0) }
            ) {
                account.currentCredits = credits
                if let totalCredits {
                    account.totalCredits = totalCredits
                }
                if let creditType, !creditType.isEmpty {
                    account.creditType = creditType
                }
                account.lastCreditQueryAt = observedAt
                account.dataSource = .manualEntry
                account.dataStatus = .manual
                account.updatedAt = Date()
                try save(&account, in: tx)
            }
        }
        logger.info("手动录入积分: account=\(accountId.uuidString.prefix(8)) credits=\(credits)")
        return snapshot
    }

    // MARK: - 查询失败记录

    /// 记录一次查询失败。绝不把余额写为 0，仅保存失败快照。
    @discardableResult
    public func recordQueryFailure(accountId: UUID, errorMessage: String) throws -> CreditSnapshot {
        let now = Date()
        var snapshot = CreditSnapshot(
            accountId: accountId,
            credits: nil,
            queryAt: now,
            source: .officialAPI,
            status: .failed,
            errorMessage: Masking.redactPhone(in: errorMessage)
        )

        try db.db.transaction { tx in
            try insertSnapshot(&snapshot, in: tx)

            if var account = try tx.queryFirst(
                "SELECT \(accountCols) FROM accounts WHERE id = ?",
                [.string(accountId.uuidString)],
                { Account(row: $0) }
            ) {
                account.lastCreditQueryAt = now
                account.dataStatus = .queryFailed
                account.updatedAt = now
                // 保留 currentCredits 不变，绝不置 0
                try save(&account, in: tx)
            }
        }
        logger.error("积分查询失败: account=\(accountId.uuidString.prefix(8))")
        return snapshot
    }

    private func insertSnapshot(_ snapshot: inout CreditSnapshot, in tx: SQLiteTransaction) throws {
        let placeholders = Array(repeating: "?", count: CreditSnapshot.columns.count).joined(separator: ", ")
        try tx.execute(
            "INSERT INTO credit_snapshots (\(snapshotCols)) VALUES (\(placeholders))",
            snapshot.values
        )
    }

    /// 在事务内全量更新账号（复用与 AccountService 相同的列顺序）。
    private func save(_ account: inout Account, in tx: SQLiteTransaction) throws {
        let setCols = Account.columns.filter { $0 != "id" }
        let setClause = setCols.map { "\($0) = ?" }.joined(separator: ", ")
        var values = account.values
        values.removeFirst()
        values.append(.string(account.id.uuidString))
        try tx.execute("UPDATE accounts SET \(setClause) WHERE id = ?", values)
    }

    // MARK: - 预计余额

    /// 预计当前余额 = 最近一次成功录入的余额 − 该时刻之后采集到的任务消耗。
    ///
    /// 还没有任何成功录入时返回 nil（不做猜测，也不把未知当 0）。
    /// 基准之后的任务无论成功、失败还是中断，只要日志里采集到消耗就计入，
    /// 因为那部分额度已经实际被扣掉。
    public func balanceEstimate(for accountId: UUID) throws -> CreditBalanceEstimate? {
        let baselines = try db.db.query(
            """
            SELECT credits, queryAt FROM credit_snapshots
            WHERE accountId = ? AND status = ?
            """,
            [.string(accountId.uuidString), .string(SnapshotStatus.success.rawValue)]
        ) { row in
            CreditBalanceCalculator.BaselineRow(
                credits: row.int(at: 0),
                observedAt: row.double(at: 1).map { Date(timeIntervalSince1970: $0) }
            )
        }
        let tasks = try db.db.query(
            "SELECT credits, createdAt FROM trae_tasks WHERE accountId = ?",
            [.string(accountId.uuidString)]
        ) { row in
            CreditBalanceCalculator.TaskRow(
                credits: row.double(at: 0),
                createdAt: row.double(at: 1).map { Date(timeIntervalSince1970: $0) }
            )
        }
        // 基准选取、时间过滤与求和全部由纯函数完成，便于边界矩阵测试
        return CreditBalanceCalculator.estimate(baselines: baselines, tasks: tasks)
    }

    // MARK: - 历史查询

    /// 获取某账号的额度历史（按时间倒序，支持分页）。
    public func history(for accountId: UUID, limit: Int = 50, offset: Int = 0) throws -> [CreditSnapshot] {
        try db.db.query(
            "SELECT \(snapshotCols) FROM credit_snapshots WHERE accountId = ? ORDER BY queryAt DESC LIMIT ? OFFSET ?",
            [.string(accountId.uuidString), .int(limit), .int(offset)]
        ) { CreditSnapshot(row: $0) }
    }

    /// 某账号的积分记录条数（用于删除前的数据影响提示）。
    public func count(for accountId: UUID) throws -> Int {
        try db.db.scalar(
            "SELECT COUNT(*) FROM credit_snapshots WHERE accountId = ?",
            [.string(accountId.uuidString)]
        )
    }

    /// 全部积分记录条数（用于设置页诊断信息）。
    public func countAll() throws -> Int {
        try db.db.scalar("SELECT COUNT(*) FROM credit_snapshots")
    }

    /// 导出用：按账号与起始时间筛选积分记录，按时间倒序，不分页。
    public func allRows(accountId: UUID?, since: Date?) throws -> [CreditSnapshot] {
        var conditions: [String] = []
        var values: [SQLiteValue] = []
        if let accountId {
            conditions.append("accountId = ?")
            values.append(.string(accountId.uuidString))
        }
        if let since {
            conditions.append("queryAt >= ?")
            values.append(.double(since.timeIntervalSince1970))
        }
        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        return try db.db.query(
            "SELECT \(snapshotCols) FROM credit_snapshots\(whereClause) ORDER BY queryAt DESC",
            values
        ) { CreditSnapshot(row: $0) }
    }
}
