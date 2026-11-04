import Foundation

/// 项目剧本：一个仓库 + 一条基线分支 + 一组工位。
///
/// 只保存项目元数据，不保存源码、对话或任何凭据。
public struct Project: Codable, Sendable, Identifiable {
    public static let tableName = "projects"

    public enum OrchestrationMode: String, Codable, CaseIterable, Sendable, Hashable {
        case freeLane
        case rolePlay

        public var displayName: String {
            switch self {
            case .freeLane: return "自由工位"
            case .rolePlay: return "角色剧本"
            }
        }

        public var explanation: String {
            switch self {
            case .freeLane: return "工位不固定绑定账号，开工前选择"
            case .rolePlay: return "工位绑定账号与角色，按剧本分工"
            }
        }
    }

    public var id: UUID
    public var displayName: String
    public var repoPath: String
    public var baselineBranch: String
    public var orchestrationMode: OrchestrationMode
    public var buildCommand: String?
    public var testCommand: String?
    public var setupHint: String?
    /// 工位 worktree 的根目录；nil 表示使用默认的 ~/Workbench。
    public var worktreeRoot: String?
    public var projectMemory: String?
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        repoPath: String,
        baselineBranch: String,
        orchestrationMode: OrchestrationMode = .freeLane,
        buildCommand: String? = nil,
        testCommand: String? = nil,
        setupHint: String? = nil,
        worktreeRoot: String? = nil,
        projectMemory: String? = nil,
        note: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.repoPath = repoPath
        self.baselineBranch = baselineBranch
        self.orchestrationMode = orchestrationMode
        self.buildCommand = buildCommand
        self.testCommand = testCommand
        self.setupHint = setupHint
        self.worktreeRoot = worktreeRoot
        self.projectMemory = projectMemory
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let columns = [
        "id", "displayName", "repoPath", "baselineBranch", "orchestrationMode",
        "buildCommand", "testCommand", "setupHint", "worktreeRoot",
        "projectMemory", "note", "createdAt", "updatedAt"
    ]

    public init(row: Row) {
        self.id = UUID(uuidString: row.string(at: 0) ?? "") ?? UUID()
        self.displayName = row.string(at: 1) ?? ""
        self.repoPath = row.string(at: 2) ?? ""
        self.baselineBranch = row.string(at: 3) ?? "main"
        self.orchestrationMode = OrchestrationMode(rawValue: row.string(at: 4) ?? "") ?? .freeLane
        self.buildCommand = row.string(at: 5)
        self.testCommand = row.string(at: 6)
        self.setupHint = row.string(at: 7)
        self.worktreeRoot = row.string(at: 8)
        self.projectMemory = row.string(at: 9)
        self.note = row.string(at: 10)
        self.createdAt = row.double(at: 11).map { Date(timeIntervalSince1970: $0) } ?? Date()
        self.updatedAt = row.double(at: 12).map { Date(timeIntervalSince1970: $0) } ?? Date()
    }

    public var values: [SQLiteValue] {
        [
            .string(id.uuidString),
            .string(displayName),
            .string(repoPath),
            .string(baselineBranch),
            .string(orchestrationMode.rawValue),
            buildCommand.sqliteValue,
            testCommand.sqliteValue,
            setupHint.sqliteValue,
            worktreeRoot.sqliteValue,
            projectMemory.sqliteValue,
            note.sqliteValue,
            .double(createdAt.timeIntervalSince1970),
            .double(updatedAt.timeIntervalSince1970)
        ]
    }
}

extension Project {
    public var repoURL: URL {
        URL(fileURLWithPath: repoPath)
    }

    /// 仓库目录名，用于列表与默认 worktree 路径。
    public var repoNamespace: String {
        let name = repoURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "repo" : name
    }

    public var modeBadge: String {
        orchestrationMode.displayName
    }
}
