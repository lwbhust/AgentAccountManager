import Foundation

/// 项目剧本 CRUD。
public final class ProjectService: Sendable {
    private let db: DatabaseService
    private let logger: AppLogger

    public init(database: DatabaseService, logger: AppLogger = AppLogger(category: "project")) {
        self.db = database
        self.logger = logger
    }

    private var cols: String { Project.columns.joined(separator: ", ") }

    // MARK: - 查询

    public func listAll() throws -> [Project] {
        try db.db.query(
            "SELECT \(cols) FROM projects ORDER BY updatedAt DESC, createdAt DESC"
        ) { Project(row: $0) }
    }

    public func get(id: UUID) throws -> Project? {
        try db.db.queryFirst(
            "SELECT \(cols) FROM projects WHERE id = ?",
            [.string(id.uuidString)]
        ) { Project(row: $0) }
    }

    public func count() throws -> Int {
        try db.db.scalar("SELECT COUNT(*) FROM projects")
    }

    // MARK: - 新增

    @discardableResult
    public func create(
        displayName: String,
        repoPath: String,
        baselineBranch: String,
        orchestrationMode: Project.OrchestrationMode,
        buildCommand: String? = nil,
        testCommand: String? = nil,
        setupHint: String? = nil,
        worktreeRoot: String? = nil,
        projectMemory: String? = nil,
        note: String? = nil
    ) throws -> Project {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectError.emptyName }
        let normalizedRepo = Self.normalizePath(repoPath)
        guard !normalizedRepo.isEmpty else { throw ProjectError.emptyRepoPath }
        let branch = baselineBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw ProjectError.emptyBaselineBranch }

        let project = Project(
            displayName: name,
            repoPath: normalizedRepo,
            baselineBranch: branch,
            orchestrationMode: orchestrationMode,
            buildCommand: Self.clean(buildCommand),
            testCommand: Self.clean(testCommand),
            setupHint: Self.clean(setupHint),
            worktreeRoot: Self.cleanPath(worktreeRoot),
            projectMemory: Self.clean(projectMemory),
            note: Self.clean(note)
        )
        let placeholders = Array(repeating: "?", count: Project.columns.count).joined(separator: ", ")
        try db.db.execute(
            "INSERT INTO projects (\(cols)) VALUES (\(placeholders))",
            project.values
        )
        logger.info("项目已创建: id=\(project.id.uuidString.prefix(8))")
        return project
    }

    // MARK: - 更新

    @discardableResult
    public func update(
        id: UUID,
        displayName: String,
        repoPath: String,
        baselineBranch: String,
        orchestrationMode: Project.OrchestrationMode,
        buildCommand: String?,
        testCommand: String?,
        setupHint: String?,
        worktreeRoot: String?,
        projectMemory: String?,
        note: String?
    ) throws -> Project? {
        guard var project = try get(id: id) else { return nil }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectError.emptyName }
        let normalizedRepo = Self.normalizePath(repoPath)
        guard !normalizedRepo.isEmpty else { throw ProjectError.emptyRepoPath }
        let branch = baselineBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw ProjectError.emptyBaselineBranch }

        project.displayName = name
        let newRoot = Self.cleanPath(worktreeRoot) ?? WorkstationService.defaultWorktreeRoot.path
        let oldRoot = project.worktreeRoot ?? WorkstationService.defaultWorktreeRoot.path
        let workstationCount = try db.db.scalar(
            "SELECT COUNT(*) FROM workstations WHERE projectId = ?",
            [.string(id.uuidString)]
        )
        if workstationCount > 0 && (normalizedRepo != project.repoPath || newRoot != oldRoot) {
            throw ProjectError.immutableWorktreeConfig
        }

        project.repoPath = normalizedRepo
        project.baselineBranch = branch
        project.orchestrationMode = orchestrationMode
        project.buildCommand = Self.clean(buildCommand)
        project.testCommand = Self.clean(testCommand)
        project.setupHint = Self.clean(setupHint)
        project.worktreeRoot = Self.cleanPath(worktreeRoot)
        project.projectMemory = Self.clean(projectMemory)
        project.note = Self.clean(note)
        project.updatedAt = Date()
        try save(&project)
        return project
    }

    public func save(_ project: inout Project) throws {
        project.updatedAt = Date()
        let setCols = Project.columns.filter { $0 != "id" }
        let setClause = setCols.map { "\($0) = ?" }.joined(separator: ", ")
        var values = project.values
        values.removeFirst()
        values.append(.string(project.id.uuidString))
        try db.db.execute("UPDATE projects SET \(setClause) WHERE id = ?", values)
    }

    // MARK: - 删除

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        let changes = try db.db.execute(
            "DELETE FROM projects WHERE id = ?",
            [.string(id.uuidString)]
        )
        if changes > 0 {
            logger.info("项目已删除: id=\(id.uuidString.prefix(8))")
        }
        return changes > 0
    }

    // MARK: - 工具

    public static func normalizePath(_ raw: String) -> String {
        let expanded = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .expandingTildeInPath
        guard !expanded.isEmpty else { return "" }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    public static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func cleanPath(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return normalizePath(value)
    }
}

public enum ProjectError: LocalizedError {
    case emptyName
    case emptyRepoPath
    case emptyBaselineBranch
    case immutableWorktreeConfig

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "项目名称不能为空"
        case .emptyRepoPath: return "仓库路径不能为空"
        case .emptyBaselineBranch: return "基线分支不能为空"
        case .immutableWorktreeConfig:
            return "项目已有工位，不能修改仓库路径或 worktree 根目录；请新建项目"
        }
    }
}
