import Foundation

/// 单个 schema 迁移步骤。
///
/// 每个迁移有明确的前置版本（fromVersion）与目标版本（toVersion）；
/// `apply` 在 MigrationRunner 开启的事务内执行，失败整体回滚，
/// user_version 不前进，下次打开自动重试——不留不完整状态。
protocol SchemaMigration {
    var fromVersion: Int { get }
    var toVersion: Int { get }
    /// 重建表类迁移需要在事务外临时关闭外键（PRAGMA foreign_keys 在事务内无效）。
    var requiresForeignKeysOff: Bool { get }
    func apply(_ tx: SQLiteTransaction) throws
}

extension SchemaMigration {
    var requiresForeignKeysOff: Bool { false }
}

/// 迁移错误。
enum MigrationError: Error, LocalizedError {
    /// 版本链不连续（理论上不该出现，显式报错而不是静默跳过）。
    case versionGap(found: Int, expected: Int)

    var errorDescription: String? {
        switch self {
        case .versionGap(let found, let expected):
            return "数据库 schema 版本不连续：当前 \(found)，迁移期望 \(expected)"
        }
    }
}

/// 迁移执行器：按版本顺序执行待应用的迁移，每步独立事务。
///
/// - 已迁移过的步骤不会重复执行（`user_version >= toVersion` 即跳过）；
/// - 库版本比代码新（user_version 超出迁移链）时不做任何改动；
/// - 每步迁移把 `PRAGMA user_version` 的推进放进同一事务，保证「结构 + 版本」原子生效。
struct MigrationRunner {
    let migrations: [any SchemaMigration]

    /// 全量迁移链（v1 → 当前版本），顺序即执行顺序。
    /// DatabaseService.supportedSchemaVersion 必须与链尾 toVersion 一致。
    static let `default` = MigrationRunner(migrations: [
        MigrationV0ToV1(),
        MigrationV1ToV2(),
        MigrationV2ToV3(),
        MigrationV3ToV4(),
        MigrationV4ToV5(),
        MigrationV5ToV6(),
        MigrationV6ToV7()
    ])

    /// 执行待应用的迁移。
    func runIfNeeded(on db: SQLiteDatabase) throws {
        var version = try db.scalar("PRAGMA user_version")
        for migration in migrations where version < migration.toVersion {
            guard migration.fromVersion == version else {
                throw MigrationError.versionGap(found: version, expected: migration.fromVersion)
            }
            if migration.requiresForeignKeysOff {
                try db.execute("PRAGMA foreign_keys = OFF")
            }
            do {
                try db.transaction { tx in
                    try migration.apply(tx)
                    try tx.execute("PRAGMA user_version = \(migration.toVersion)")
                }
            } catch {
                if migration.requiresForeignKeysOff {
                    try? db.execute("PRAGMA foreign_keys = ON")
                }
                throw error
            }
            if migration.requiresForeignKeysOff {
                try db.execute("PRAGMA foreign_keys = ON")
            }
            version = migration.toVersion
        }
    }
}
