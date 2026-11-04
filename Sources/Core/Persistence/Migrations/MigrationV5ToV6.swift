import Foundation

/// v5 → v6：项目打开记录（仅 TRAE 账号，用于「最近 3 天」）。
///
/// `(accountId, workspacePath)` 唯一，重复打开按 UPSERT 累加次数；
/// 账号删除时级联清理。
struct MigrationV5ToV6: SchemaMigration {
    let fromVersion = 5
    let toVersion = 6

    func apply(_ tx: SQLiteTransaction) throws {
        try tx.execute("""
        CREATE TABLE IF NOT EXISTS project_visits (
            id TEXT PRIMARY KEY NOT NULL,
            accountId TEXT NOT NULL,
            workspacePath TEXT NOT NULL,
            lastVisitedAt REAL NOT NULL,
            visitCount INTEGER NOT NULL DEFAULT 1,
            source TEXT NOT NULL DEFAULT 'app',
            FOREIGN KEY (accountId) REFERENCES accounts(id) ON DELETE CASCADE,
            UNIQUE (accountId, workspacePath)
        )
        """)
        try tx.execute(
            "CREATE INDEX IF NOT EXISTS ix_project_visits_accountId ON project_visits(accountId, lastVisitedAt)"
        )
    }
}
