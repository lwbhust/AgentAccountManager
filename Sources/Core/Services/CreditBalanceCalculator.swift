import Foundation

/// 预计余额的纯计算：基准选取 + 基准时刻之后的消耗统计。
///
/// 算法从 `CreditService.balanceEstimate` 的原 SQL 语义平移而来：
/// 数据库只负责取原始行，这里不做任何 IO，便于用边界矩阵直接验证。
/// 语义与原实现一致：
/// - 基准 = 成功录入且 credits 非空的记录中 observedAt 最新的一条；
///   同一时刻并列时保留先出现的一条（原 SQL 在并列时行为未定义，
///   这里收敛为确定规则）。
/// - 只有 `createdAt > 基准时刻` 的任务计入消耗（严格大于，恰在基准时刻不算）。
/// - 消耗合计只累加 credits 非空的任务；credits 为空的任务计入「待采集」
///   数量，不按 0 处理。
/// - 没有任何可用基准时返回 nil（不把未知当 0）。
public enum CreditBalanceCalculator {
    /// 基准候选行（credit_snapshots 中 status='success' 的记录）。
    public struct BaselineRow: Sendable, Equatable {
        /// 录入的积分；为空的行不能作为基准
        public let credits: Int?
        /// 观测时间；为空的行不能作为基准
        public let observedAt: Date?

        public init(credits: Int?, observedAt: Date?) {
            self.credits = credits
            self.observedAt = observedAt
        }
    }

    /// 任务行（trae_tasks）。
    public struct TaskRow: Sendable, Equatable {
        /// 采集到的单轮消耗；为空表示尚未采集到该轮消耗
        public let credits: Double?
        /// 任务创建时间；为空的行不参与统计（与 SQL 对 NULL 的比较语义一致）
        public let createdAt: Date?

        public init(credits: Double?, createdAt: Date?) {
            self.credits = credits
            self.createdAt = createdAt
        }
    }

    /// 由基准候选与任务原始行计算预计余额；没有可用基准时返回 nil。
    public static func estimate(
        baselines: [BaselineRow],
        tasks: [TaskRow]
    ) -> CreditBalanceEstimate? {
        var baseline: (credits: Int, observedAt: Date)?
        for row in baselines {
            guard let credits = row.credits, let observedAt = row.observedAt else { continue }
            if let current = baseline, observedAt <= current.observedAt { continue }
            baseline = (credits, observedAt)
        }
        guard let baseline else { return nil }

        var consumedCredits: Double = 0
        var consumedTaskCount = 0
        var allTaskCount = 0
        for task in tasks {
            guard let createdAt = task.createdAt, createdAt > baseline.observedAt else { continue }
            allTaskCount += 1
            if let credits = task.credits {
                consumedCredits += credits
                consumedTaskCount += 1
            }
        }

        return CreditBalanceEstimate(
            baselineCredits: baseline.credits,
            baselineAt: baseline.observedAt,
            consumedCredits: consumedCredits,
            consumedTaskCount: consumedTaskCount,
            pendingTaskCount: max(0, allTaskCount - consumedTaskCount)
        )
    }
}
