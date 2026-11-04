import Foundation

/// v4 → v5：新增 TRAE 任务与单任务积分消耗记录。
///
/// `status` 允许为空，表示日志里还没出现状态字段；
/// `credits` 允许为空，表示还没采集到该轮消耗，绝不写 0。
/// 任务随账号删除级联清理。
struct MigrationV4ToV5: SchemaMigration {
    let fromVersion = 4
    let toVersion = 5

    func apply(_ tx: SQLiteTransaction) throws {
        try tx.execute("""
        CREATE TABLE IF NOT EXISTS trae_tasks (
            id TEXT PRIMARY KEY NOT NULL,
            accountId TEXT NOT NULL,
            sessionId TEXT NOT NULL DEFAULT '',
            title TEXT,
            status TEXT,
            agentName TEXT,
            modelName TEXT,
            credits REAL,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL,
            FOREIGN KEY (accountId) REFERENCES accounts(id) ON DELETE CASCADE
        )
        """)
        try tx.execute(
            "CREATE INDEX IF NOT EXISTS ix_trae_tasks_accountId ON trae_tasks(accountId, createdAt)"
        )
    }
}
