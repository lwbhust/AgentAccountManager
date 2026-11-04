import Foundation
import Core

/// 服务装配容器：集中创建并持有全部 Core 服务。
///
/// 恢复备份 / 清空数据会重建数据库并整体替换服务实例；
/// Store 持有 registry 本身（身份稳定），每次经它读取当前服务，
/// 避免捕获到被替换前的旧服务。
@MainActor
final class ServiceRegistry {
    private(set) var database: DatabaseService?
    private(set) var accountService: AccountService?
    private(set) var creditService: CreditService?
    private(set) var switchLogService: SwitchLogService?
    private(set) var switchService: SwitchService?
    private(set) var taskService: TraeTaskService?
    private(set) var projectVisitService: ProjectVisitService?
    private(set) var projectService: ProjectService?
    private(set) var workstationService: WorkstationService?
    private(set) var workbenchService: WorkbenchService?

    /// 钥匙串与 TRAE 进程服务不依赖数据库，全生命周期唯一。
    let keychain = KeychainService()
    let traeService = TraeService()

    /// 用新数据库重建全部服务（原 AppState.install 的装配部分）。
    func install(_ db: DatabaseService) {
        self.database = db
        let accounts = AccountService(database: db)
        let credits = CreditService(database: db)
        let switches = SwitchLogService(database: db)
        let visits = ProjectVisitService(database: db)
        self.accountService = accounts
        self.creditService = credits
        self.switchLogService = switches
        self.projectVisitService = visits
        self.switchService = SwitchService(
            accountService: accounts,
            switchLogService: switches,
            database: db,
            projectVisitService: visits
        )
        self.taskService = TraeTaskService(database: db)
        let projects = ProjectService(database: db)
        let workstations = WorkstationService(database: db)
        self.projectService = projects
        self.workstationService = workstations
        self.workbenchService = WorkbenchService(
            projects: projects,
            workstations: workstations,
            accounts: accounts
        )
    }
}
