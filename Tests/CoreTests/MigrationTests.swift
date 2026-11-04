import XCTest
@testable import Core

/// 迁移体系测试（任务书 Phase 1b-C 矩阵）：
/// 空库初始化 / 当前版本启动 / 完整迁移 / 中间版本 / 错误版本 /
/// 中途失败 / 重复打开 / 关键表索引 / 原数据不丢失 / WAL 配置。
final class MigrationTests: XCTestCase {
    var dbURL: URL!

    override func setUpWithError() throws {
        dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-migration-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + suffix))
        }
    }

    private func openDatabase() throws -> DatabaseService {
        try DatabaseService(databaseURL: dbURL)
    }

    private func userVersion(_ db: SQLiteDatabase) throws -> Int {
        try db.scalar("PRAGMA user_version")
    }

    private func objectNames(_ db: SQLiteDatabase, type: String) throws -> Set<String> {
        let rows = try db.query(
            "SELECT name FROM sqlite_master WHERE type = ?",
            [.string(type)]
        ) { $0.string(at: 0) }
        return Set(rows.compactMap { $0 })
    }

    // MARK: 空数据库初始化

    func testFreshDatabaseInitializesToLatestVersion() throws {
        let service = try openDatabase()
        defer { service.close() }

        XCTAssertEqual(try userVersion(service.db), DatabaseService.supportedSchemaVersion)
        let tables = try objectNames(service.db, type: "table")
        for expected in ["accounts", "credit_snapshots", "switch_logs", "trae_tasks", "project_visits", "projects", "workstations"] {
            XCTAssertTrue(tables.contains(expected), "缺少表 \(expected)")
        }
        let indexes = try objectNames(service.db, type: "index")
        for expected in [
            "ix_credit_snapshots_accountId",
            "ix_switch_logs_accountId",
            "ix_trae_tasks_accountId",
            "ix_project_visits_accountId",
            "ix_workstations_project",
            "ix_workstations_account"
        ] {
            XCTAssertTrue(indexes.contains(expected), "缺少索引 \(expected)")
        }
    }

    // MARK: 当前版本重复打开（幂等 + 数据保留）

    func testReopenDoesNotRerunMigrationsAndPreservesData() throws {
        let first = try openDatabase()
        let account = try AccountService(database: first).create(platform: .trae, displayName: "幂等", phoneMasked: "1")
        _ = try AccountService(database: first).updateLoginStatus(id: account.id, status: .userConfirmed)
        first.close()

        let second = try openDatabase()
        defer { second.close() }
        XCTAssertEqual(try userVersion(second.db), DatabaseService.supportedSchemaVersion)
        let accounts = try AccountService(database: second).listAll()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.id, account.id)
        XCTAssertEqual(accounts.first?.lastLoginStatus, .userConfirmed)
    }

    // MARK: v1 → v7 完整迁移，原数据不丢失

    func testFullMigrationFromV1PreservesData() throws {
        // 用生产迁移步骤构建 v1 夹具（历史 DDL 复用，避免测试内复制建表语句）
        let raw = try SQLiteDatabase(path: dbURL.path)
        try raw.transaction { tx in
            try MigrationV0ToV1().apply(tx)
            try tx.execute("""
                INSERT INTO accounts (id, platform, displayName, phoneMasked, lastLoginStatus, dataSource, dataStatus, createdAt, updatedAt)
                VALUES ('acc-1', 'trae', '老账号', '138****0001', 'unknown', 'manual_entry', 'manual', 1000, 1000)
                """)
            try tx.execute("""
                INSERT INTO credit_snapshots (id, accountId, credits, totalCredits, queryAt, source, status)
                VALUES ('snap-1', 'acc-1', 50, 100, 1100, 'manual_entry', 'success')
                """)
            try tx.execute("""
                INSERT INTO switch_logs (id, accountId, fromStatus, toStatus, result, createdAt)
                VALUES ('log-1', 'acc-1', 'unknown', 'pendingConfirmation', 'unconfirmed', 1200)
                """)
        }
        try raw.execute("PRAGMA user_version = 1")
        raw.close()

        let service = try openDatabase()
        defer { service.close() }
        XCTAssertEqual(try userVersion(service.db), DatabaseService.supportedSchemaVersion)
        XCTAssertEqual(try service.db.scalar("SELECT COUNT(*) FROM accounts"), 1)
        XCTAssertEqual(try service.db.scalar("SELECT COUNT(*) FROM credit_snapshots"), 1)
        XCTAssertEqual(try service.db.scalar("SELECT COUNT(*) FROM switch_logs"), 1)
        // v3 重建后老账号字段保留
        let name = try service.db.query("SELECT displayName FROM accounts WHERE id = 'acc-1'") { $0.string(at: 0) }
        XCTAssertEqual(name.first, "老账号")
        // v4 回填：存在非 failed 切换日志 → lastUsedAt 取日志时间
        let lastUsed = try service.db.query("SELECT lastUsedAt FROM accounts WHERE id = 'acc-1'") { $0.double(at: 0) }
        XCTAssertEqual(lastUsed.first, 1200)
    }

    // MARK: 中间版本迁移（从 v5 起）

    func testMigrationFromMiddleVersion() throws {
        let raw = try SQLiteDatabase(path: dbURL.path)
        // v5 夹具：依次执行 v1-v5 的生产迁移步骤
        try raw.execute("PRAGMA foreign_keys = OFF")
        try raw.transaction { try MigrationV0ToV1().apply($0) }
        try raw.transaction { try MigrationV1ToV2().apply($0) }
        try raw.transaction { try MigrationV2ToV3().apply($0) }
        try raw.transaction { try MigrationV3ToV4().apply($0) }
        try raw.transaction { try MigrationV4ToV5().apply($0) }
        try raw.execute("PRAGMA foreign_keys = ON")
        try raw.execute("PRAGMA user_version = 5")
        try raw.execute("""
            INSERT INTO accounts (id, platform, displayName, phoneMasked, lastLoginStatus, dataSource, dataStatus, createdAt, updatedAt)
            VALUES ('acc-mid', 'workbuddy', '中途版本', '2', 'userConfirmed', 'manual_entry', 'manual', 2000, 2000)
            """)
        raw.close()

        let service = try openDatabase()
        defer { service.close() }
        XCTAssertEqual(try userVersion(service.db), DatabaseService.supportedSchemaVersion)
        // 只补跑 v6/v7：旧数据保留，新表出现
        XCTAssertEqual(try service.db.scalar("SELECT COUNT(*) FROM accounts"), 1)
        let status = try service.db.query("SELECT lastLoginStatus FROM accounts WHERE id = 'acc-mid'") { $0.string(at: 0) }
        XCTAssertEqual(status.first, "userConfirmed")
        let tables = try objectNames(service.db, type: "table")
        XCTAssertTrue(tables.contains("project_visits"))
        XCTAssertTrue(tables.contains("projects"))
        XCTAssertTrue(tables.contains("workstations"))
    }

    // MARK: 错误版本处理（库比代码新：不做任何改动）

    func testNewerDatabaseVersionIsLeftUntouched() throws {
        let service = try openDatabase()
        try service.db.execute("PRAGMA user_version = 99")
        service.close()

        let second = try openDatabase()
        defer { second.close() }
        XCTAssertEqual(try userVersion(second.db), 99, "不得回写版本号或重跑迁移")
        XCTAssertEqual(try second.db.scalar("SELECT COUNT(*) FROM accounts"), 0)
    }

    // MARK: 迁移中途失败：版本不前进、数据回滚

    func testFailedMigrationLeavesVersionAndDataUntouched() throws {
        let raw = try SQLiteDatabase(path: dbURL.path)
        try raw.transaction { tx in
            try MigrationV0ToV1().apply(tx)
            try tx.execute("""
                INSERT INTO accounts (id, platform, displayName, phoneMasked, lastLoginStatus, dataSource, dataStatus, createdAt, updatedAt)
                VALUES ('acc-f', 'trae', '失败夹具', '1', 'unknown', 'manual_entry', 'manual', 1, 1)
                """)
        }
        try raw.execute("PRAGMA user_version = 1")
        raw.close()

        struct FailingMigration: SchemaMigration {
            let fromVersion = 1
            let toVersion = 2
            func apply(_ tx: SQLiteTransaction) throws {
                try tx.execute("DELETE FROM accounts") // 先改动数据再抛错，验证回滚
                throw MigrationTests.failureStub
            }
        }

        let probe = try SQLiteDatabase(path: dbURL.path)
        let runner = MigrationRunner(migrations: [FailingMigration()])
        XCTAssertThrowsError(try runner.runIfNeeded(on: probe))
        XCTAssertEqual(try probe.scalar("SELECT COUNT(*) FROM accounts"), 1, "失败迁移必须整体回滚")
        XCTAssertEqual(try probe.scalar("PRAGMA user_version"), 1, "失败迁移不得推进版本号")
        probe.close()
    }

    private static let failureStub = NSError(domain: "MigrationTests", code: 1)

    // MARK: 连接配置：WAL + busy_timeout + foreign_keys

    func testConnectionEnablesWALAndBusyTimeout() throws {
        let service = try openDatabase()
        defer { service.close() }

        let mode = try service.db.query("PRAGMA journal_mode") { $0.string(at: 0) }
        XCTAssertEqual(mode.first, "wal", "应启用 WAL 日志模式")
        XCTAssertEqual(try service.db.scalar("PRAGMA busy_timeout"), 5000)
        XCTAssertEqual(try service.db.scalar("PRAGMA foreign_keys"), 1)
    }

    // MARK: WAL 场景下的备份一致性

    func testBackupUnderWALCapturesConsistentSnapshot() throws {
        let service = try openDatabase()
        let accounts = AccountService(database: service)
        let account = try accounts.create(platform: .workbuddy, displayName: "WAL备份", phoneMasked: "1")

        let backupURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backup-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: backupURL)
        }

        // 先备份，再写入新状态（留在 -wal 中，验证备份不含备份后的写入）
        try service.backup(to: backupURL)
        _ = try accounts.updateLoginStatus(id: account.id, status: .userConfirmed)
        service.close()

        // 用备份覆盖原库并重开：备份内容应是备份时点的一致快照
        try FileManager.default.removeItem(at: dbURL)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + suffix))
        }
        try FileManager.default.copyItem(at: backupURL, to: dbURL)

        let reopened = try openDatabase()
        defer { reopened.close() }
        let restored = try AccountService(database: reopened).listAll()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, account.id)
        XCTAssertEqual(restored.first?.lastLoginStatus, .unknown, "备份应是写入前的一致性快照")
    }

    // MARK: 数据库文件不可写

    func testReadOnlyDatabaseFileFailsToOpen() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("readonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("main.sqlite")
        FileManager.default.createFile(atPath: dbURL.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dbURL.path)
        defer {
            // 恢复可写权限，保证临时目录能被删除
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbURL.path)
            try? FileManager.default.removeItem(at: dir)
        }

        // 数据库文件不可写时应显式失败，而不是静默降级成半可用的库。
        XCTAssertThrowsError(try DatabaseService(databaseURL: dbURL))
    }
}
