import Foundation
import Core

/// 积分领域状态：各账号预计余额缓存与积分历史查询。
///
/// 余额估算本身在 Core（CreditBalanceCalculator / CreditService），
/// 这里只负责把「按账号批量刷新后的估算」发布给界面。
@MainActor
final class CreditStore: ObservableObject {
    /// 各账号的预计余额（最近一次录入 − 之后的任务消耗），随账号列表与任务采集刷新。
    @Published private(set) var balances: [UUID: CreditBalanceEstimate] = [:]

    private let registry: ServiceRegistry
    private let logger: AppLogger

    init(registry: ServiceRegistry, logger: AppLogger) {
        self.registry = registry
        self.logger = logger
    }

    /// 重新计算各账号的预计余额（基准余额减去之后的任务消耗）。
    ///
    /// 只读本地数据库，供界面刷新使用；没有成功录入的账号不产生条目。
    func refreshBalances(for accounts: [Account]) {
        guard let service = registry.creditService else { return }
        var result: [UUID: CreditBalanceEstimate] = [:]
        for account in accounts {
            guard account.hasCreditRecord else { continue }
            do {
                if let estimate = try service.balanceEstimate(for: account.id) {
                    result[account.id] = estimate
                }
            } catch {
                logger.error(
                    "计算预计余额失败: account=\(account.id.uuidString.prefix(8)) error=\(error.localizedDescription)"
                )
            }
        }
        if result != balances {
            balances = result
        }
    }

    /// 该账号的预计余额；还没有成功录入过余额时为 nil。
    func balance(for accountId: UUID) -> CreditBalanceEstimate? {
        balances[accountId]
    }

    /// 界面上展示的当前积分：有预计余额时优先用它，否则退回最近录入值。
    func displayedCredits(for account: Account) -> Double? {
        if let estimate = balances[account.id] {
            return estimate.estimatedCredits
        }
        return account.currentCredits.map(Double.init)
    }

    func history(for accountId: UUID, limit: Int = 50, offset: Int = 0) -> [CreditSnapshot] {
        (try? registry.creditService?.history(for: accountId, limit: limit, offset: offset)) ?? []
    }

    func historyCount(for accountId: UUID) -> Int {
        (try? registry.creditService?.count(for: accountId)) ?? 0
    }

    var staleInterval: TimeInterval {
        registry.creditService?.staleInterval ?? 24 * 3600
    }
}
