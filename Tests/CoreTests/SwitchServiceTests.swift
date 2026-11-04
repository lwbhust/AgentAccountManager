import XCTest
import Core
import os

// MARK: - Mock/Stub（任务书 Phase 1a-F：外部进程启动与身份核验为可测试边界）

/// WorkBuddy 启动行为桩。
private final class MockWorkBuddy: WorkBuddySwitching, @unchecked Sendable {
    private let lock = NSLock()
    private let installedFlag: Bool
    private let openResult: Bool
    private let openDelay: TimeInterval
    private var openCalls = 0

    init(installed: Bool = true, openResult: Bool = true, openDelay: TimeInterval = 0) {
        self.installedFlag = installed
        self.openResult = openResult
        self.openDelay = openDelay
    }

    var isInstalled: Bool { installedFlag }

    @discardableResult
    func openApp() -> Bool {
        if openDelay > 0 { Thread.sleep(forTimeInterval: openDelay) }
        lock.lock()
        openCalls += 1
        lock.unlock()
        return openResult
    }

    var openCallCount: Int { lock.withLock { openCalls } }
}

/// TRAE 启动与身份核验桩。
private final class MockTrae: TraeSwitching, @unchecked Sendable {
    private let lock = NSLock()
    var bundleResolvable = true
    var cliInstalled = true
    var workspace: URL?
    var launchError: Error?
    var hasSession = false
    var identity: String?
    var launchDelay: TimeInterval = 0
    private var launchCalls = 0
    private var verifyCalls = 0

    var isApplicationBundleResolvable: Bool { bundleResolvable }
    var isInstalled: Bool { cliInstalled }
    func lastWorkspace(for accountId: UUID) -> URL? { workspace }

    @discardableResult
    func launchIsolated(account: Account, workspace: URL?) throws -> Bool {
        if launchDelay > 0 { Thread.sleep(forTimeInterval: launchDelay) }
        lock.lock()
        launchCalls += 1
        lock.unlock()
        if let launchError { throw launchError }
        return true
    }

    func hasPersistedSession(accountId: UUID) -> Bool { hasSession }

    func verifyLoginIdentity() -> String? {
        lock.lock()
        verifyCalls += 1
        lock.unlock()
        return identity
    }

    var launchCallCount: Int { lock.withLock { launchCalls } }
    var verifyCallCount: Int { lock.withLock { verifyCalls } }
}

private enum StubError: Error, LocalizedError {
    case launchFailed

    var errorDescription: String? { "模拟的启动失败" }
}

// MARK: - 测试

/// SwitchService 切换事务测试矩阵（任务书 Phase 1a-F 十项）：
/// 账号不存在 / 应用路径无效 / 启动失败 / 启动成功但验证失败 / 身份无法核验 /
/// 数据库写入失败 / 连续触发切换 / 不同平台切换 / 中间步骤异常 / 成功记录正确。
final class SwitchServiceTests: XCTestCase {
    var database: DatabaseService!
    var accountService: AccountService!
    var switchLogService: SwitchLogService!
    var projectVisitService: ProjectVisitService!

    override func setUpWithError() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-switch-\(UUID().uuidString).sqlite")
        database = try DatabaseService(databaseURL: tmp)
        accountService = AccountService(database: database)
        switchLogService = SwitchLogService(database: database)
        projectVisitService = ProjectVisitService(database: database)
    }

    override func tearDownWithError() throws {
        let url = database.databaseURL
        database.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// 构造被测服务。`withDatabase = false` 时走逐项提交的兼容路径。
    private func makeService(
        workbuddy: WorkBuddySwitching = MockWorkBuddy(),
        trae: TraeSwitching = MockTrae(),
        withDatabase: Bool = true
    ) -> SwitchService {
        SwitchService(
            accountService: accountService,
            switchLogService: switchLogService,
            database: withDatabase ? database : nil,
            workbuddy: workbuddy,
            trae: trae,
            projectVisitService: projectVisitService
        )
    }

    // MARK: 1. 目标账号不存在

    func testSwitchFailsWhenTargetAccountMissing() throws {
        let account = try accountService.create(platform: .workbuddy, displayName: "幽灵", phoneMasked: "1")
        _ = try accountService.delete(id: account.id)

        let outcome = makeService().switchTo(account: account)

        XCTAssertEqual(outcome.result, .failed)
        XCTAssertEqual(outcome.phase, .failed)
        XCTAssertEqual(outcome.failedAtPhase, .preflight)
        XCTAssertFalse(outcome.launched)
        XCTAssertNil(try accountService.get(id: account.id))
        // 账号已删除：switch_logs 外键级联，失败日志无处归属，落库必然失败
        XCTAssertEqual(try switchLogService.count(for: account.id), 0)
    }

    /// UI 持有过期引用（平台字段已被改）时必须中止，不能按旧平台启动。
    func testSwitchAbortsWhenPlatformChanged() throws {
        let account = try accountService.create(platform: .workbuddy, displayName: "换平台", phoneMasked: "1")
        try database.db.execute(
            "UPDATE accounts SET platform = 'trae' WHERE id = ?",
            [.string(account.id.uuidString)]
        )

        let outcome = makeService().switchTo(account: account)

        XCTAssertEqual(outcome.result, .failed)
        XCTAssertEqual(outcome.failedAtPhase, .preflight)
        XCTAssertEqual(try switchLogService.count(for: account.id), 1)
    }

    // MARK: 2. 目标应用路径无效

    func testSwitchFailsWhenAppUnavailable() throws {
        let wbAccount = try accountService.create(platform: .workbuddy, displayName: "W", phoneMasked: "1")
        let traeAccount = try accountService.create(platform: .trae, displayName: "T", phoneMasked: "2")

        // WorkBuddy 未安装
        let wbOutcome = makeService(workbuddy: MockWorkBuddy(installed: false)).switchTo(account: wbAccount)
        XCTAssertEqual(wbOutcome.result, .failed)
        XCTAssertEqual(wbOutcome.failedAtPhase, .preflight)
        XCTAssertNotNil(wbOutcome.failureAdvice)

        // TRAE 应用包无法解析
        let noBundle = MockTrae()
        noBundle.bundleResolvable = false
        let bundleOutcome = makeService(trae: noBundle).switchTo(account: traeAccount)
        XCTAssertEqual(bundleOutcome.failedAtPhase, .preflight)
        XCTAssertTrue(bundleOutcome.detail.contains("未找到"))

        // TRAE CLI 不可用
        let noCLI = MockTrae()
        noCLI.cliInstalled = false
        let cliOutcome = makeService(trae: noCLI).switchTo(account: traeAccount)
        XCTAssertEqual(cliOutcome.failedAtPhase, .preflight)
        XCTAssertTrue(cliOutcome.detail.contains("命令行"))

        // 状态未被改动；每次尝试各留一条失败日志
        XCTAssertEqual(try accountService.get(id: wbAccount.id)?.lastLoginStatus, .unknown)
        XCTAssertEqual(try accountService.get(id: traeAccount.id)?.lastLoginStatus, .unknown)
        XCTAssertEqual(try switchLogService.count(for: traeAccount.id), 2, "TRAE 两次预检失败各留一条日志")
    }

    // MARK: 3. 启动失败

    func testSwitchFailsWhenLaunchFails() throws {
        let wbAccount = try accountService.create(platform: .workbuddy, displayName: "W", phoneMasked: "1")
        let traeAccount = try accountService.create(platform: .trae, displayName: "T", phoneMasked: "2")

        // WorkBuddy：系统拒绝打开
        let wbOutcome = makeService(workbuddy: MockWorkBuddy(openResult: false)).switchTo(account: wbAccount)
        XCTAssertEqual(wbOutcome.result, .failed)
        XCTAssertEqual(wbOutcome.failedAtPhase, .launching)
        XCTAssertFalse(wbOutcome.launched, "启动失败不得声称已启动")
        XCTAssertEqual(try accountService.get(id: wbAccount.id)?.lastLoginStatus, .unknown, "启动失败不得改写登录状态")

        // TRAE：启动抛错
        let traeMock = MockTrae()
        traeMock.launchError = StubError.launchFailed
        let traeOutcome = makeService(trae: traeMock).switchTo(account: traeAccount)
        XCTAssertEqual(traeOutcome.result, .failed)
        XCTAssertEqual(traeOutcome.failedAtPhase, .launching)
        XCTAssertFalse(traeOutcome.launched)
        XCTAssertEqual(try accountService.get(id: traeAccount.id)?.lastLoginStatus, .unknown)
        XCTAssertEqual(try switchLogService.count(for: traeAccount.id), 1, "启动失败仍应留下失败记录")
    }

    // MARK: 4. 启动成功但身份验证失败

    func testLaunchedButUnverifiedTraeStaysPending() throws {
        let account = try accountService.create(platform: .trae, displayName: "T", phoneMasked: "1")
        let trae = MockTrae() // 无持久化会话、无法读身份
        let service = makeService(trae: trae)

        let outcome = service.switchTo(account: account)

        XCTAssertEqual(outcome.result, .unconfirmed)
        XCTAssertTrue(outcome.launched)
        XCTAssertFalse(outcome.identityVerified, "未验证必须显式标注，不得伪造成功")
        XCTAssertEqual(outcome.phase, .completed)
        XCTAssertEqual(trae.verifyCallCount, 1, "启动后必须尝试身份核验")
        XCTAssertEqual(try accountService.get(id: account.id)?.lastLoginStatus, .pendingConfirmation)
        if let log = try switchLogService.history(for: account.id, limit: 1).first {
            XCTAssertEqual(log.result, .unconfirmed)
            XCTAssertEqual(log.fromStatus, LoginStatus.unknown.rawValue)
            XCTAssertEqual(log.toStatus, LoginStatus.pendingConfirmation.rawValue)
        }
    }

    // MARK: 5. 身份无法核验（WorkBuddy 显式标注；已确认状态保留；verified 降级）

    func testWorkBuddyCannotVerifyKeepsUserConfirmationAndDowngradesVerified() throws {
        let account = try accountService.create(platform: .workbuddy, displayName: "W", phoneMasked: "1")
        _ = try accountService.updateLoginStatus(id: account.id, status: .userConfirmed)
        let service = makeService()

        let outcome = service.switchTo(account: account)

        XCTAssertEqual(outcome.result, .unconfirmed)
        XCTAssertFalse(outcome.identityVerified, "WorkBuddy 无法自动核验，必须显式标注")
        XCTAssertFalse(outcome.manualSteps.isEmpty, "必须给出人工核对步骤")
        XCTAssertEqual(try accountService.get(id: account.id)?.lastLoginStatus, .userConfirmed, "已人工确认的状态在无法核验时应保留")

        // 曾经验证过，但本次未核验 → 降级为用户确认，不沿用旧验证
        _ = try accountService.updateLoginStatus(id: account.id, status: .verified)
        _ = service.switchTo(account: account)
        XCTAssertEqual(try accountService.get(id: account.id)?.lastLoginStatus, .userConfirmed)
    }

    // MARK: 6. 数据库写入失败（事务整体回滚）

    func testCommitFailureRollsBackAllStateChanges() throws {
        let account = try accountService.create(platform: .trae, displayName: "T", phoneMasked: "1")
        try database.db.execute("DROP TABLE project_visits")
        let trae = MockTrae()
        trae.workspace = URL(fileURLWithPath: "/tmp/rollback-demo") // 触发 ProjectVisit 写入

        let outcome = makeService(trae: trae).switchTo(account: account)

        XCTAssertEqual(outcome.result, .failed)
        XCTAssertEqual(outcome.phase, .failed)
        XCTAssertEqual(outcome.failedAtPhase, .committing)
        XCTAssertTrue(outcome.launched, "应用确实启动过，外部事实要保留在结果里")
        // 事务回滚：登录状态与最近使用时间不得改动（前两步虽已写入也必须撤销）
        let refreshed = try XCTUnwrap(try accountService.get(id: account.id))
        XCTAssertEqual(refreshed.lastLoginStatus, .unknown)
        XCTAssertNil(refreshed.lastUsedAt)
        // 失败仍有独立日志（事务外的失败记录）
        if let log = try switchLogService.history(for: account.id, limit: 1).first {
            XCTAssertEqual(log.result, .failed)
            XCTAssertNotNil(log.errorMessage, "失败原因必须保留")
        }
    }

    /// 切换日志表本身不可用时，同样如实失败，不得留半套状态。
    func testCommitFailureWhenSwitchLogUnavailable() throws {
        let account = try accountService.create(platform: .trae, displayName: "T2", phoneMasked: "3")
        try database.db.execute("DROP TABLE switch_logs")

        let outcome = makeService().switchTo(account: account)

        XCTAssertEqual(outcome.result, .failed)
        XCTAssertEqual(outcome.failedAtPhase, .committing)
        XCTAssertEqual(try accountService.get(id: account.id)?.lastLoginStatus, .unknown)
        XCTAssertNil(try accountService.get(id: account.id)?.lastUsedAt)
    }

    // MARK: 7. 连续触发切换（服务级互斥）

    func testConcurrentSwitchRejectedWhileTransactionInFlight() throws {
        let account = try accountService.create(platform: .trae, displayName: "并发", phoneMasked: "1")
        let trae = MockTrae()
        trae.launchDelay = 0.3
        let service = makeService(trae: trae)

        let group = DispatchGroup()
        let results = OSAllocatedUnfairLock<[SwitchService.SwitchOutcome]>(initialState: [])
        for _ in 0..<2 {
            group.enter()
            Thread.detachNewThread {
                let outcome = service.switchTo(account: account)
                results.withLock { $0.append(outcome) }
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(trae.launchCallCount, 1, "并发下只应有一个事务真正启动客户端")
        let outcomes = results.withLock { $0 }
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes.filter { $0.result != .failed }.count, 1)
        XCTAssertEqual(outcomes.filter { $0.result == .failed }.count, 1)
        XCTAssertEqual(outcomes.first { $0.result == .failed }?.failedAtPhase, .idle)
        XCTAssertFalse(outcomes.first { $0.result == .failed }?.launched ?? true)
        // 被拒绝的尝试什么都没发生，不写切换日志
        XCTAssertEqual(try switchLogService.count(for: account.id), 1)
    }

    /// 连续两次切换：事务结束后互斥必须释放，第二次完整执行。
    func testSequentialSwitchesBothRunAfterMutexRelease() throws {
        let account = try accountService.create(platform: .trae, displayName: "连续", phoneMasked: "1")
        let trae = MockTrae()
        trae.launchDelay = 0.05
        let service = makeService(trae: trae)

        _ = service.switchTo(account: account)
        XCTAssertFalse(service.isSwitching, "事务结束后互斥必须释放")
        let second = service.switchTo(account: account)

        XCTAssertEqual(trae.launchCallCount, 2)
        XCTAssertEqual(second.result, .unconfirmed)
        XCTAssertEqual(try switchLogService.count(for: account.id), 2)
    }

    // MARK: 8. 不同平台切换

    func testPlatformSpecificOutcomes() throws {
        let wbAccount = try accountService.create(platform: .workbuddy, displayName: "W", phoneMasked: "1")
        let traeAccount = try accountService.create(platform: .trae, displayName: "T", phoneMasked: "2")
        let trae = MockTrae()
        trae.identity = "user@example.com"
        trae.hasSession = true

        let wbOutcome = makeService().switchTo(account: wbAccount)
        XCTAssertEqual(wbOutcome.result, .unconfirmed)
        XCTAssertFalse(wbOutcome.manualSteps.isEmpty, "WorkBuddy 走人工核对路径")

        let traeOutcome = makeService(trae: trae).switchTo(account: traeAccount)
        XCTAssertEqual(traeOutcome.result, .success)
        XCTAssertTrue(traeOutcome.identityVerified)
        XCTAssertEqual(traeOutcome.claimedIdentity, "user@example.com")
        XCTAssertEqual(try accountService.get(id: traeAccount.id)?.lastLoginStatus, .verified)
    }

    // MARK: 9. 中间步骤异常（兼容路径保持旧的逐项容错语义）

    func testLegacyPathMidStepFailureKeepsTolerantBehavior() throws {
        let account = try accountService.create(platform: .workbuddy, displayName: "W", phoneMasked: "1")
        try database.db.execute("DROP TABLE switch_logs")

        // 未注入共享数据库：与历史行为一致，逐项写入、逐项容错
        let outcome = makeService(withDatabase: false).switchTo(account: account)

        XCTAssertEqual(outcome.result, .unconfirmed, "兼容路径下提交错误不推翻启动结果")
        XCTAssertEqual(try accountService.get(id: account.id)?.lastLoginStatus, .pendingConfirmation, "状态仍逐项写入")
        XCTAssertEqual(outcome.phase, .completed)
    }

    // MARK: 10. 成功记录正确生成

    func testSuccessfulSwitchGeneratesCompleteRecords() throws {
        let account = try accountService.create(platform: .trae, displayName: "完整", phoneMasked: "1")
        let workspace = URL(fileURLWithPath: "/tmp/demo-project-\(UUID().uuidString)")
        let trae = MockTrae()
        trae.identity = "dev@trae"
        trae.workspace = workspace
        trae.hasSession = true

        let outcome = makeService(trae: trae).switchTo(account: account)

        XCTAssertEqual(outcome.result, .success)
        XCTAssertEqual(outcome.phase, .completed)
        XCTAssertNil(outcome.failedAtPhase)

        let refreshed = try XCTUnwrap(try accountService.get(id: account.id))
        XCTAssertEqual(refreshed.lastLoginStatus, .verified)
        XCTAssertNotNil(refreshed.lastUsedAt, "启动过客户端必须记录最近使用时间")

        let visits = try projectVisitService.recent(accountId: account.id, since: Date().addingTimeInterval(-60))
        XCTAssertEqual(visits.count, 1, "TRAE 切换应记录项目打开")
        XCTAssertEqual(visits.first?.workspacePath, workspace.standardizedFileURL.path)

        if let log = try switchLogService.history(for: account.id, limit: 1).first {
            XCTAssertEqual(log.result, .success)
            XCTAssertEqual(log.fromStatus, LoginStatus.unknown.rawValue)
            XCTAssertEqual(log.toStatus, LoginStatus.verified.rawValue)
        } else {
            XCTFail("成功切换必须写入切换日志")
        }
    }
}
