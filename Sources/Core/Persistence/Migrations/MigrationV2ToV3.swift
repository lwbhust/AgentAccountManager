import Foundation

/// v2 → v3：重建 accounts 表——删除从未使用的 creditResetAt 列，新增 lastUsedAt。
///
/// SQLite 官方推荐的删列流程：建新表 → 拷数据 → 删旧表 → 改名。
/// 期间 credit_snapshots / switch_logs 通过外键引用 accounts(id)，
/// 必须临时关闭外键约束（由 runner 在事务外设置）。
struct MigrationV2ToV3: SchemaMigration {
    let fromVersion = 2
    let toVersion = 3
    let requiresForeignKeysOff = true

    func apply(_ tx: SQLiteTransaction) throws {
        try tx.execute("""
        CREATE TABLE accounts_v3 (
            id TEXT PRIMARY KEY NOT NULL,
            platform TEXT NOT NULL,
            displayName TEXT NOT NULL,
            phoneMasked TEXT NOT NULL,
            phoneHash TEXT,
            planType TEXT,
            note TEXT,
            lastLoginStatus TEXT NOT NULL DEFAULT 'unknown',
            lastCreditQueryAt REAL,
            currentCredits INTEGER,
            totalCredits INTEGER,
            creditType TEXT,
            lastUsedAt REAL,
            dataSource TEXT NOT NULL DEFAULT 'manual_entry',
            dataStatus TEXT NOT NULL DEFAULT 'manual',
            traeUserDataDir TEXT,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        )
        """)
        try tx.execute("""
        INSERT INTO accounts_v3 (
            id, platform, displayName, phoneMasked, phoneHash,
            planType, note, lastLoginStatus, lastCreditQueryAt,
            currentCredits, totalCredits, creditType, lastUsedAt,
            dataSource, dataStatus, traeUserDataDir, createdAt, updatedAt
        )
        SELECT
            id, platform, displayName, phoneMasked, phoneHash,
            planType, note, lastLoginStatus, lastCreditQueryAt,
            currentCredits, totalCredits, creditType, NULL,
            dataSource, dataStatus, traeUserDataDir, createdAt, updatedAt
        FROM accounts
        """)
        try tx.execute("DROP TABLE accounts")
        try tx.execute("ALTER TABLE accounts_v3 RENAME TO accounts")

        // 引用完整性校验（v2 已清理孤儿行，此处应无违规；仅记录不阻断）
        let violations = try tx.query("PRAGMA foreign_key_check") { _ in () }.count
        if violations > 0 {
            AppLogger(category: "migration").error("v3 迁移后外键校验发现 \(violations) 处违规")
        }
    }
}
