import Foundation

/// v3 → v4：用历史切换日志回填 `lastUsedAt`。
///
/// 该字段是 v3 才加入的，此前切换成功不会记录，导致老账号一直显示
/// 「从未切换」。只按真正启动过客户端的日志回填（`failed` 表示未启动），
/// 已有值的账号不受影响。
struct MigrationV3ToV4: SchemaMigration {
    let fromVersion = 3
    let toVersion = 4

    func apply(_ tx: SQLiteTransaction) throws {
        try tx.execute("""
            UPDATE accounts
            SET lastUsedAt = (
                SELECT MAX(createdAt) FROM switch_logs
                WHERE switch_logs.accountId = accounts.id
                  AND switch_logs.result <> 'failed'
            )
            WHERE lastUsedAt IS NULL
              AND EXISTS (
                SELECT 1 FROM switch_logs
                WHERE switch_logs.accountId = accounts.id
                  AND switch_logs.result <> 'failed'
              )
            """)
    }
}
