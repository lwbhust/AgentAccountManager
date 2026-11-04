import XCTest
import Core
import AgentAccountManager

@MainActor
final class WorkbenchAppStateTests: XCTestCase {
    var tempRoot: URL!
    var database: DatabaseService!
    var state: AppState!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkbenchAppState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let dbURL = tempRoot.appendingPathComponent("test.sqlite")
        database = try DatabaseService(databaseURL: dbURL)
        state = try AppState(database: database)
    }

    override func tearDownWithError() throws {
        database?.close()
        database = nil
        state = nil
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        UserDefaults.standard.removeObject(forKey: "lastSelectedAccountId")
    }

    func testWorkbenchServicesAvailable() {
        XCTAssertNotNil(state.projectService)
        XCTAssertNotNil(state.workstationService)
        XCTAssertNotNil(state.workbenchService)
    }

    func testAccountRevisionAndSelectAccount() throws {
        try state.addAccount(
            platform: .trae,
            displayName: "TRAE A",
            phoneMasked: "1",
            fullPhone: nil,
            planType: nil,
            note: nil
        )
        let account = try XCTUnwrap(state.accounts.first)
        let revision = state.accountRevision
        XCTAssertGreaterThan(revision, 0)

        state.selectedPlatform = .workbuddy
        state.accountFilter = .running
        state.searchText = "不存在的关键字"
        state.isSearchPresented = true

        state.selectAccount(id: account.id)

        XCTAssertNil(state.selectedPlatform)
        XCTAssertEqual(state.accountFilter, .all)
        XCTAssertEqual(state.searchText, "")
        XCTAssertFalse(state.isSearchPresented)
        XCTAssertEqual(state.selectedAccountId, account.id)

        try state.updateAccount(
            id: account.id,
            displayName: "TRAE A 更新",
            note: nil,
            planType: nil,
            fullPhone: nil
        )
        XCTAssertGreaterThan(state.accountRevision, revision)
    }

    func testDeletionImpactIncludesWorkstations() throws {
        try state.addAccount(
            platform: .trae,
            displayName: "TRAE A",
            phoneMasked: "1",
            fullPhone: nil,
            planType: nil,
            note: nil
        )
        let account = try XCTUnwrap(state.accounts.first)
        let projectService = try XCTUnwrap(state.projectService)
        let workstationService = try XCTUnwrap(state.workstationService)

        let project = try projectService.create(
            displayName: "影响测试项目",
            repoPath: tempRoot.appendingPathComponent("repo").path,
            baselineBranch: "main",
            orchestrationMode: .freeLane,
            worktreeRoot: tempRoot.appendingPathComponent("worktrees").path
        )
        let lanes = try workstationService.createDefaults(for: project)
        let lane = try XCTUnwrap(lanes.first)
        try workstationService.assignAccount(workstationId: lane.id, accountId: account.id)

        let impact = state.deletionImpact(for: account)
        XCTAssertEqual(impact.workstations, 1)
        XCTAssertTrue(impact.workstationNames.first?.contains("影响测试项目") == true)
        XCTAssertFalse(impact.isRunning)

        try state.deleteAccount(id: account.id)
        let refreshed = try workstationService.get(id: lane.id)
        XCTAssertNotNil(refreshed)
        XCTAssertNil(refreshed?.accountId)
    }

    func testManualCreditAnnouncementCanBeSuppressed() throws {
        try state.addAccount(
            platform: .trae,
            displayName: "TRAE A",
            phoneMasked: "1",
            fullPhone: nil,
            planType: nil,
            note: nil
        )
        let account = try XCTUnwrap(state.accounts.first)
        state.toast = nil

        try state.recordManualCredits(
            accountId: account.id,
            credits: 100,
            totalCredits: nil,
            creditType: nil,
            observedAt: Date(),
            announce: false
        )
        XCTAssertNil(state.toast)
        XCTAssertEqual(try XCTUnwrap(state.accounts.first).currentCredits, 100)

        try state.recordManualCredits(
            accountId: account.id,
            credits: 120,
            totalCredits: nil,
            creditType: nil,
            observedAt: Date(),
            announce: true
        )
        XCTAssertNotNil(state.toast)
    }
}
