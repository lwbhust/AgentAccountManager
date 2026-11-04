import Foundation
import SQLite3

/// 轻量 SQLite 封装，提供安全的参数绑定与行读取。
/// 替代 GRDB（因本机 SwiftPM 工具链损坏无法解析依赖）。
public final class SQLiteDatabase: Sendable {
    private let dbQueue: DispatchQueue
    nonisolated(unsafe) private var db: OpaquePointer?
    public let path: String

    /// - Parameter readOnly: 以只读方式打开，用于校验备份文件，避免误写用户选中的文件。
    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        self.dbQueue = DispatchQueue(label: "com.agentaccountmanager.sqlite.\(path)")
        var handle: OpaquePointer?
        let flags: Int32 = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        let rc = sqlite3_open_v2(
            path,
            &handle,
            flags,
            nil
        )
        guard rc == SQLITE_OK, let handle else {
            throw SQLiteError.openFailed(rc)
        }
        self.db = handle
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - 执行（无返回结果）

    /// 执行 SQL，支持 ? 占位符参数。
    @discardableResult
    public func execute(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int {
        try dbQueue.sync { try executeUnsafe(sql, parameters) }
    }

    /// 事务：BEGIN IMMEDIATE → 执行 → COMMIT，失败自动 ROLLBACK。
    ///
    /// 事务期间独占数据库队列，`body` 内只能使用传入的 `SQLiteTransaction`
    /// （不要调用 `SQLiteDatabase` 的公开方法，否则会死锁）。
    public func transaction<T>(_ body: (SQLiteTransaction) throws -> T) throws -> T {
        try dbQueue.sync {
            try executeUnsafe("BEGIN IMMEDIATE")
            do {
                let value = try body(SQLiteTransaction(database: self))
                try executeUnsafe("COMMIT")
                return value
            } catch {
                _ = try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    /// 已持有数据库队列时执行（内部使用）。
    @discardableResult
    fileprivate func executeUnsafe(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int {
        guard let db else { throw SQLiteError.closed }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(errorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt: stmt, parameters)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw SQLiteError.stepFailed(errorMessage())
        }
        return Int(sqlite3_changes(db))
    }

    // MARK: - 查询

    /// 查询并映射每一行。
    public func query<T>(_ sql: String, _ parameters: [SQLiteValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        try dbQueue.sync { try queryUnsafe(sql, parameters, map) }
    }

    /// 已持有数据库队列时查询（内部使用）。
    fileprivate func queryUnsafe<T>(_ sql: String, _ parameters: [SQLiteValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        guard let db else { throw SQLiteError.closed }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(errorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt: stmt, parameters)
        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            try results.append(map(Row(stmt: stmt!)))
        }
        return results
    }

    /// 查询首行。
    public func queryFirst<T>(_ sql: String, _ parameters: [SQLiteValue] = [], _ map: (Row) throws -> T) throws -> T? {
        try query(sql, parameters, map).first
    }

    /// 查询单个标量值（如 COUNT）。
    public func scalar(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int {
        let rows = try query(sql, parameters) { row in
            row.int(at: 0) ?? 0
        }
        return rows.first ?? 0
    }

    // MARK: - 私有

    private func bind(stmt: OpaquePointer?, _ values: [SQLiteValue]) throws {
        for (index, value) in values.enumerated() {
            let idx = Int32(index + 1)
            switch value {
            case .null:
                sqlite3_bind_null(stmt, idx)
            case .int(let v):
                sqlite3_bind_int64(stmt, idx, Int64(v))
            case .int64(let v):
                sqlite3_bind_int64(stmt, idx, v)
            case .string(let v):
                sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .double(let v):
                sqlite3_bind_double(stmt, idx, v)
            case .data(let v):
                v.withUnsafeBytes { ptr in
                    _ = sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            }
        }
    }

    private func errorMessage() -> String {
        guard let db, let msg = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: msg)
    }

    // 需在 dbQueue 内调用
    private func closeInternal() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    public func close() {
        dbQueue.sync { closeInternal() }
    }

    /// 数据库真空备份到另一路径（用于备份）。
    public func backup(to destPath: String) throws {
        try dbQueue.sync {
            guard let db else { throw SQLiteError.closed }
            var dest: OpaquePointer?
            guard sqlite3_open(destPath, &dest) == SQLITE_OK, let dest else {
                throw SQLiteError.openFailed(0)
            }
            defer { sqlite3_close(dest) }
            let bk = sqlite3_backup_init(dest, "main", db, "main")
            guard let bk else {
                throw SQLiteError.backupFailed(String(cString: sqlite3_errmsg(dest)))
            }
            sqlite3_backup_step(bk, -1)
            sqlite3_backup_finish(bk)
        }
        normalizeBackupJournalMode(destPath: destPath)
    }

    /// 归一化备份文件的 journal 模式。
    ///
    /// Backup API 会连同页头一起复制，源库处于 WAL 模式时备份文件也带 WAL 标志，
    /// 而 WAL 库无法以只读方式打开（缺 -shm），会破坏备份校验与跨设备恢复。
    /// 将备份文件转回 DELETE journal，使其成为独立可用的单文件备份。
    private func normalizeBackupJournalMode(destPath: String) {
        var dest: OpaquePointer?
        guard sqlite3_open(destPath, &dest) == SQLITE_OK, let dest else { return }
        defer { sqlite3_close(dest) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dest, "PRAGMA journal_mode = DELETE", -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            rc = sqlite3_step(stmt)
        }
    }
}

/// 事务上下文：只能在 `SQLiteDatabase.transaction` 的闭包内使用。
///
/// 它直接复用调用方已经持有的数据库队列，避免嵌套加锁死锁。
public struct SQLiteTransaction {
    fileprivate let database: SQLiteDatabase

    @discardableResult
    public func execute(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int {
        try database.executeUnsafe(sql, parameters)
    }

    public func query<T>(_ sql: String, _ parameters: [SQLiteValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        try database.queryUnsafe(sql, parameters, map)
    }

    public func queryFirst<T>(_ sql: String, _ parameters: [SQLiteValue] = [], _ map: (Row) throws -> T) throws -> T? {
        try database.queryUnsafe(sql, parameters, map).first
    }
}

/// 支持绑定到 SQLite 的值类型。
public enum SQLiteValue {
    case null
    case int(Int)
    case int64(Int64)
    case string(String)
    case double(Double)
    case data(Data)
}

extension Int: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { .int(self) }
}
extension Int64: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { .int64(self) }
}
extension String: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { .string(self) }
}
extension Double: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { .double(self) }
}
extension Data: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue { .data(self) }
}
extension Optional where Wrapped: SQLiteValueConvertible {
    public var sqliteValue: SQLiteValue {
        switch self {
        case .some(let v): return v.sqliteValue
        case .none: return .null
        }
    }
}

public protocol SQLiteValueConvertible {
    var sqliteValue: SQLiteValue { get }
}

/// 查询结果行。
public struct Row {
    private let stmt: OpaquePointer

    init(stmt: OpaquePointer) {
        self.stmt = stmt
    }

    public func int(at index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }

    public func int64(at index: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, index)
    }

    public func string(at index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    public func double(at index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    public func data(at index: Int32) -> Data? {
        guard let ptr = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: ptr, count: count)
    }

    /// 按列名查找索引（性能略差，仅用于调试/灵活场景）
    public func index(forColumn name: String) -> Int32? {
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            if let colName = sqlite3_column_name(stmt, i), String(cString: colName) == name {
                return i
            }
        }
        return nil
    }
}

public enum SQLiteError: Error, LocalizedError {
    case openFailed(Int32)
    case closed
    case prepareFailed(String)
    case stepFailed(String)
    case backupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let code): return "SQLite 打开失败 (code=\(code))"
        case .closed: return "SQLite 数据库已关闭"
        case .prepareFailed(let msg): return "SQL 准备失败: \(msg)"
        case .stepFailed(let msg): return "SQL 执行失败: \(msg)"
        case .backupFailed(let msg): return "SQLite 备份失败: \(msg)"
        }
    }
}

// SQLITE_TRANSIENT 常量
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
