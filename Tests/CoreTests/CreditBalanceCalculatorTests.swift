import XCTest
import Core

/// CreditBalanceCalculator 的边界矩阵：
/// 语义必须与原 balanceEstimate 的 SQL 行为一致。
final class CreditBalanceCalculatorTests: XCTestCase {
    private func baseline(_ credits: Int?, _ timestamp: TimeInterval?) -> CreditBalanceCalculator.BaselineRow {
        .init(credits: credits, observedAt: timestamp.map { Date(timeIntervalSince1970: $0) })
    }

    private func task(_ credits: Double?, _ timestamp: TimeInterval?) -> CreditBalanceCalculator.TaskRow {
        .init(credits: credits, createdAt: timestamp.map { Date(timeIntervalSince1970: $0) })
    }

    // MARK: - 基准选取

    /// 没有任何可用基准时返回 nil，即使有任务也不把未知当 0。
    func testNoBaselineReturnsNil() {
        XCTAssertNil(CreditBalanceCalculator.estimate(baselines: [], tasks: [task(2, 100)]))
        // 候选行的 credits/observedAt 为空等价于无基准
        XCTAssertNil(CreditBalanceCalculator.estimate(baselines: [baseline(nil, 100)], tasks: [task(2, 200)]))
        XCTAssertNil(CreditBalanceCalculator.estimate(baselines: [baseline(50, nil)], tasks: [task(2, 200)]))
    }

    /// credits 或 observedAt 为空的候选行被跳过，其余仍可用。
    func testIncompleteBaselineRowsAreSkipped() {
        let estimate = CreditBalanceCalculator.estimate(
            baselines: [baseline(nil, 300), baseline(80, nil), baseline(50, 200)],
            tasks: []
        )
        XCTAssertEqual(estimate?.baselineCredits, 50)
        XCTAssertEqual(estimate?.baselineAt, Date(timeIntervalSince1970: 200))
    }

    /// 多条基准乱序输入：取 observedAt 最新的一条。
    func testPicksLatestBaselineRegardlessOfOrder() {
        let estimate = CreditBalanceCalculator.estimate(
            baselines: [baseline(100, 300), baseline(90, 200), baseline(80, 100)],
            tasks: [task(10, 250), task(5, 350)]
        )
        XCTAssertEqual(estimate?.baselineCredits, 100)
        XCTAssertEqual(estimate?.baselineAt, Date(timeIntervalSince1970: 300))
        // 只有 t=350 的任务在基准（t=300）之后，t=250 的任务不计入
        XCTAssertEqual(estimate?.consumedCredits ?? 0, 5, accuracy: 0.0001)
        XCTAssertEqual(estimate?.consumedTaskCount, 1)
        XCTAssertEqual(estimate?.pendingTaskCount, 0)
    }

    /// observedAt 并列时保留先出现的一条（收敛后的确定规则）。
    func testBaselineTieKeepsFirst() {
        let estimate = CreditBalanceCalculator.estimate(
            baselines: [baseline(70, 200), baseline(60, 200)],
            tasks: []
        )
        XCTAssertEqual(estimate?.baselineCredits, 70)
    }

    // MARK: - 时间过滤

    /// 基准之前与恰在基准时刻的任务都不计入（严格大于）。
    func testTasksAtOrBeforeBaselineExcluded() {
        let estimate = CreditBalanceCalculator.estimate(
            baselines: [baseline(100, 1000)],
            tasks: [task(5, 999), task(5, 1000), task(5, 1001)]
        )
        XCTAssertEqual(estimate?.consumedCredits ?? 0, 5, accuracy: 0.0001)
        XCTAssertEqual(estimate?.consumedTaskCount, 1)
        XCTAssertEqual(estimate?.pendingTaskCount, 0)
    }

    /// createdAt 为空的行不参与任何统计（与 SQL 的 NULL 比较语义一致）。
    func testTaskWithoutTimestampExcluded() {
        let estimate = CreditBalanceCalculator.estimate(
            baselines: [baseline(100, 1000)],
            tasks: [task(5, nil), task(5, 1001)]
        )
        XCTAssertEqual(estimate?.consumedCredits ?? 0, 5, accuracy: 0.0001)
        XCTAssertEqual(estimate?.consumedTaskCount, 1)
        XCTAssertEqual(estimate?.pendingTaskCount, 0)
    }

    // MARK: - 消耗统计

    /// credits 全空：消耗为 0，全部任务计入待采集，估算等于基准。
    func testTasksWithoutCreditsCountAsPending() {
        let estimate = CreditBalanceCalculator.estimate(
            baselines: [baseline(100, 1000)],
            tasks: [task(nil, 1001), task(nil, 1002)]
        )
        XCTAssertEqual(estimate?.consumedCredits ?? 0, 0, accuracy: 0.0001)
        XCTAssertEqual(estimate?.consumedTaskCount, 0)
        XCTAssertEqual(estimate?.pendingTaskCount, 2)
        XCTAssertEqual(estimate?.estimatedCredits ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(estimate?.hasDeduction, false)
    }

    /// nil credits 与有值任务混合：只有非空 credits 累加，其余计入待采集。
    func testMixedCreditsOnlySumsKnownValues() {
        let estimate = CreditBalanceCalculator.estimate(
            baselines: [baseline(100, 1000)],
            tasks: [task(nil, 1001), task(nil, 1002), task(4, 1003)]
        )
        XCTAssertEqual(estimate?.consumedCredits ?? 0, 4, accuracy: 0.0001)
        XCTAssertEqual(estimate?.consumedTaskCount, 1)
        XCTAssertEqual(estimate?.pendingTaskCount, 2)
        XCTAssertEqual(estimate?.estimatedCredits ?? 0, 96, accuracy: 0.0001)
    }

    /// 消耗超过基准：负估算原样透传，不做截断。
    func testNegativeEstimatePassesThrough() {
        let estimate = CreditBalanceCalculator.estimate(
            baselines: [baseline(10, 1000)],
            tasks: [task(6, 1001), task(7, 1002)]
        )
        XCTAssertEqual(estimate?.estimatedCredits ?? 0, -3, accuracy: 0.0001)
        XCTAssertEqual(estimate?.hasDeduction, true)
    }
}
