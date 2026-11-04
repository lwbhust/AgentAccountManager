import Foundation
import Core

/// 积分的展示模型（仅 UI 层）。
///
/// 积分来自手动录入 + 日志推算，不是官方余额。所有展示都必须带置信度标签，
/// 不允许只显示一个看似精确的数字。
///
/// 语义分级（audit P0 修正）：
/// - `needsAttention`：真正需要用户处理的问题（估算为负、查询失败）→ 警示色；
/// - `isEstimate`：估算/记录值、样本不足、数据较旧都是"常态信息"→ 中性色，
///   只靠文字标签说明置信度，不再整段橙色渲染。
struct CreditPresentation: Equatable {
    let valueText: String?
    let label: String
    let detail: String?
    let needsCalibration: Bool
    /// 真正的异常状态（负余额、查询失败），仅此情况使用警示色。
    let needsAttention: Bool

    /// 兼容旧调用方：原 isWarning 语义已收窄为 needsAttention。
    var isWarning: Bool { needsAttention }

    init(
        account: Account,
        estimate: CreditBalanceEstimate?,
        staleInterval: TimeInterval,
        now: Date = Date()
    ) {
        if account.dataStatus == .queryFailed {
            self.valueText = account.currentCredits.map { "约 \(Format.credits($0))" }
            self.label = "上次查询失败 · 沿用旧记录"
            self.detail = "不代表当前余额"
            self.needsCalibration = true
            self.needsAttention = true
            return
        }

        guard account.hasCreditRecord else {
            self.valueText = nil
            self.label = "未录入"
            self.detail = "去 TRAE 官方界面查看后录入"
            self.needsCalibration = true
            self.needsAttention = false
            return
        }

        guard let estimate else {
            let value = account.currentCredits.map { "约 \(Format.credits($0))" }
            let age = account.lastCreditQueryAt.map { Format.relative($0) } ?? "时间未知"
            self.valueText = value
            self.label = "记录值 · \(age)"
            self.detail = "未做任务扣减，非实时"
            self.needsCalibration = true
            self.needsAttention = false
            return
        }

        let value = "约 \(Format.credits(estimate.estimatedCredits))"
        let age = now.timeIntervalSince(estimate.baselineAt)
        let isStale = age > staleInterval

        if estimate.estimatedCredits < 0 {
            self.valueText = value
            self.label = "估算为负 · 需校准"
            self.detail = "任务消耗已超过记录值"
            self.needsCalibration = true
            self.needsAttention = true
            return
        }

        if estimate.pendingTaskCount > 0 {
            self.valueText = value
            self.label = "估算 · \(estimate.pendingTaskCount) 个任务未采集"
            self.detail = "样本不足，仅供参考"
            self.needsCalibration = true
            self.needsAttention = false
            return
        }

        if isStale {
            self.valueText = value
            self.label = "估算 · \(Format.relative(estimate.baselineAt))"
            self.detail = "数据较旧，建议核对后校准"
            self.needsCalibration = true
            self.needsAttention = false
            return
        }

        self.valueText = value
        self.label = "估算 · \(Format.relative(estimate.baselineAt))"
        self.detail = "基准 \(Format.credits(estimate.baselineCredits)) − 已采集 \(Format.credits(estimate.consumedCredits))"
        self.needsCalibration = false
        self.needsAttention = false
    }
}
