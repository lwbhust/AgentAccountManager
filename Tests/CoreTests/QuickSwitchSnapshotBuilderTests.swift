import XCTest
@testable import Core

/// QuickSwitchSnapshotBuilder 边界矩阵：排序、条数上限、副标题、过期识别与空输入。
final class QuickSwitchSnapshotBuilderTests: XCTestCase {
    // MARK: - 构造辅助

    private func makeAccount(
        _ name: String,
        platform: Platform,
        lastUsedAt: Date? = nil,
        planType: String? = nil
    ) -> Account {
        Account(
            platform: platform,
            displayName: name,
            phoneMasked: "138****0000",
            planType: planType,
            lastUsedAt: lastUsedAt
        )
    }

    // MARK: - 排序

    func testOrderingFavoriteFirstThenRunningThenRecent() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let plainOld = makeAccount("普通旧", platform: .trae, lastUsedAt: base)
        let plainRecent = makeAccount("普通新", platform: .trae, lastUsedAt: base.addingTimeInterval(60))
        let running = makeAccount("运行中", platform: .trae, lastUsedAt: base.addingTimeInterval(-600))
        let favorite = makeAccount("收藏", platform: .trae, lastUsedAt: base.addingTimeInterval(-1200))

        let ordered = QuickSwitchSnapshotBuilder.orderedAccounts(
            [plainOld, plainRecent, running, favorite],
            favorites: [favorite.id],
            runningTraeAccountIds: [running.id]
        )

        XCTAssertEqual(ordered.map(\.displayName), ["收藏", "运行中", "普通新", "普通旧"])
    }

    func testOrderingStableWhenNoSignals() {
        // 无收藏、无运行、无最近使用：按平台（TRAE 在前）再按名称稳定排列。
        let wA = makeAccount("W-B", platform: .workbuddy)
        let tB = makeAccount("T-B", platform: .trae)
        let tA = makeAccount("T-A", platform: .trae)

        let ordered = QuickSwitchSnapshotBuilder.orderedAccounts(
            [wA, tB, tA],
            favorites: [],
            runningTraeAccountIds: []
        )

        XCTAssertEqual(ordered.map(\.displayName), ["T-A", "T-B", "W-B"])
    }

    func testOrderingWorkBuddyRunningDoesNotLiftAllAccounts() {
        // WorkBuddy 运行状态是平台级，排序规则不感知它：
        // 运行中的 TRAE 浮到最近使用的 W 之前；W 账号之间仍按最近使用排列。
        let wRecent = makeAccount("W-最近", platform: .workbuddy, lastUsedAt: Date(timeIntervalSince1970: 1_000))
        let tRunning = makeAccount("T-运行", platform: .trae, lastUsedAt: Date(timeIntervalSince1970: 500))
        let wIdle = makeAccount("W-闲置", platform: .workbuddy, lastUsedAt: Date(timeIntervalSince1970: 100))

        let ordered = QuickSwitchSnapshotBuilder.orderedAccounts(
            [wIdle, tRunning, wRecent],
            favorites: [],
            runningTraeAccountIds: [tRunning.id]
        )

        XCTAssertEqual(ordered.map(\.displayName), ["T-运行", "W-最近", "W-闲置"])
    }

    func testOrderingTreatsNilLastUsedAtAsOldest() {
        let neverUsed = makeAccount("从未使用", platform: .trae)
        let used = makeAccount("用过", platform: .trae, lastUsedAt: Date(timeIntervalSince1970: 10))

        let ordered = QuickSwitchSnapshotBuilder.orderedAccounts(
            [neverUsed, used],
            favorites: [],
            runningTraeAccountIds: []
        )

        XCTAssertEqual(ordered.map(\.displayName), ["用过", "从未使用"])
    }

    // MARK: - 快照组装

    func testBuildCapsAccountsAndProjects() {
        let accounts = (1...12).map { makeAccount("账号\($0)", platform: .trae) }
        let projects = (1...10).map { index in
            WidgetProjectSnapshot(
                accountId: accounts[0].id,
                accountName: "账号1",
                name: "项目\(index)",
                path: "/tmp/项目\(index)",
                lastVisitedAt: Date(timeIntervalSince1970: Double(index))
            )
        }

        let snapshot = QuickSwitchSnapshotBuilder.build(
            accounts: accounts,
            favorites: [],
            runningTraeAccountIds: [],
            isWorkBuddyRunning: false,
            recentProjects: projects
        )

        XCTAssertEqual(snapshot.accounts.count, 8)
        XCTAssertEqual(snapshot.projects.count, 6)
        // 上限截取发生在排序之后：前 8 条应是排序后的头部（同信号下按名称）。
        XCTAssertEqual(snapshot.accounts.first?.name, "账号1")
    }

    func testBuildRunningCountCountsTraePerAccountAndWorkBuddyPlatformWide() {
        let t1 = makeAccount("T1", platform: .trae)
        let t2 = makeAccount("T2", platform: .trae)
        let w1 = makeAccount("W1", platform: .workbuddy)
        let w2 = makeAccount("W2", platform: .workbuddy)

        let snapshot = QuickSwitchSnapshotBuilder.build(
            accounts: [t1, t2, w1, w2],
            favorites: [],
            runningTraeAccountIds: [t1.id],
            isWorkBuddyRunning: true,
            recentProjects: []
        )

        // TRAE 只计运行中的账号；WorkBuddy 客户端运行时逐账号计入（与原实现一致）。
        XCTAssertEqual(snapshot.runningCount, 3)
        XCTAssertTrue(snapshot.accounts.first { $0.id == t1.id }!.isRunning)
        XCTAssertFalse(snapshot.accounts.first { $0.id == t2.id }!.isRunning)
        XCTAssertTrue(snapshot.accounts.first { $0.id == w1.id }!.isRunning)
        XCTAssertTrue(snapshot.accounts.first { $0.id == w2.id }!.isRunning)
    }

    func testBuildSetsSchemaVersionAndInjectedTimestamp() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = QuickSwitchSnapshotBuilder.build(
            accounts: [],
            favorites: [],
            runningTraeAccountIds: [],
            isWorkBuddyRunning: false,
            recentProjects: [],
            now: now
        )

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.updatedAt, now)
    }

    func testBuildMarksFavoriteAccounts() {
        let favorite = makeAccount("收藏", platform: .trae)
        let plain = makeAccount("普通", platform: .trae)

        let snapshot = QuickSwitchSnapshotBuilder.build(
            accounts: [plain, favorite],
            favorites: [favorite.id],
            runningTraeAccountIds: [],
            isWorkBuddyRunning: false,
            recentProjects: []
        )

        XCTAssertTrue(snapshot.accounts.first { $0.id == favorite.id }!.isFavorite)
        XCTAssertFalse(snapshot.accounts.first { $0.id == plain.id }!.isFavorite)
    }

    // MARK: - 副标题

    func testSubtitleMatrix() {
        let t = makeAccount("T", platform: .trae)
        let w = makeAccount("W", platform: .workbuddy)
        let planWhitespace = makeAccount("TW", platform: .trae, planType: "   ")

        // 套餐在前，运行状态在后
        XCTAssertEqual(QuickSwitchSnapshotBuilder.subtitle(for: makeAccount("P", platform: .trae, planType: "Pro"), isRunning: true), "Pro · 运行中")
        XCTAssertEqual(QuickSwitchSnapshotBuilder.subtitle(for: makeAccount("P", platform: .workbuddy, planType: "Max"), isRunning: true), "Max · 客户端已打开")
        // 无套餐
        XCTAssertEqual(QuickSwitchSnapshotBuilder.subtitle(for: t, isRunning: true), "运行中")
        XCTAssertEqual(QuickSwitchSnapshotBuilder.subtitle(for: w, isRunning: true), "客户端已打开")
        // 未运行
        XCTAssertEqual(QuickSwitchSnapshotBuilder.subtitle(for: t, isRunning: false), "未运行")
        XCTAssertEqual(QuickSwitchSnapshotBuilder.subtitle(for: w, isRunning: false), "客户端未打开")
        // 套餐为空白视为无套餐，落入「未运行」
        XCTAssertEqual(QuickSwitchSnapshotBuilder.subtitle(for: planWhitespace, isRunning: false), "未运行")
        // 副标题不含手机号或凭据
        XCTAssertFalse(QuickSwitchSnapshotBuilder.subtitle(for: t, isRunning: true).contains("138"))
    }

    // MARK: - 过期识别

    func testIsStaleBoundaries() {
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = WidgetSnapshot(
            updatedAt: updatedAt,
            runningCount: 0,
            accounts: [],
            projects: []
        )
        let maxAge: TimeInterval = 24 * 3600

        // 恰好等于 maxAge 未过期；超过才过期
        XCTAssertFalse(snapshot.isStale(now: updatedAt.addingTimeInterval(maxAge), maxAge: maxAge))
        XCTAssertTrue(snapshot.isStale(now: updatedAt.addingTimeInterval(maxAge + 1), maxAge: maxAge))
        // 默认 24 小时
        XCTAssertFalse(snapshot.isStale(now: updatedAt.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(snapshot.isStale(now: updatedAt.addingTimeInterval(25 * 3600)))
    }

    // MARK: - 空输入

    func testBuildWithEmptyInputsYieldsEmptySnapshot() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = QuickSwitchSnapshotBuilder.build(
            accounts: [],
            favorites: [],
            runningTraeAccountIds: [],
            isWorkBuddyRunning: false,
            recentProjects: [],
            now: now
        )

        XCTAssertEqual(snapshot.accounts, [])
        XCTAssertEqual(snapshot.projects, [])
        XCTAssertEqual(snapshot.runningCount, 0)
    }
}
