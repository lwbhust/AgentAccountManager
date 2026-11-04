import XCTest
import Core
@testable import AgentAccountManager

final class CreditPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let staleInterval: TimeInterval = 12 * 3600

    private func makeAccount(
        credits: Int? = nil,
        observedAt: Date? = nil,
        status: DataStatus = .manual
    ) -> Account {
        var account = Account(platform: .trae, displayName: "测试账号", phoneMasked: "")
        account.currentCredits = credits
        account.lastCreditQueryAt = observedAt
        account.dataStatus = status
        return account
    }

    private func estimate(
        baseline: Int,
        baselineAt: Date,
        consumed: Double,
        consumedCount: Int = 1,
        pending: Int = 0
    ) -> CreditBalanceEstimate {
        CreditBalanceEstimate(
            baselineCredits: baseline,
            baselineAt: baselineAt,
            consumedCredits: consumed,
            consumedTaskCount: consumedCount,
            pendingTaskCount: pending
        )
    }

    func testNoRecordShowsUnrecorded() {
        let presentation = CreditPresentation(
            account: makeAccount(),
            estimate: nil,
            staleInterval: staleInterval,
            now: now
        )
        XCTAssertNil(presentation.valueText)
        XCTAssertEqual(presentation.label, "未录入")
        XCTAssertTrue(presentation.needsCalibration)
        XCTAssertFalse(presentation.isWarning)
    }

    func testFreshEstimateShowsConfidenceLabel() {
        let account = makeAccount(credits: 1000, observedAt: now)
        let estimate = estimate(
            baseline: 1000,
            baselineAt: now.addingTimeInterval(-3600),
            consumed: 10
        )
        let presentation = CreditPresentation(
            account: account,
            estimate: estimate,
            staleInterval: staleInterval,
            now: now
        )
        XCTAssertTrue(presentation.valueText?.contains("990") == true)
        XCTAssertTrue(presentation.label.contains("估算"))
        XCTAssertFalse(presentation.needsCalibration)
        XCTAssertFalse(presentation.isWarning)
    }

    func testStaleEstimateNeedsCalibration() {
        let account = makeAccount(credits: 1000, observedAt: now.addingTimeInterval(-13 * 3600))
        let estimate = estimate(
            baseline: 1000,
            baselineAt: now.addingTimeInterval(-13 * 3600),
            consumed: 10
        )
        let presentation = CreditPresentation(
            account: account,
            estimate: estimate,
            staleInterval: staleInterval,
            now: now
        )
        // 数据较旧是常态信息：仍需校准，但不使用警示色（audit P0 语义修正）。
        XCTAssertTrue(presentation.detail?.contains("较旧") == true)
        XCTAssertTrue(presentation.needsCalibration)
        XCTAssertFalse(presentation.isWarning)
    }

    func testPendingTasksShowSampleInsufficient() {
        let account = makeAccount(credits: 1000, observedAt: now)
        let estimate = estimate(
            baseline: 1000,
            baselineAt: now.addingTimeInterval(-3600),
            consumed: 10,
            pending: 2
        )
        let presentation = CreditPresentation(
            account: account,
            estimate: estimate,
            staleInterval: staleInterval,
            now: now
        )
        XCTAssertTrue(presentation.label.contains("估算"))
        XCTAssertTrue(presentation.label.contains("2"))
        XCTAssertTrue(presentation.detail?.contains("样本不足") == true)
        XCTAssertTrue(presentation.needsCalibration)
        XCTAssertFalse(presentation.isWarning)
    }

    func testNegativeEstimateNeedsCalibration() {
        let account = makeAccount(credits: 10, observedAt: now)
        let estimate = estimate(
            baseline: 10,
            baselineAt: now.addingTimeInterval(-3600),
            consumed: 20
        )
        let presentation = CreditPresentation(
            account: account,
            estimate: estimate,
            staleInterval: staleInterval,
            now: now
        )
        XCTAssertEqual(presentation.label, "估算为负 · 需校准")
        XCTAssertTrue(presentation.valueText?.contains("-10") == true)
        XCTAssertTrue(presentation.needsCalibration)
        XCTAssertTrue(presentation.isWarning)
    }

    func testQueryFailureKeepsOldRecord() {
        let account = makeAccount(
            credits: 500,
            observedAt: now,
            status: .queryFailed
        )
        let presentation = CreditPresentation(
            account: account,
            estimate: nil,
            staleInterval: staleInterval,
            now: now
        )
        XCTAssertTrue(presentation.label.contains("上次查询失败"))
        XCTAssertTrue(presentation.valueText?.contains("500") == true)
        XCTAssertEqual(presentation.detail, "不代表当前余额")
        XCTAssertTrue(presentation.needsCalibration)
    }

    func testRecordOnlyIsNotTreatedAsLive() {
        let account = makeAccount(credits: 500, observedAt: now)
        let presentation = CreditPresentation(
            account: account,
            estimate: nil,
            staleInterval: staleInterval,
            now: now
        )
        XCTAssertTrue(presentation.label.contains("记录值"))
        XCTAssertTrue(presentation.valueText?.contains("500") == true)
        XCTAssertTrue(presentation.needsCalibration)
    }
}
