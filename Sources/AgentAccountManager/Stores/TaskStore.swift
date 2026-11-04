import Foundation
import Core

/// 任务采集领域状态：六元组统计、诊断与任务查询。
///
/// 日志扫描（TraeTaskScanner）与落库（TraeTaskService）都在 Core；
/// 这里负责后台调度与把采集结果发布给界面。
@MainActor
final class TaskStore: ObservableObject {
    /// 任务采集版本号：有新任务或消耗更新时递增，详情页据此重新加载。
    @Published private(set) var revision: Int = 0
    /// 各账号的任务采集诊断（最近扫描、最近成功解析、格式异常等）。
    @Published private(set) var diagnostics: [UUID: TraeTaskScanDiagnostics] = [:]
    /// 最近一次后台采集完成的时间。
    @Published private(set) var lastCollectionAt: Date?
    /// 最近一次采集的六元组统计（发现/解析/新增/更新/跳过/失败），
    /// 用于区分「没有新任务」和「采集出现问题」。
    @Published private(set) var lastCollectionStats: TraeTaskCollectionStats?

    /// 是否正在采集：定时循环、回到前台与手动 ⌘R 可能并发触发，只保留一个在跑。
    private var isCollecting = false

    private let registry: ServiceRegistry
    private let logger: AppLogger
    /// 增量读取各账号 TRAE 日志；只在后台任务中访问。
    private lazy var taskScanner = TraeTaskScanner(root: registry.traeService.traeDataRoot)

    init(registry: ServiceRegistry, logger: AppLogger) {
        self.registry = registry
        self.logger = logger
    }

    /// 采集 TRAE 本地日志里的任务与单任务积分消耗。
    ///
    /// 日志读取与解析在后台执行，只有真正发生变化的行才会写入数据库；
    /// 由界面定时调用，不在渲染路径中执行。
    /// 每次采集产出六元组统计（发现/解析/新增/更新/跳过/失败），
    /// 记录到 `lastCollectionStats`；有异常或实际写入时输出日志。
    /// - Returns: 本次实际写入（新增+更新）的行数；0 表示没有变化、没有可采账号或已在采集中。
    func collect(traeAccountIds ids: [UUID]) async -> Int {
        guard let service = registry.taskService, !ids.isEmpty else { return 0 }
        // 并发去重：上一轮扫描还没结束时直接跳过本轮（结果会在上一轮里体现）。
        guard !isCollecting else { return 0 }
        isCollecting = true
        defer { isCollecting = false }
        let scanner = taskScanner
        let logger = logger
        let result = await Task.detached(priority: .utility) { () -> (stats: TraeTaskCollectionStats, report: TraeTaskScanReport) in
            let report = await scanner.scanDetailed(accountIds: ids)
            var stats = TraeTaskCollectionStats(scan: report, write: TraeTaskUpsertReport())
            guard !report.events.isEmpty else { return (stats, report) }
            do {
                stats.merge(try service.upsertWithReport(report.events))
            } catch {
                // 事务整体失败：所有事件都未落库，如实计入 failed
                logger.error("任务日志写入失败: \(error.localizedDescription)")
                stats.failed = report.events.count
            }
            return (stats, report)
        }.value

        let stats = result.stats
        diagnostics = result.report.diagnostics
        lastCollectionStats = stats
        lastCollectionAt = Date()
        if stats.changedCount > 0 || stats.hasIssue {
            logger.info(
                "任务采集: 发现\(stats.discovered) 解析\(stats.parsed) 新增\(stats.inserted) 更新\(stats.updated) 跳过\(stats.skipped) 失败\(stats.failed)"
            )
        }
        if stats.changedCount > 0 {
            revision &+= 1
        }
        return stats.changedCount
    }

    func history(for accountId: UUID, limit: Int = 50, offset: Int = 0) -> [TraeTask] {
        (try? registry.taskService?.history(for: accountId, limit: limit, offset: offset)) ?? []
    }

    /// 某账号最新一条任务（工作台工位卡片摘要用）。
    func latest(for accountId: UUID) -> TraeTask? {
        (try? registry.taskService?.history(for: accountId, limit: 1))??.first
    }

    func count(for accountId: UUID) -> Int {
        (try? registry.taskService?.count(for: accountId)) ?? 0
    }

    /// 某时间之后解析出的任务积分消耗合计（来自日志，不是官方余额）。
    func creditsConsumed(for accountId: UUID, since: Date) -> Double? {
        (try? registry.taskService?.creditsConsumed(for: accountId, since: since)) ?? nil
    }
}
