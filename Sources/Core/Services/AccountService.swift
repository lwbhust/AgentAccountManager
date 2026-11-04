import Foundation

/// 账号 CRUD 业务逻辑。
public final class AccountService: Sendable {
    private let db: DatabaseService
    private let logger: AppLogger

    public init(database: DatabaseService, logger: AppLogger = AppLogger(category: "account")) {
        self.db = database
        self.logger = logger
    }

    private var cols: String { Account.columns.joined(separator: ", ") }

    // MARK: - 查询

    /// 列出所有账号：最近切换过的排前面，其余按平台、创建时间排序。
    public func listAll() throws -> [Account] {
        try db.db.query(
            """
            SELECT \(cols) FROM accounts
            ORDER BY (lastUsedAt IS NULL) ASC, lastUsedAt DESC, platform ASC, createdAt ASC
            """
        ) { Account(row: $0) }
    }

    /// 按平台筛选账号（同样最近使用优先）。
    public func list(platform: Platform) throws -> [Account] {
        try db.db.query(
            """
            SELECT \(cols) FROM accounts WHERE platform = ?
            ORDER BY (lastUsedAt IS NULL) ASC, lastUsedAt DESC, createdAt ASC
            """,
            [.string(platform.rawValue)]
        ) { Account(row: $0) }
    }

    /// 按手机号摘要查找账号（用于表单查重提示）。
    public func find(byPhoneHash hash: String) throws -> [Account] {
        try db.db.query(
            "SELECT \(cols) FROM accounts WHERE phoneHash = ?",
            [.string(hash)]
        ) { Account(row: $0) }
    }

    /// 获取单个账号。
    public func get(id: UUID) throws -> Account? {
        try db.db.queryFirst(
            "SELECT \(cols) FROM accounts WHERE id = ?",
            [.string(id.uuidString)]
        ) { Account(row: $0) }
    }

    // MARK: - 新增

    /// 新增账号。phoneHash 可选，用于去重比较。
    @discardableResult
    public func create(
        platform: Platform,
        displayName: String,
        phoneMasked: String,
        phoneHash: String? = nil,
        planType: String? = nil,
        note: String? = nil
    ) throws -> Account {
        let account = Account(
            platform: platform,
            displayName: displayName,
            phoneMasked: phoneMasked,
            phoneHash: phoneHash,
            planType: planType,
            note: note
        )
        let placeholders = Array(repeating: "?", count: Account.columns.count).joined(separator: ", ")
        try db.db.execute(
            "INSERT INTO accounts (\(cols)) VALUES (\(placeholders))",
            account.values
        )
        logger.info("账号已创建: id=\(account.id.uuidString.prefix(8)) platform=\(platform.rawValue)")
        return account
    }

    // MARK: - 更新

    /// 更新账号的可编辑字段（名称、备注、套餐）。
    ///
    /// 表单提交的是完整快照：`note` / `planType` 传 nil 表示清空该字段，
    /// 而不是"保持不变"；`displayName` 为空时保留原值。
    @discardableResult
    public func update(
        id: UUID,
        displayName: String? = nil,
        note: String? = nil,
        planType: String? = nil
    ) throws -> Account? {
        guard var account = try get(id: id) else { return nil }
        if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            account.displayName = displayName
        }
        account.note = note
        account.planType = planType
        account.updatedAt = Date()
        try save(&account)
        return account
    }

    /// 更新账号的登录状态。
    @discardableResult
    public func updateLoginStatus(id: UUID, status: LoginStatus) throws -> Account? {
        guard var account = try get(id: id) else { return nil }
        account.lastLoginStatus = status
        account.updatedAt = Date()
        try save(&account)
        return account
    }

    /// 更新账号的手机号（仅保存脱敏值与摘要，完整值由调用方存入 Keychain）。
    @discardableResult
    public func updatePhone(id: UUID, phoneMasked: String, phoneHash: String?) throws -> Account? {
        guard var account = try get(id: id) else { return nil }
        account.phoneMasked = phoneMasked
        account.phoneHash = phoneHash
        account.updatedAt = Date()
        try save(&account)
        return account
    }

    /// 记录账号的最近使用时间（切换成功启动后调用）。
    @discardableResult
    public func markUsed(id: UUID, at date: Date = Date()) throws -> Account? {
        guard var account = try get(id: id) else { return nil }
        account.lastUsedAt = date
        account.updatedAt = Date()
        try save(&account)
        return account
    }

    // MARK: - 事务上下文变体（供 SwitchService 原子提交组合使用）
    //
    // SQLiteDatabase.transaction 期间独占数据库队列，闭包内不得调用本服务的
    // 公开方法（其内部经 dbQueue.sync 会死锁），必须使用传入的 SQLiteTransaction。
    // 以下为定向 UPDATE：只改目标列，避免整行重写覆盖并发修改。

    /// 事务上下文：更新登录状态。
    @discardableResult
    public func updateLoginStatus(_ tx: SQLiteTransaction, id: UUID, status: LoginStatus) throws -> Int {
        try tx.execute(
            "UPDATE accounts SET lastLoginStatus = ?, updatedAt = ? WHERE id = ?",
            [.string(status.rawValue), .double(Date().timeIntervalSince1970), .string(id.uuidString)]
        )
    }

    /// 事务上下文：记录最近使用时间。
    @discardableResult
    public func markUsed(_ tx: SQLiteTransaction, id: UUID, at date: Date = Date()) throws -> Int {
        try tx.execute(
            "UPDATE accounts SET lastUsedAt = ?, updatedAt = ? WHERE id = ?",
            [.double(date.timeIntervalSince1970), .double(Date().timeIntervalSince1970), .string(id.uuidString)]
        )
    }

    /// 全量保存（UPDATE 现有账号，避免触发外键级联删除）。
    public func save(_ account: inout Account) throws {
        account.updatedAt = Date()
        let setCols = Account.columns.filter { $0 != "id" }
        let setClause = setCols.map { "\($0) = ?" }.joined(separator: ", ")
        var values = account.values
        values.removeFirst() // 去掉 id（对应 columns[0]）
        values.append(.string(account.id.uuidString)) // WHERE id = ?
        try db.db.execute(
            "UPDATE accounts SET \(setClause) WHERE id = ?",
            values
        )
    }

    // MARK: - 删除

    /// 删除本地账号记录，同时删除其额度快照与切换日志（外键级联）。
    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        let changes = try db.db.execute(
            "DELETE FROM accounts WHERE id = ?",
            [.string(id.uuidString)]
        )
        if changes > 0 {
            logger.info("账号已删除: id=\(id.uuidString.prefix(8))")
        }
        return changes > 0
    }

    // MARK: - 计数

    public func count() throws -> Int {
        try db.db.scalar("SELECT COUNT(*) FROM accounts")
    }
}
