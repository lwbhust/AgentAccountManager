import Foundation

/// 工位：项目里的一个独立工作目录与分支，可绑定一个 TRAE 账号。
///
/// `accountId` 在角色剧本模式下是固定绑定；在自由工位模式下表示上次使用的账号，
/// 开工前允许更换。工位不保存任何积分字段。
public struct Workstation: Codable, Sendable, Identifiable {
    public static let tableName = "workstations"

    public var id: UUID
    public var projectId: UUID
    public var accountId: UUID?
    public var displayName: String
    public var roleTag: String?
    public var worktreePath: String?
    public var branchName: String?
    public var isEnabled: Bool
    public var lastActivatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        accountId: UUID? = nil,
        displayName: String,
        roleTag: String? = nil,
        worktreePath: String? = nil,
        branchName: String? = nil,
        isEnabled: Bool = true,
        lastActivatedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.accountId = accountId
        self.displayName = displayName
        self.roleTag = roleTag
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.isEnabled = isEnabled
        self.lastActivatedAt = lastActivatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let columns = [
        "id", "projectId", "accountId", "displayName", "roleTag",
        "worktreePath", "branchName", "isEnabled", "lastActivatedAt",
        "createdAt", "updatedAt"
    ]

    public init(row: Row) {
        self.id = UUID(uuidString: row.string(at: 0) ?? "") ?? UUID()
        self.projectId = UUID(uuidString: row.string(at: 1) ?? "") ?? UUID()
        self.accountId = row.string(at: 2).flatMap(UUID.init(uuidString:))
        self.displayName = row.string(at: 3) ?? ""
        self.roleTag = row.string(at: 4)
        self.worktreePath = row.string(at: 5)
        self.branchName = row.string(at: 6)
        self.isEnabled = (row.int(at: 7) ?? 1) != 0
        self.lastActivatedAt = row.double(at: 8).map { Date(timeIntervalSince1970: $0) }
        self.createdAt = row.double(at: 9).map { Date(timeIntervalSince1970: $0) } ?? Date()
        self.updatedAt = row.double(at: 10).map { Date(timeIntervalSince1970: $0) } ?? Date()
    }

    public var values: [SQLiteValue] {
        [
            .string(id.uuidString),
            .string(projectId.uuidString),
            accountId.map { .string($0.uuidString) } ?? .null,
            .string(displayName),
            roleTag.sqliteValue,
            worktreePath.sqliteValue,
            branchName.sqliteValue,
            .int(isEnabled ? 1 : 0),
            lastActivatedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .double(createdAt.timeIntervalSince1970),
            .double(updatedAt.timeIntervalSince1970)
        ]
    }
}

extension Workstation {
    public var worktreeURL: URL? {
        worktreePath.map { URL(fileURLWithPath: $0) }
    }

    public var roleDisplay: String {
        let trimmed = roleTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "通用" : trimmed
    }
}
