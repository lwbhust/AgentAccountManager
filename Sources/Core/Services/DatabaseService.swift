import Foundation

/// 数据库服务，封装 SQLiteDatabase 连接配置与 schema 迁移调度。
///
/// 数据库文件位于 ~/Library/Application Support/AgentAccountManager/AgentAccountManager.sqlite
/// 迁移步骤见 Persistence/Migrations/（由 MigrationRunner 按版本链执行）。
public final class DatabaseService: Sendable {
    /// 当前代码支持的 schema 版本（用于备份校验）。必须与迁移链尾 toVersion 一致。
    public static let supportedSchemaVersion = 7

    public let db: SQLiteDatabase
    public let databaseURL: URL

    public init(databaseURL: URL? = nil) throws {
        let url = try databaseURL ?? Self.defaultDatabaseURL()
        self.databaseURL = url
        self.db = try SQLiteDatabase(path: url.path)
        try configureConnection()
        try MigrationRunner.default.runIfNeeded(on: db)
    }

    /// 每次打开连接时的连接级配置。
    ///
    /// - foreign_keys：按连接生效，必须在每次打开时开启，否则删除账号不会级联。
    /// - busy_timeout：遭遇短暂写锁（如备份/校验只读连接）时等待 5 秒而不是立刻报错。
    /// - WAL：写不阻塞读、崩溃恢复更稳；备份走 SQLite Backup API，与 -wal/-shm 兼容
    ///   （恢复流程已统一清理这两个副产物文件）。启用失败仅记录并沿用默认 journal，
    ///   不作为致命错误——它影响的是并发表现，不是正确性。
    private func configureConnection() throws {
        try db.execute("PRAGMA foreign_keys = ON")
        _ = try db.query("PRAGMA busy_timeout = 5000") { $0.int(at: 0) }
        let mode = try db.query("PRAGMA journal_mode = WAL") { $0.string(at: 0) }
        if mode.first != "wal" {
            AppLogger(category: "database").error("SQLite WAL 模式启用失败（journal_mode=\(mode.first ?? "unknown")），沿用默认 journal 继续")
        }
    }

    /// 默认数据库文件路径。
    public static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("AgentAccountManager", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("AgentAccountManager.sqlite")
    }

    // MARK: - 备份

    /// 将数据库文件复制到目标 URL，用于本地备份。
    public func backup(to url: URL) throws {
        try db.backup(to: url.path)
    }

    /// 关闭数据库连接。
    public func close() {
        db.close()
    }
}
