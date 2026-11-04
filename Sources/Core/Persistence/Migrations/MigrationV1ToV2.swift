import Foundation

/// v1 → v2：清理历史遗留的孤儿行。
///
/// 旧版本外键未在每次连接启用，删除账号可能残留快照与日志。
struct MigrationV1ToV2: SchemaMigration {
    let fromVersion = 1
    let toVersion = 2

    func apply(_ tx: SQLiteTransaction) throws {
        try tx.execute("DELETE FROM credit_snapshots WHERE accountId NOT IN (SELECT id FROM accounts)")
        try tx.execute("DELETE FROM switch_logs WHERE accountId NOT IN (SELECT id FROM accounts)")
    }
}
