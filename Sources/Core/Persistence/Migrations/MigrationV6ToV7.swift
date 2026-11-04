import Foundation

/// v6 → v7：三工位工作台的项目与工位表。
///
/// 只新增表，不修改任何旧表。工位随项目级联删除；账号删除时工位置空，
/// 工位记录与 worktree 目录不自动删除。
struct MigrationV6ToV7: SchemaMigration {
    let fromVersion = 6
    let toVersion = 7

    func apply(_ tx: SQLiteTransaction) throws {
        try tx.execute("""
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY NOT NULL,
            displayName TEXT NOT NULL,
            repoPath TEXT NOT NULL,
            baselineBranch TEXT NOT NULL,
            orchestrationMode TEXT NOT NULL,
            buildCommand TEXT,
            testCommand TEXT,
            setupHint TEXT,
            worktreeRoot TEXT,
            projectMemory TEXT,
            note TEXT,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        )
        """)

        try tx.execute("""
        CREATE TABLE IF NOT EXISTS workstations (
            id TEXT PRIMARY KEY NOT NULL,
            projectId TEXT NOT NULL,
            accountId TEXT,
            displayName TEXT NOT NULL,
            roleTag TEXT,
            worktreePath TEXT,
            branchName TEXT,
            isEnabled INTEGER NOT NULL DEFAULT 1,
            lastActivatedAt REAL,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL,
            FOREIGN KEY (projectId) REFERENCES projects(id) ON DELETE CASCADE,
            FOREIGN KEY (accountId) REFERENCES accounts(id) ON DELETE SET NULL,
            UNIQUE (projectId, displayName),
            UNIQUE (projectId, accountId),
            UNIQUE (worktreePath)
        )
        """)

        try tx.execute(
            "CREATE INDEX IF NOT EXISTS ix_workstations_project ON workstations(projectId, isEnabled)"
        )
        try tx.execute(
            "CREATE INDEX IF NOT EXISTS ix_workstations_account ON workstations(accountId)"
        )
    }
}
