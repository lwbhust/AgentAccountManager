import XCTest
import Core

final class ProjectVisitTests: XCTestCase {
    var database: DatabaseService!
    var accounts: AccountService!
    var visits: ProjectVisitService!
    private var tempDirs: [URL] = []

    override func setUpWithError() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("visits-\(UUID().uuidString).sqlite")
        database = try DatabaseService(databaseURL: tmp)
        accounts = AccountService(database: database)
        visits = ProjectVisitService(database: database)
        tempDirs = []
    }

    override func tearDownWithError() throws {
        let url = database.databaseURL
        database.close()
        try? FileManager.default.removeItem(at: url)
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeWorkspace(_ name: String = "project") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pv-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// v6 迁移建表。
    func testProjectVisitsTableExists() throws {
        let count = try database.db.scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='project_visits'"
        )
        XCTAssertEqual(count, 1)
        XCTAssertEqual(
            try database.db.scalar("PRAGMA user_version"),
            DatabaseService.supportedSchemaVersion
        )
    }

    /// 同一项目重复打开：次数累加、时间取较晚值。
    func testRecordAccumulatesCountAndKeepsLatestTime() throws {
        let account = try accounts.create(platform: .trae, displayName: "记录", phoneMasked: "1")
        let ws = try makeWorkspace()
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(3600)

        try visits.record(accountId: account.id, workspace: ws, at: first)
        try visits.record(accountId: account.id, workspace: ws, at: second)

        let rows = try visits.recent(
            accountId: account.id,
            since: first.addingTimeInterval(-1)
        )
        XCTAssertEqual(rows.count, 1, "同一路径只保留一行")
        XCTAssertEqual(rows[0].visitCount, 2)
        XCTAssertEqual(
            rows[0].lastVisitedAt.timeIntervalSince1970,
            second.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(rows[0].workspacePath, ws.standardizedFileURL.path)
    }

    /// 只返回时间窗口内的项目，按最近打开倒序。
    func testRecentFiltersByIntervalAndSorts() throws {
        let account = try accounts.create(platform: .trae, displayName: "窗口", phoneMasked: "1")
        let old = try makeWorkspace("old")
        let newer = try makeWorkspace("newer")
        let middle = try makeWorkspace("middle")
        let now = Date()

        try visits.record(accountId: account.id, workspace: old, at: now.addingTimeInterval(-4 * 24 * 3600))
        try visits.record(accountId: account.id, workspace: middle, at: now.addingTimeInterval(-2 * 3600))
        try visits.record(accountId: account.id, workspace: newer, at: now.addingTimeInterval(-3600))

        let rows = try visits.recent(
            accountId: account.id,
            since: now.addingTimeInterval(-3 * 24 * 3600)
        )
        XCTAssertEqual(
            rows.map(\.workspacePath),
            [newer.standardizedFileURL.path, middle.standardizedFileURL.path],
            "4 天前的记录应被排除，其余按时间倒序"
        )
    }

    /// 删除账号级联删除项目记录。
    func testDeleteAccountCascadesProjectVisits() throws {
        let account = try accounts.create(platform: .trae, displayName: "级联", phoneMasked: "1")
        let ws = try makeWorkspace()
        try visits.record(accountId: account.id, workspace: ws)

        XCTAssertEqual(try visits.count(for: account.id), 1)
        XCTAssertTrue(try accounts.delete(id: account.id))
        XCTAssertEqual(try visits.countAll(), 0)
    }

    /// 过期记录可清理。
    func testPruneRemovesOldRecords() throws {
        let account = try accounts.create(platform: .trae, displayName: "清理", phoneMasked: "1")
        let old = try makeWorkspace("old")
        let fresh = try makeWorkspace("fresh")
        let now = Date()

        try visits.record(accountId: account.id, workspace: old, at: now.addingTimeInterval(-100 * 24 * 3600))
        try visits.record(accountId: account.id, workspace: fresh, at: now)

        let removed = try visits.prune(olderThan: now.addingTimeInterval(-90 * 24 * 3600))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try visits.count(for: account.id), 1)
    }
}
