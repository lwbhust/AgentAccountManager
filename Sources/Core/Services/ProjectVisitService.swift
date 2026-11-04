import Foundation

/// 项目打开记录服务。
///
/// 仅记录"哪个项目在什么时间被打开过"以及打开次数，
/// 不保存项目内容、对话或任何凭据。
public final class ProjectVisitService: Sendable {
    private let db: DatabaseService

    public init(database: DatabaseService) {
        self.db = database
    }

    private var columns: String { ProjectVisit.columns.joined(separator: ", ") }

    private var upsertSQL: String {
        """
        INSERT INTO project_visits (id, accountId, workspacePath, lastVisitedAt, visitCount, source)
        VALUES (?, ?, ?, ?, 1, ?)
        ON CONFLICT(accountId, workspacePath) DO UPDATE SET
            lastVisitedAt = MAX(project_visits.lastVisitedAt, excluded.lastVisitedAt),
            visitCount = project_visits.visitCount + 1,
            source = excluded.source
        """
    }

    private func upsertValues(
        accountId: UUID,
        workspace: URL,
        at date: Date,
        source: String
    ) -> [SQLiteValue] {
        [
            .string(UUID().uuidString),
            .string(accountId.uuidString),
            .string(workspace.standardizedFileURL.path),
            .double(date.timeIntervalSince1970),
            .string(source)
        ]
    }

    /// 记录一次项目打开；同一账号同一路径累加次数并保留较晚时间。
    @discardableResult
    public func record(
        accountId: UUID,
        workspace: URL,
        at date: Date = Date(),
        source: String = "app"
    ) throws -> Int {
        try db.db.execute(
            upsertSQL,
            upsertValues(accountId: accountId, workspace: workspace, at: date, source: source)
        )
    }

    /// 事务上下文变体（供 SwitchService 原子提交组合使用）：
    /// SQLiteDatabase.transaction 期间独占数据库队列，闭包内只能走 SQLiteTransaction。
    @discardableResult
    public func record(
        _ tx: SQLiteTransaction,
        accountId: UUID,
        workspace: URL,
        at date: Date = Date(),
        source: String = "app"
    ) throws -> Int {
        try tx.execute(
            upsertSQL,
            upsertValues(accountId: accountId, workspace: workspace, at: date, source: source)
        )
    }

    /// 指定时间之后打开过的项目，按最近打开倒序。
    public func recent(accountId: UUID, since: Date, limit: Int = 100) throws -> [ProjectVisit] {
        try db.db.query(
            """
            SELECT \(columns) FROM project_visits
            WHERE accountId = ? AND lastVisitedAt >= ?
            ORDER BY lastVisitedAt DESC LIMIT ?
            """,
            [.string(accountId.uuidString), .double(since.timeIntervalSince1970), .int(limit)]
        ) { ProjectVisit(row: $0) }
    }

    /// 删除早于给定时间的记录（控制表体积）。
    @discardableResult
    public func prune(olderThan date: Date) throws -> Int {
        try db.db.execute(
            "DELETE FROM project_visits WHERE lastVisitedAt < ?",
            [.double(date.timeIntervalSince1970)]
        )
    }

    /// 某账号的项目记录条数。
    public func count(for accountId: UUID) throws -> Int {
        try db.db.scalar(
            "SELECT COUNT(*) FROM project_visits WHERE accountId = ?",
            [.string(accountId.uuidString)]
        )
    }

    /// 全部项目记录条数（诊断用）。
    public func countAll() throws -> Int {
        try db.db.scalar("SELECT COUNT(*) FROM project_visits")
    }
}
