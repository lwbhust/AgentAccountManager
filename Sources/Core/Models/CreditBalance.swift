import Foundation

/// 预计余额：以最近一次手动录入的余额为基准，减去该时刻之后采集到的任务消耗。
///
/// 只在本地计算，不改变账号里记录的余额本身；用户重新录入最新余额时，
/// 基准时间随之前移，此前已扣减的任务消耗会自动不再计入，避免重复扣减。
public struct CreditBalanceEstimate: Sendable, Equatable {
    /// 基准余额（最近一次成功录入的数值）
    public let baselineCredits: Int
    /// 基准的观测时间
    public let baselineAt: Date
    /// 基准之后采集到的任务消耗合计
    public let consumedCredits: Double
    /// 基准之后已采集到消耗的任务数
    public let consumedTaskCount: Int
    /// 基准之后仍未采集到消耗的任务数（未计入扣减，不按 0 处理）
    public let pendingTaskCount: Int

    public init(
        baselineCredits: Int,
        baselineAt: Date,
        consumedCredits: Double,
        consumedTaskCount: Int,
        pendingTaskCount: Int
    ) {
        self.baselineCredits = baselineCredits
        self.baselineAt = baselineAt
        self.consumedCredits = consumedCredits
        self.consumedTaskCount = consumedTaskCount
        self.pendingTaskCount = pendingTaskCount
    }

    /// 预计当前可用积分
    public var estimatedCredits: Double {
        Double(baselineCredits) - consumedCredits
    }

    /// 基准之后是否已有任务消耗
    public var hasDeduction: Bool {
        consumedTaskCount > 0
    }
}
