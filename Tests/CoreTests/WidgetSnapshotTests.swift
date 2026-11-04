import XCTest
import Core

final class WidgetSnapshotTests: XCTestCase {
    func testSnapshotRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")

        let accountId = UUID()
        let snapshot = WidgetSnapshot(
            runningCount: 1,
            accounts: [
                WidgetAccountSnapshot(
                    id: accountId,
                    name: "账号 A",
                    platform: .trae,
                    isRunning: true,
                    isFavorite: true,
                    subtitle: "free · 运行中"
                )
            ],
            projects: [
                WidgetProjectSnapshot(
                    accountId: accountId,
                    accountName: "账号 A",
                    name: "我的项目",
                    path: "/Users/test/我的 项目",
                    lastVisitedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ]
        )

        try WidgetSnapshotStore.save(snapshot, to: url)
        let loaded = try XCTUnwrap(WidgetSnapshotStore.load(from: url))
        XCTAssertEqual(loaded, snapshot)
    }

    func testSnapshotContentComparisonIgnoresTimestamp() {
        let account = WidgetAccountSnapshot(
            id: UUID(),
            name: "账号",
            platform: .workbuddy,
            isRunning: false,
            isFavorite: false,
            subtitle: ""
        )
        let a = WidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 100),
            runningCount: 0,
            accounts: [account],
            projects: []
        )
        let b = WidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 200),
            runningCount: 0,
            accounts: [account],
            projects: []
        )

        XCTAssertTrue(a.hasSameContent(as: b))
    }

    func testAccountDeepLinkRoundTrip() throws {
        let id = UUID()
        let url = WidgetDeepLink.account(id).url
        let parsed = try XCTUnwrap(WidgetDeepLink.parse(url))
        XCTAssertEqual(parsed, .account(id))
    }

    func testProjectDeepLinkEncodesPath() throws {
        let accountId = UUID()
        let path = "/Users/example/Projects/AgentAccountManager"
        let url = WidgetDeepLink.project(accountId: accountId, path: path).url
        let parsed = try XCTUnwrap(WidgetDeepLink.parse(url))

        XCTAssertEqual(parsed, .project(accountId: accountId, path: path))
    }

    func testDeepLinkRejectsMalformedURL() {
        XCTAssertNil(WidgetDeepLink.parse(URL(string: "https://example.com/account")!))
        XCTAssertNil(WidgetDeepLink.parse(URL(string: "agentaccountmanager://account")!))
        XCTAssertNil(WidgetDeepLink.parse(URL(string: "agentaccountmanager://unknown")!))
    }

    // MARK: - 快照文件异常路径

    private func temporarySnapshotURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-snapshot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("snapshot.json")
    }

    func testLoadMissingFileReturnsNil() {
        let url = temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // 未保存过快照时小组件应展示空态，而不是崩溃或渲染占位数据。
        XCTAssertNil(WidgetSnapshotStore.load(from: url))
    }

    func testLoadCorruptedFileReturnsNil() throws {
        let url = temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("这不是 JSON".utf8).write(to: url)
        XCTAssertNil(WidgetSnapshotStore.load(from: url))
    }

    func testLoadRejectsNewerSchemaVersion() throws {
        // 未来主应用写出的更高版本快照：本扩展无法理解其结构，宁可展示空态。
        let url = temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let future = WidgetSnapshot(
            schemaVersion: WidgetSnapshot.currentSchemaVersion + 1,
            runningCount: 1,
            accounts: [],
            projects: []
        )
        try WidgetSnapshotStore.save(future, to: url)
        XCTAssertNil(WidgetSnapshotStore.load(from: url))
    }
}
