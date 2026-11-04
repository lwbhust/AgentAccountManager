import Foundation

/// v0 → v1：初始建表（accounts / credit_snapshots / switch_logs）。
struct MigrationV0ToV1: SchemaMigration {
    let fromVersion = 0
    let toVersion = 1

    func apply(_ tx: SQLiteTransaction) throws {
        try tx.execute("""
        CREATE TABLE IF NOT EXISTS accounts (
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
            creditResetAt REAL,
            dataSource TEXT NOT NULL DEFAULT 'manual_entry',
            dataStatus TEXT NOT NULL DEFAULT 'manual',
            traeUserDataDir TEXT,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        )
        """)

        try tx.execute("""
        CREATE TABLE IF NOT EXISTS credit_snapshots (
            id TEXT PRIMARY KEY NOT NULL,
            accountId TEXT NOT NULL,
            credits INTEGER,
            totalCredits INTEGER,
            queryAt REAL NOT NULL,
            source TEXT NOT NULL,
            status TEXT NOT NULL,
            errorMessage TEXT,
            FOREIGN KEY (accountId) REFERENCES accounts(id) ON DELETE CASCADE
        )
        """)
        try tx.execute("CREATE INDEX IF NOT EXISTS ix_credit_snapshots_accountId ON credit_snapshots(accountId, queryAt)")

        try tx.execute("""
        CREATE TABLE IF NOT EXISTS switch_logs (
            id TEXT PRIMARY KEY NOT NULL,
            accountId TEXT NOT NULL,
            fromStatus TEXT NOT NULL,
            toStatus TEXT NOT NULL,
            result TEXT NOT NULL,
            errorMessage TEXT,
            createdAt REAL NOT NULL,
            FOREIGN KEY (accountId) REFERENCES accounts(id) ON DELETE CASCADE
        )
        """)
        try tx.execute("CREATE INDEX IF NOT EXISTS ix_switch_logs_accountId ON switch_logs(accountId, createdAt)")
    }
}
