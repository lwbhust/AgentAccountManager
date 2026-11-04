import XCTest
import Core
import AgentAccountManager

/// AppState 层冒烟测试：注入临时数据库，验证账号/积分主流程贯通。
/// 不触碰真实数据库文件；完整手机号传 nil，不写真实钥匙串。
@MainActor
final class AppStateTests: XCTestCase {
    var database: DatabaseService!
    var state: AppState!

    override func setUpWithError() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appstate-\(UUID().uuidString).sqlite")
        database = try DatabaseService(databaseURL: tmp)
        state = try AppState(database: database)
    }

    override func tearDownWithError() throws {
        let url = database.databaseURL
        database.close()
        database = nil
        state = nil
        try? FileManager.default.removeItem(at: url)
        // addAccount 会把选中账号写入 UserDefaults，测试后清理避免污染真实环境
        UserDefaults.standard.removeObject(forKey: "lastSelectedAccountId")
        UserDefaults.standard.removeObject(forKey: "favoriteAccountIds")
    }

    func testAddAccountSmoke() throws {
        XCTAssertTrue(state.isDatabaseReady)
        XCTAssertEqual(state.accounts.count, 0)

        try state.addAccount(
            platform: .workbuddy,
            displayName: "冒烟账号",
            phoneMasked: "138****1234",
            fullPhone: nil,
            planType: "标准版",
            note: nil
        )

        XCTAssertEqual(state.accounts.count, 1)
        XCTAssertEqual(state.accounts.first?.displayName, "冒烟账号")
        XCTAssertEqual(state.selectedAccountId, state.accounts.first?.id, "新增后应自动选中")
        XCTAssertEqual(state.toast, "账号已创建")
    }

    func testQuickSwitchAccountsSortsFavoritesThenRecent() throws {
        try state.addAccount(
            platform: .trae,
            displayName: "较早使用",
            phoneMasked: "1",
            fullPhone: nil,
            planType: nil,
            note: nil
        )
        let older = try XCTUnwrap(state.accounts.first { $0.displayName == "较早使用" })

        try state.addAccount(
            platform: .trae,
            displayName: "最近使用",
            phoneMasked: "2",
            fullPhone: nil,
            planType: nil,
            note: nil
        )
        let recent = try XCTUnwrap(state.accounts.first { $0.displayName == "最近使用" })

        try state.addAccount(
            platform: .workbuddy,
            displayName: "收藏账号",
            phoneMasked: "3",
            fullPhone: nil,
            planType: nil,
            note: nil
        )
        let favorite = try XCTUnwrap(state.accounts.first { $0.displayName == "收藏账号" })

        let now = Date()
        _ = try state.accountService?.markUsed(id: older.id, at: now.addingTimeInterval(-3600))
        _ = try state.accountService?.markUsed(id: recent.id, at: now)
        state.toggleFavorite(favorite.id)
        try state.reload()

        XCTAssertEqual(
            state.quickSwitchAccounts.map(\.displayName),
            ["收藏账号", "最近使用", "较早使用"]
        )
    }

    func testRecordManualCreditsSmoke() throws {
        try state.addAccount(
            platform: .trae,
            displayName: "积分冒烟",
            phoneMasked: "139****0000",
            fullPhone: nil,
            planType: nil,
            note: nil
        )
        let account = try XCTUnwrap(state.accounts.first)

        try state.recordManualCredits(
            accountId: account.id,
            credits: 800,
            totalCredits: 1000,
            creditType: "会员积分",
            observedAt: Date()
        )

        let refreshed = try XCTUnwrap(state.accounts.first)
        XCTAssertEqual(refreshed.currentCredits, 800)
        XCTAssertEqual(refreshed.totalCredits, 1000)
        XCTAssertEqual(state.creditHistoryCount(for: account.id), 1)
        XCTAssertEqual(state.creditHistory(for: account.id).first?.credits, 800)
    }

    func testDuplicatePhoneDetection() throws {
        let phone = "13812341234"
        try state.addAccount(
            platform: .workbuddy,
            displayName: "已有",
            phoneMasked: Masking.maskPhone(phone),
            fullPhone: phone,
            planType: nil,
            note: nil
        )
        let existing = try XCTUnwrap(state.accounts.first)
        // 完整手机号写入了真实钥匙串，测试结束后清除
        defer { state.keychain.deletePhone(for: existing.id) }

        let matches = state.duplicatePhoneAccounts(fullPhone: phone)
        XCTAssertEqual(matches.map(\.id), [existing.id], "应命中相同手机号的账号")

        let excluded = state.duplicatePhoneAccounts(fullPhone: phone, excluding: existing.id)
        XCTAssertTrue(excluded.isEmpty, "编辑场景应排除自己")

        XCTAssertTrue(state.duplicatePhoneAccounts(fullPhone: "13700000000").isEmpty)
    }

    func testWorkBuddyConfirmationConflict() throws {
        try state.addAccount(
            platform: .workbuddy, displayName: "W1", phoneMasked: "1",
            fullPhone: nil, planType: nil, note: nil
        )
        let w1 = try XCTUnwrap(state.accounts.first { $0.displayName == "W1" })
        try state.addAccount(
            platform: .workbuddy, displayName: "W2", phoneMasked: "2",
            fullPhone: nil, planType: nil, note: nil
        )
        let w2 = try XCTUnwrap(state.accounts.first { $0.displayName == "W2" })
        try state.addAccount(
            platform: .trae, displayName: "T1", phoneMasked: "3",
            fullPhone: nil, planType: nil, note: nil
        )
        let trae = try XCTUnwrap(state.accounts.first { $0.displayName == "T1" })

        state.confirmLogin(w1)
        state.confirmLogin(trae)
        XCTAssertTrue(
            state.conflictingWorkBuddyAccountIds.isEmpty,
            "单个 WorkBuddy 确认 + TRAE 确认不应构成冲突（不同平台可同时登录）"
        )

        state.confirmLogin(w2)
        XCTAssertEqual(
            state.conflictingWorkBuddyAccountIds,
            [w1.id, w2.id],
            "两个 WorkBuddy 账号同时已确认属于矛盾状态"
        )

        state.unconfirmOtherWorkBuddyAccounts(except: w2.id)
        XCTAssertTrue(state.conflictingWorkBuddyAccountIds.isEmpty)
        XCTAssertEqual(state.account(id: w2.id)?.lastLoginStatus, .userConfirmed)
        XCTAssertEqual(state.account(id: w1.id)?.lastLoginStatus, .unknown)
        XCTAssertEqual(
            state.account(id: trae.id)?.lastLoginStatus,
            .userConfirmed,
            "清理 WorkBuddy 冲突不应影响 TRAE 账号"
        )
    }

    func testEstimatedBalanceDeductsTasksAfterBaseline() throws {
        try state.addAccount(
            platform: .trae, displayName: "扣减测试", phoneMasked: "1",
            fullPhone: nil, planType: nil, note: nil
        )
        let account = try XCTUnwrap(state.accounts.first)
        let baseline = Date(timeIntervalSince1970: 1_800_000_000)

        try state.recordManualCredits(
            accountId: account.id,
            credits: 100,
            totalCredits: nil,
            creditType: nil,
            observedAt: baseline
        )

        // 基准之前的任务不重复扣减
        XCTAssertEqual(try state.taskService?.upsert([
            TraeTaskEvent(
                accountId: account.id, messageId: "before",
                credits: 50, date: baseline.addingTimeInterval(-60)
            ),
            // 基准之后的任务计入
            TraeTaskEvent(
                accountId: account.id, messageId: "after1",
                credits: 4.06, date: baseline.addingTimeInterval(60)
            ),
            TraeTaskEvent(
                accountId: account.id, messageId: "after2",
                credits: 1.5, date: baseline.addingTimeInterval(120)
            ),
            // 未采集到消耗的任务只提示，不按 0 计入
            TraeTaskEvent(
                accountId: account.id, messageId: "pending",
                credits: nil, date: baseline.addingTimeInterval(180)
            )
        ]) ?? 0, 4)

        state.refreshCreditBalances()
        let estimate = try XCTUnwrap(state.creditBalance(for: account.id))
        XCTAssertEqual(estimate.baselineCredits, 100)
        XCTAssertEqual(estimate.consumedCredits, 5.56, accuracy: 0.0001)
        XCTAssertEqual(estimate.consumedTaskCount, 2)
        XCTAssertEqual(estimate.pendingTaskCount, 1)
        XCTAssertEqual(estimate.estimatedCredits, 94.44, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(state.displayedCredits(for: account)), 94.44, accuracy: 0.0001)

        // 一次性录入最新余额：基准前移，之前的任务消耗不再计入
        try state.recordManualCredits(
            accountId: account.id,
            credits: 90,
            totalCredits: nil,
            creditType: nil,
            observedAt: baseline.addingTimeInterval(300)
        )
        let reset = try XCTUnwrap(state.creditBalance(for: account.id))
        XCTAssertEqual(reset.baselineCredits, 90)
        XCTAssertEqual(reset.consumedCredits, 0, accuracy: 0.0001)
        XCTAssertEqual(reset.estimatedCredits, 90, accuracy: 0.0001)
        XCTAssertEqual(reset.pendingTaskCount, 0)
    }

    func testRecentProjectsIncludesRecordedVisit() throws {
        try state.addAccount(
            platform: .trae, displayName: "项目记录", phoneMasked: "1",
            fullPhone: nil, planType: nil, note: nil
        )
        let account = try XCTUnwrap(state.accounts.first)
        let ws = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("state-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        try state.projectVisitService?.record(accountId: account.id, workspace: ws)
        let projects = state.recentProjects(for: account)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.url.standardizedFileURL.path, ws.standardizedFileURL.path)
        XCTAssertEqual(projects.first?.visitCount, 1)

        // 项目目录已不存在时不再展示
        try FileManager.default.removeItem(at: ws)
        XCTAssertTrue(state.recentProjects(for: account).isEmpty)
    }
}
