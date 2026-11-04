import Foundation

/// 本地数据备份、恢复与清空。
///
/// 恢复流程按"校验 → 自动安全备份 → 替换 → 失败回滚"执行，
/// 避免用户选错文件或复制失败后丢失现有数据。
public struct BackupRestore {
    private let database: DatabaseService
    private let keychain: any KeychainStoring

    public init(database: DatabaseService, keychain: any KeychainStoring = KeychainService()) {
        self.database = database
        self.keychain = keychain
    }

    /// 备份数据库到指定目录（文件名自动加时间戳）。
    /// - Returns: 备份文件 URL
    /// - Note: 写入后会立刻校验备份文件可打开且结构完整，避免留下坏备份。
    @discardableResult
    public func backup(to directory: URL) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let fileName = "AgentAccountManager-backup-\(Self.timestamp()).sqlite"
        let dest = directory.appendingPathComponent(fileName)
        try database.backup(to: dest)
        try validate(dest)
        return dest
    }

    /// 从备份文件恢复数据库。
    /// - Returns: 恢复前自动生成的安全备份路径（恢复前的数据）。
    /// - Important: 恢复会覆盖当前数据库，调用前应提示用户。
    @discardableResult
    public func restore(from backupURL: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupURL.path) else {
            throw RestoreError.backupNotFound
        }
        guard backupURL.standardizedFileURL != database.databaseURL.standardizedFileURL else {
            throw RestoreError.invalidBackup("不能选择当前正在使用的数据库文件")
        }
        try validate(backupURL)

        // 先备份当前数据，后续任何失败都能回滚
        let safety = try makeSafetyBackup()

        database.close()
        if fm.fileExists(atPath: database.databaseURL.path) {
            try fm.removeItem(at: database.databaseURL)
        }
        do {
            try fm.copyItem(at: backupURL, to: database.databaseURL)
        } catch {
            if fm.fileExists(atPath: database.databaseURL.path) {
                try? fm.removeItem(at: database.databaseURL)
            }
            try? fm.copyItem(at: safety, to: database.databaseURL)
            removeSidecarFiles()
            throw RestoreError.restoreFailed(error.localizedDescription)
        }
        removeSidecarFiles()
        return safety
    }

    /// 删除所有本地数据：数据库文件与钥匙串中的完整手机号。
    /// - Warning: 此操作不可逆。
    public func deleteAllData() throws {
        let fm = FileManager.default
        database.close()
        if fm.fileExists(atPath: database.databaseURL.path) {
            try fm.removeItem(at: database.databaseURL)
        }
        removeSidecarFiles()
        keychain.deleteAll()
    }

    // MARK: - 校验与辅助

    /// 校验目标文件确实是本应用可用的数据库。
    private func validate(_ url: URL) throws {
        let probe: SQLiteDatabase
        do {
            probe = try SQLiteDatabase(path: url.path, readOnly: true)
        } catch {
            throw RestoreError.invalidBackup("无法打开该文件：\(error.localizedDescription)")
        }
        defer { probe.close() }

        let hasAccountsTable: Int
        let version: Int
        let integrity: String?
        do {
            hasAccountsTable = try probe.scalar(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='accounts'"
            )
            version = try probe.scalar("PRAGMA user_version")
            integrity = try probe.queryFirst("PRAGMA integrity_check") { $0.string(at: 0) ?? "" }
        } catch {
            throw RestoreError.invalidBackup("文件不是有效的 SQLite 数据库")
        }

        guard integrity == "ok" else {
            throw RestoreError.invalidBackup("数据库完整性校验未通过")
        }
        guard hasAccountsTable == 1 else {
            throw RestoreError.invalidBackup("文件中缺少账号表，可能不是本应用的备份")
        }
        guard version >= 1, version <= DatabaseService.supportedSchemaVersion else {
            throw RestoreError.invalidBackup("备份的数据版本（v\(version)）不受支持")
        }
    }

    /// 把当前数据库复制成一份安全备份。
    private func makeSafetyBackup() throws -> URL {
        let directory = database.databaseURL.deletingLastPathComponent()
        let url = directory.appendingPathComponent("AgentAccountManager-pre-restore-\(Self.timestamp()).sqlite")
        do {
            try database.backup(to: url)
        } catch {
            throw RestoreError.safetyBackupFailed(error.localizedDescription)
        }
        return url
    }

    /// 删除可能残留的 WAL/SHM 边车文件，避免旧日志作用到替换后的数据库。
    private func removeSidecarFiles() {
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] {
            let url = URL(fileURLWithPath: database.databaseURL.path + suffix)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    public enum RestoreError: LocalizedError {
        case backupNotFound
        case invalidBackup(String)
        case safetyBackupFailed(String)
        case restoreFailed(String)

        public var errorDescription: String? {
            switch self {
            case .backupNotFound:
                return "找不到所选备份文件"
            case .invalidBackup(let reason):
                return "无法使用该备份：\(reason)"
            case .safetyBackupFailed(let reason):
                return "恢复前备份当前数据失败，已取消恢复：\(reason)"
            case .restoreFailed(let reason):
                return "恢复失败，已回滚到恢复前的数据：\(reason)"
            }
        }
    }
}
