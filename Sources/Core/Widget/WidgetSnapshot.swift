import Foundation

/// WidgetKit 小组件读取的数据快照。
///
/// 小组件运行在独立、受沙盒限制的扩展进程里，不能直接访问 AppState 或 SQLite。
/// 主应用把渲染所需的只读信息写入一个 JSON 文件，扩展通过受限的主目录读权限读取。
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var updatedAt: Date
    public var runningCount: Int
    public var accounts: [WidgetAccountSnapshot]
    public var projects: [WidgetProjectSnapshot]

    public init(
        schemaVersion: Int = WidgetSnapshot.currentSchemaVersion,
        updatedAt: Date = Date(),
        runningCount: Int,
        accounts: [WidgetAccountSnapshot],
        projects: [WidgetProjectSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.runningCount = runningCount
        self.accounts = accounts
        self.projects = projects
    }

    /// 只比较影响渲染的内容，忽略每次写入都会变化的时间戳。
    public func hasSameContent(as other: WidgetSnapshot) -> Bool {
        runningCount == other.runningCount
            && accounts == other.accounts
            && projects == other.projects
    }
}

public struct WidgetAccountSnapshot: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let platform: Platform
    public let isRunning: Bool
    public let isFavorite: Bool
    /// 套餐、运行状态等一行副标题；不含手机号或任何凭据。
    public let subtitle: String

    public init(
        id: UUID,
        name: String,
        platform: Platform,
        isRunning: Bool,
        isFavorite: Bool,
        subtitle: String
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.isRunning = isRunning
        self.isFavorite = isFavorite
        self.subtitle = subtitle
    }
}

public struct WidgetProjectSnapshot: Codable, Sendable, Identifiable, Equatable {
    public let accountId: UUID
    public let accountName: String
    /// 项目目录名（不含完整路径，避免在小组件里暴露太长的路径）。
    public let name: String
    /// 完整路径只用于深链和打开项目，不在界面展示。
    public let path: String
    public let lastVisitedAt: Date

    public var id: String { accountId.uuidString + "|" + path }

    public init(
        accountId: UUID,
        accountName: String,
        name: String,
        path: String,
        lastVisitedAt: Date
    ) {
        self.accountId = accountId
        self.accountName = accountName
        self.name = name
        self.path = path
        self.lastVisitedAt = lastVisitedAt
    }
}

/// 小组件点击后交给主应用处理的深链。
public enum WidgetDeepLink: Sendable, Equatable {
    public static let scheme = "agentaccountmanager"

    case account(UUID)
    case project(accountId: UUID, path: String)

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .account(let id):
            components.host = "account"
            components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        case .project(let accountId, let path):
            components.host = "project"
            components.queryItems = [
                URLQueryItem(name: "account", value: accountId.uuidString),
                URLQueryItem(name: "path", value: path)
            ]
        }
        return components.url!
    }

    public static func parse(_ url: URL) -> WidgetDeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value {
                query[item.name] = value
            }
        }
        switch url.host?.lowercased() {
        case "account":
            guard let raw = query["id"], let id = UUID(uuidString: raw) else { return nil }
            return .account(id)
        case "project":
            guard let rawAccount = query["account"],
                  let accountId = UUID(uuidString: rawAccount),
                  let path = query["path"],
                  !path.isEmpty else { return nil }
            return .project(accountId: accountId, path: path)
        default:
            return nil
        }
    }
}

/// 主应用与小组件扩展共享的 JSON 快照文件。
///
/// 扩展启用 App Sandbox，并通过 `com.apple.security.temporary-exception.files.home-relative-path.read-only`
/// 只读访问主应用目录；因此这里始终使用真实用户主目录，而不是沙盒容器目录。
public enum WidgetSnapshotStore {
    public static let fileName = "widget-snapshot.json"

    public static var directoryURL: URL {
        realHomeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AgentAccountManager", isDirectory: true)
    }

    public static var fileURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    public static func save(_ snapshot: WidgetSnapshot, to url: URL? = nil) throws {
        let target = url ?? fileURL
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)
        try data.write(to: target, options: .atomic)
    }

    public static func load(from url: URL? = nil) -> WidgetSnapshot? {
        let target = url ?? fileURL
        guard let data = try? Data(contentsOf: target) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        // 更高版本的快照可能包含本扩展无法理解的结构，宁可展示空态也不渲染残缺数据。
        guard snapshot.schemaVersion <= WidgetSnapshot.currentSchemaVersion else { return nil }
        return snapshot
    }

    private static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()) {
            return URL(fileURLWithPath: String(cString: entry.pointee.pw_dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
