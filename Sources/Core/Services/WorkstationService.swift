import Foundation

/// 工位 CRUD、绑定校验与稳定路径/分支生成。
public final class WorkstationService: Sendable {
    public static let maxEnabledPerProject = 3
    public static let defaultWorktreeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Workbench", isDirectory: true)

    private let db: DatabaseService
    private let logger: AppLogger

    public init(database: DatabaseService, logger: AppLogger = AppLogger(category: "workstation")) {
        self.db = database
        self.logger = logger
    }

    private var cols: String { Workstation.columns.joined(separator: ", ") }

    // MARK: - 查询

    public func listAll() throws -> [Workstation] {
        try db.db.query(
            "SELECT \(cols) FROM workstations ORDER BY createdAt ASC"
        ) { Workstation(row: $0) }
    }

    public func list(projectId: UUID) throws -> [Workstation] {
        try db.db.query(
            "SELECT \(cols) FROM workstations WHERE projectId = ? ORDER BY createdAt ASC",
            [.string(projectId.uuidString)]
        ) { Workstation(row: $0) }
    }

    public func get(id: UUID) throws -> Workstation? {
        try db.db.queryFirst(
            "SELECT \(cols) FROM workstations WHERE id = ?",
            [.string(id.uuidString)]
        ) { Workstation(row: $0) }
    }

    public func countEnabled(projectId: UUID) throws -> Int {
        try db.db.scalar(
            "SELECT COUNT(*) FROM workstations WHERE projectId = ? AND isEnabled = 1",
            [.string(projectId.uuidString)]
        )
    }

    // MARK: - 默认工位

    /// 新项目默认创建 3 个工位，名称与角色随编排模式不同。
    @discardableResult
    public func createDefaults(for project: Project) throws -> [Workstation] {
        if try !list(projectId: project.id).isEmpty {
            return try list(projectId: project.id)
        }

        let seeds: [(String, String?)] = {
            switch project.orchestrationMode {
            case .freeLane:
                return [("工位 1", nil), ("工位 2", nil), ("工位 3", nil)]
            case .rolePlay:
                return [("实现", "开发"), ("评审", "评审"), ("验收", "验收")]
            }
        }()

        var created: [Workstation] = []
        for (index, seed) in seeds.enumerated() {
            let workstation = try create(
                project: project,
                displayName: seed.0,
                roleTag: seed.1,
                accountId: nil,
                isEnabled: true,
                slugSeed: "lane\(index + 1)"
            )
            created.append(workstation)
        }
        logger.info("默认工位已创建: project=\(project.id.uuidString.prefix(8)) count=\(created.count)")
        return created
    }

    // MARK: - 新增

    @discardableResult
    public func create(
        project: Project,
        displayName: String,
        roleTag: String? = nil,
        accountId: UUID? = nil,
        isEnabled: Bool = true
    ) throws -> Workstation {
        let index = try list(projectId: project.id).count
        return try create(
            project: project,
            displayName: displayName,
            roleTag: roleTag,
            accountId: accountId,
            isEnabled: isEnabled,
            slugSeed: "lane\(index + 1)"
        )
    }

    @discardableResult
    private func create(
        project: Project,
        displayName: String,
        roleTag: String?,
        accountId: UUID?,
        isEnabled: Bool,
        slugSeed: String
    ) throws -> Workstation {
        let name = try validateName(displayName)
        if isEnabled, try countEnabled(projectId: project.id) >= Self.maxEnabledPerProject {
            throw WorkstationError.tooManyEnabled
        }
        if let accountId {
            try validateAccount(accountId, projectId: project.id, excluding: nil)
        }
        let plan = try plan(project: project, displayName: name, slugSeed: slugSeed)
        let workstation = Workstation(
            projectId: project.id,
            accountId: accountId,
            displayName: name,
            roleTag: ProjectService.clean(roleTag),
            worktreePath: plan.path,
            branchName: plan.branch,
            isEnabled: isEnabled
        )
        try insert(workstation)
        return workstation
    }

    // MARK: - 批量更新

    /// 工作台设置页一次保存全部工位。所有校验通过后才写库，避免部分保存。
    public func updateBatch(project: Project, workstations: [Workstation]) throws {
        guard !workstations.isEmpty else { return }
        let projectId = project.id

        let existing = try list(projectId: projectId)
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var merged: [UUID: Workstation] = existingById
        for item in workstations {
            guard existingById[item.id] != nil else {
                throw WorkstationError.notFound
            }
            var copy = item
            copy.displayName = try validateName(item.displayName)
            copy.roleTag = ProjectService.clean(item.roleTag)
            copy.projectId = projectId
            merged[item.id] = copy
        }

        let values = Array(merged.values)
        let enabled = values.filter(\.isEnabled)
        if enabled.count > Self.maxEnabledPerProject {
            throw WorkstationError.tooManyEnabled
        }
        let names = values.map(\.displayName)
        if Set(names).count != names.count {
            throw WorkstationError.duplicateName
        }
        let accountIds = values.compactMap(\.accountId)
        if Set(accountIds).count != accountIds.count {
            throw WorkstationError.duplicateAccount
        }
        for accountId in accountIds {
            try validateAccount(accountId, projectId: projectId, excluding: nil)
        }

        try db.db.transaction { tx in
            for item in values {
                try tx.execute(
                    """
                    UPDATE workstations
                    SET displayName = ?, roleTag = ?, accountId = ?, isEnabled = ?, updatedAt = ?
                    WHERE id = ? AND projectId = ?
                    """,
                    [
                        .string(item.displayName),
                        item.roleTag.sqliteValue,
                        item.accountId.map { .string($0.uuidString) } ?? .null,
                        .int(item.isEnabled ? 1 : 0),
                        .double(Date().timeIntervalSince1970),
                        .string(item.id.uuidString),
                        .string(projectId.uuidString)
                    ]
                )
            }
        }
        logger.info("工位设置已保存: project=\(projectId.uuidString.prefix(8)) count=\(values.count)")
    }

    /// 自由工位模式下更新上次使用的账号。
    public func assignAccount(workstationId: UUID, accountId: UUID?) throws {
        guard var workstation = try get(id: workstationId) else {
            throw WorkstationError.notFound
        }
        if let accountId {
            try validateAccount(accountId, projectId: workstation.projectId, excluding: workstationId)
        }
        workstation.accountId = accountId
        workstation.updatedAt = Date()
        try save(&workstation)
    }

    public func touchLastActivated(id: UUID, at date: Date = Date()) throws {
        guard var workstation = try get(id: id) else { return }
        workstation.lastActivatedAt = date
        workstation.updatedAt = date
        try save(&workstation)
    }

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        let changes = try db.db.execute(
            "DELETE FROM workstations WHERE id = ?",
            [.string(id.uuidString)]
        )
        return changes > 0
    }

    // MARK: - 账号引用

    public struct WorkstationReference: Sendable, Identifiable {
        public let projectName: String
        public let workstationName: String
        public var id: String { "\(projectName)|\(workstationName)" }
    }

    /// 某账号被哪些工位引用（用于删除账号前的影响提示）。
    public func references(forAccountId accountId: UUID) throws -> [WorkstationReference] {
        try db.db.query(
            """
            SELECT p.displayName, w.displayName
            FROM workstations w
            JOIN projects p ON p.id = w.projectId
            WHERE w.accountId = ?
            ORDER BY p.displayName ASC, w.displayName ASC
            """,
            [.string(accountId.uuidString)]
        ) { row in
            WorkstationReference(
                projectName: row.string(at: 0) ?? "未命名项目",
                workstationName: row.string(at: 1) ?? "未命名工位"
            )
        }
    }

    // MARK: - 路径与分支

    public struct Plan: Sendable {
        public let path: String
        public let branch: String
    }

    /// 生成稳定的 worktree 路径与分支名。默认根目录 ~/Workbench。
    public func plan(
        project: Project,
        displayName: String,
        slugSeed: String
    ) throws -> Plan {
        let root = try normalizedRoot(for: project)
        let namespace = Self.projectNamespace(for: project)
        let baseSlug = Self.slug(from: slugSeed.isEmpty ? displayName : slugSeed)
        let projectRoot = root.appendingPathComponent(namespace, isDirectory: true)

        var candidate = baseSlug
        var suffix = 2
        while try pathOrBranchExists(projectId: project.id, path: projectRoot.appendingPathComponent(candidate).path, branch: "workbench/\(namespace)/\(candidate)")
            || FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(candidate).path) {
            candidate = "\(baseSlug)-\(suffix)"
            suffix += 1
            if suffix > 50 { throw WorkstationError.cannotAllocatePath }
        }

        return Plan(
            path: projectRoot.appendingPathComponent(candidate).path,
            branch: "workbench/\(namespace)/\(candidate)"
        )
    }

    public static func projectNamespace(for project: Project) -> String {
        let base = slug(from: project.repoNamespace)
        let shortId = project.id.uuidString.prefix(6).lowercased()
        return "\(base)-\(shortId)"
    }

    public static func slug(from raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let limited = String(collapsed.prefix(32))
        return limited.isEmpty ? "lane" : limited
    }

    // MARK: - 私有

    private func normalizedRoot(for project: Project) throws -> URL {
        let raw = project.worktreeRoot ?? Self.defaultWorktreeRoot.path
        let path = ProjectService.normalizePath(raw)
        guard !path.isEmpty else { throw WorkstationError.invalidRoot }
        try Self.validateRoot(path)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func validateRoot(_ path: String) throws {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let forbiddenExact = ["/", "/System", "/Applications", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private"]
        let forbiddenPrefixes = ["/System/", "/Applications/", "/Library/", "/usr/", "/bin/", "/sbin/", "/etc/", "/private/", home + "/Library/"]
        if forbiddenExact.contains(standardized) || forbiddenPrefixes.contains(where: { standardized.hasPrefix($0) }) {
            throw WorkstationError.invalidRoot
        }
    }

    private func validateName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw WorkstationError.emptyName }
        return name
    }

    private func validateAccount(_ accountId: UUID, projectId: UUID, excluding workstationId: UUID?) throws {
        let platformRow: String?? = try db.db.queryFirst(
            "SELECT platform FROM accounts WHERE id = ?",
            [.string(accountId.uuidString)]
        ) { $0.string(at: 0) }
        guard let platform = platformRow ?? nil else { throw WorkstationError.accountNotFound }
        guard platform == Platform.trae.rawValue else { throw WorkstationError.accountNotTrae }

        var sql = "SELECT COUNT(*) FROM workstations WHERE projectId = ? AND accountId = ?"
        var values: [SQLiteValue] = [.string(projectId.uuidString), .string(accountId.uuidString)]
        if let workstationId {
            sql += " AND id <> ?"
            values.append(.string(workstationId.uuidString))
        }
        let count = try db.db.scalar(sql, values)
        if count > 0 { throw WorkstationError.duplicateAccount }
    }

    private func pathOrBranchExists(projectId: UUID, path: String, branch: String) throws -> Bool {
        try db.db.scalar(
            "SELECT COUNT(*) FROM workstations WHERE projectId = ? AND (worktreePath = ? OR branchName = ?)",
            [.string(projectId.uuidString), .string(path), .string(branch)]
        ) > 0
    }

    private func insert(_ workstation: Workstation) throws {
        try db.db.transaction { tx in
            try insert(workstation, in: tx)
        }
    }

    private func insert(_ workstation: Workstation, in tx: SQLiteTransaction) throws {
        let placeholders = Array(repeating: "?", count: Workstation.columns.count).joined(separator: ", ")
        try tx.execute(
            "INSERT INTO workstations (\(cols)) VALUES (\(placeholders))",
            workstation.values
        )
    }

    private func save(_ workstation: inout Workstation) throws {
        workstation.updatedAt = Date()
        try db.db.execute(
            """
            UPDATE workstations
            SET accountId = ?, displayName = ?, roleTag = ?, worktreePath = ?, branchName = ?,
                isEnabled = ?, lastActivatedAt = ?, updatedAt = ?
            WHERE id = ?
            """,
            [
                workstation.accountId.map { .string($0.uuidString) } ?? .null,
                .string(workstation.displayName),
                workstation.roleTag.sqliteValue,
                workstation.worktreePath.sqliteValue,
                workstation.branchName.sqliteValue,
                .int(workstation.isEnabled ? 1 : 0),
                workstation.lastActivatedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .double(workstation.updatedAt.timeIntervalSince1970),
                .string(workstation.id.uuidString)
            ]
        )
    }
}

public enum WorkstationError: LocalizedError {
    case notFound
    case emptyName
    case tooManyEnabled
    case duplicateName
    case duplicateAccount
    case accountNotFound
    case accountNotTrae
    case invalidRoot
    case cannotAllocatePath

    public var errorDescription: String? {
        switch self {
        case .notFound: return "工位不存在"
        case .emptyName: return "工位名称不能为空"
        case .tooManyEnabled: return "同一个项目最多启用 3 个工位"
        case .duplicateName: return "同一项目内的工位名称不能重复"
        case .duplicateAccount: return "同一项目内一个账号只能绑定一个工位"
        case .accountNotFound: return "绑定的账号不存在"
        case .accountNotTrae: return "工作台工位只支持 TRAE 账号"
        case .invalidRoot: return "worktree 根目录不能指向系统目录"
        case .cannotAllocatePath: return "无法为工位分配唯一的 worktree 路径"
        }
    }
}
