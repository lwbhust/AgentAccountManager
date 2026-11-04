import Foundation

/// 本地账号记录。
///
/// 手机号不作为唯一标识（同一手机号可关联不同平台账号）。
/// 仅在 SQLite 中保存脱敏手机号；完整手机号（如有需要）存 Keychain。
public struct Account: Codable, Sendable, Identifiable {
    public static let tableName = "accounts"

    public var id: UUID
    public var platform: Platform
    public var displayName: String
    /// 脱敏手机号，如 138****1234
    public var phoneMasked: String
    /// 完整手机号的 SHA-256 摘要（可选），用于去重比较，不明文存储手机号
    public var phoneHash: String?
    public var planType: String?
    public var note: String?
    public var lastLoginStatus: LoginStatus
    public var lastCreditQueryAt: Date?
    /// 查询失败时保持 nil，绝不写 0
    public var currentCredits: Int?
    public var totalCredits: Int?
    /// 积分类型描述，如 "会员积分"、"奖励积分"
    public var creditType: String?
    /// 最近一次切换（启动）到该账号的时间；nil 表示从未切换过
    public var lastUsedAt: Date?
    public var dataSource: DataSource
    public var dataStatus: DataStatus
    /// TRAE 专属：该账号对应的 --user-data-dir 路径
    public var traeUserDataDir: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        platform: Platform,
        displayName: String,
        phoneMasked: String,
        phoneHash: String? = nil,
        planType: String? = nil,
        note: String? = nil,
        lastLoginStatus: LoginStatus = .unknown,
        lastCreditQueryAt: Date? = nil,
        currentCredits: Int? = nil,
        totalCredits: Int? = nil,
        creditType: String? = nil,
        lastUsedAt: Date? = nil,
        dataSource: DataSource = .manualEntry,
        dataStatus: DataStatus = .manual,
        traeUserDataDir: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.platform = platform
        self.displayName = displayName
        self.phoneMasked = phoneMasked
        self.phoneHash = phoneHash
        self.planType = planType
        self.note = note
        self.lastLoginStatus = lastLoginStatus
        self.lastCreditQueryAt = lastCreditQueryAt
        self.currentCredits = currentCredits
        self.totalCredits = totalCredits
        self.creditType = creditType
        self.lastUsedAt = lastUsedAt
        self.dataSource = dataSource
        self.dataStatus = dataStatus
        self.traeUserDataDir = traeUserDataDir
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Row 映射

    /// 列顺序与 SELECT 语句保持一致
    public static let columns = [
        "id", "platform", "displayName", "phoneMasked", "phoneHash",
        "planType", "note", "lastLoginStatus", "lastCreditQueryAt",
        "currentCredits", "totalCredits", "creditType",
        "lastUsedAt", "dataSource", "dataStatus", "traeUserDataDir",
        "createdAt", "updatedAt"
    ]

    public init(row: Row) {
        self.id = UUID(uuidString: row.string(at: 0) ?? "") ?? UUID()
        self.platform = Platform(rawValue: row.string(at: 1) ?? "") ?? .workbuddy
        self.displayName = row.string(at: 2) ?? ""
        self.phoneMasked = row.string(at: 3) ?? ""
        self.phoneHash = row.string(at: 4)
        self.planType = row.string(at: 5)
        self.note = row.string(at: 6)
        self.lastLoginStatus = LoginStatus(storedValue: row.string(at: 7) ?? "")
        self.lastCreditQueryAt = row.double(at: 8).map { Date(timeIntervalSince1970: $0) }
        self.currentCredits = row.int(at: 9)
        self.totalCredits = row.int(at: 10)
        self.creditType = row.string(at: 11)
        self.lastUsedAt = row.double(at: 12).map { Date(timeIntervalSince1970: $0) }
        self.dataSource = DataSource(rawValue: row.string(at: 13) ?? "") ?? .manualEntry
        self.dataStatus = DataStatus(rawValue: row.string(at: 14) ?? "") ?? .manual
        self.traeUserDataDir = row.string(at: 15)
        self.createdAt = row.double(at: 16).map { Date(timeIntervalSince1970: $0) } ?? Date()
        self.updatedAt = row.double(at: 17).map { Date(timeIntervalSince1970: $0) } ?? Date()
    }

    /// 用于 INSERT/UPDATE 的绑定值（按 columns 顺序）
    public var values: [SQLiteValue] {
        [
            .string(id.uuidString),
            .string(platform.rawValue),
            .string(displayName),
            .string(phoneMasked),
            phoneHash.sqliteValue,
            planType.sqliteValue,
            note.sqliteValue,
            .string(lastLoginStatus.rawValue),
            lastCreditQueryAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            currentCredits.sqliteValue,
            totalCredits.sqliteValue,
            creditType.sqliteValue,
            lastUsedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .string(dataSource.rawValue),
            .string(dataStatus.rawValue),
            traeUserDataDir.sqliteValue,
            .double(createdAt.timeIntervalSince1970),
            .double(updatedAt.timeIntervalSince1970)
        ]
    }
}

extension Account {
    /// 用于列表展示的积分文本
    public var creditsDisplay: String {
        guard dataStatus != .queryFailed else { return "查询失败" }
        guard let credits = currentCredits else { return "—" }
        return "\(credits)"
    }

    /// 是否有可展示的积分记录
    public var hasCreditRecord: Bool {
        currentCredits != nil || lastCreditQueryAt != nil
    }

    /// 手机号展示文本（未填写时不显示占位符空值）
    public var phoneDisplay: String {
        let trimmed = phoneMasked.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "—" ? "未填写手机号" : trimmed
    }

    /// 用于列表展示的最近查询时间文本
    public var lastQueryDisplay: String {
        guard let date = lastCreditQueryAt else { return "未查询" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// 用于展示的最近切换时间文本
    public var lastUsedDisplay: String {
        guard let date = lastUsedAt else { return "从未切换" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// 积分记录是否已超过给定有效期（未录入过视为过期）。
    public func isCreditStale(within interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let date = lastCreditQueryAt else { return true }
        return now.timeIntervalSince(date) > interval
    }
}
