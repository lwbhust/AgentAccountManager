import XCTest
import Core

class WorkbenchTestCase: XCTestCase {
    var tempRoot: URL!
    var dbURL: URL!
    var db: DatabaseService!
    var accounts: AccountService!
    var projects: ProjectService!
    var workstations: WorkstationService!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkbenchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        dbURL = tempRoot.appendingPathComponent("test.sqlite")
        db = try DatabaseService(databaseURL: dbURL)
        rebuildServices()
    }

    override func tearDownWithError() throws {
        db?.close()
        db = nil
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        dbURL = nil
    }

    func rebuildServices() {
        accounts = AccountService(database: db)
        projects = ProjectService(database: db)
        workstations = WorkstationService(database: db)
    }

    func createTraeAccount(_ name: String = "TRAE") throws -> Account {
        try accounts.create(platform: .trae, displayName: name, phoneMasked: "")
    }

    func createWorkBuddyAccount(_ name: String = "WB") throws -> Account {
        try accounts.create(platform: .workbuddy, displayName: name, phoneMasked: "")
    }

    func createProject(repo: URL? = nil, mode: Project.OrchestrationMode = .freeLane) throws -> Project {
        let repoPath = repo?.path ?? tempRoot.appendingPathComponent("placeholder-repo").path
        return try projects.create(
            displayName: "测试项目",
            repoPath: repoPath,
            baselineBranch: "main",
            orchestrationMode: mode,
            worktreeRoot: tempRoot.appendingPathComponent("worktrees").path
        )
    }

    func makeGitRepo() throws -> URL {
        let gitPath = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: gitPath) else {
            throw XCTSkip("git 不可用，跳过 Git 相关测试")
        }
        let repo = tempRoot.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["-C", repo.path, "init", "-b", "main"])
        try runGit(["-C", repo.path, "config", "user.email", "test@example.com"])
        try runGit(["-C", repo.path, "config", "user.name", "Workbench Test"])
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["-C", repo.path, "add", "README.md"])
        try runGit(["-C", repo.path, "commit", "-m", "initial"])
        return repo
    }

    func runGit(_ arguments: [String]) throws {
        let result = ProcessService().run(
            launchPath: "/usr/bin/git",
            arguments: arguments,
            timeout: 30
        )
        guard result.0 == 0 else {
            throw NSError(
                domain: "WorkbenchTests.git",
                code: Int(result.0),
                userInfo: [NSLocalizedDescriptionKey: result.2.isEmpty ? result.1 : result.2]
            )
        }
    }
}

// MARK: - 数据库与服务

final class WorkbenchDatabaseTests: WorkbenchTestCase {
    func testSchemaVersionAndTables() throws {
        XCTAssertEqual(DatabaseService.supportedSchemaVersion, 7)
        XCTAssertEqual(try db.db.scalar("PRAGMA user_version"), 7)
        let tables = try db.db.scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('projects','workstations')"
        )
        XCTAssertEqual(tables, 2)
    }

    func testProjectAndWorkstationCRUD() throws {
        let account = try createTraeAccount()
        let project = try createProject()
        let lanes = try workstations.createDefaults(for: project)

        XCTAssertEqual(lanes.count, 3)
        XCTAssertEqual(Set(lanes.compactMap(\.worktreePath)).count, 3)
        XCTAssertTrue(lanes.allSatisfy { $0.branchName?.hasPrefix("workbench/") == true })

        var items = try workstations.list(projectId: project.id)
        items[0].displayName = "主工位"
        items[0].accountId = account.id
        try workstations.updateBatch(project: project, workstations: items)

        let refreshed = try workstations.list(projectId: project.id)
        XCTAssertEqual(refreshed.first(where: { $0.id == items[0].id })?.displayName, "主工位")
        XCTAssertEqual(refreshed.first(where: { $0.id == items[0].id })?.accountId, account.id)

        let refs = try workstations.references(forAccountId: account.id)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.projectName, "测试项目")

        XCTAssertTrue(try projects.delete(id: project.id))
        XCTAssertTrue(try workstations.list(projectId: project.id).isEmpty)
    }

    func testAccountDeletionSetsWorkstationAccountNil() throws {
        let account = try createTraeAccount()
        let project = try createProject()
        let lane = try XCTUnwrap(try workstations.createDefaults(for: project).first)
        try workstations.assignAccount(workstationId: lane.id, accountId: account.id)

        XCTAssertTrue(try accounts.delete(id: account.id))
        let refreshed = try workstations.get(id: lane.id)
        XCTAssertNotNil(refreshed)
        XCTAssertNil(refreshed?.accountId)
    }

    func testWorkstationValidation() throws {
        let project = try createProject()
        let lanes = try workstations.createDefaults(for: project)
        let workBuddy = try createWorkBuddyAccount()

        XCTAssertThrowsError(
            try workstations.assignAccount(workstationId: lanes[0].id, accountId: workBuddy.id)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("TRAE"))
        }

        let trae = try createTraeAccount()
        try workstations.assignAccount(workstationId: lanes[0].id, accountId: trae.id)
        XCTAssertThrowsError(
            try workstations.assignAccount(workstationId: lanes[1].id, accountId: trae.id)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("一个账号只能绑定一个工位"))
        }

        _ = try workstations.create(
            project: project,
            displayName: "lane4",
            isEnabled: false
        )
        var all = try workstations.list(projectId: project.id)
        for index in all.indices { all[index].isEnabled = true }
        XCTAssertThrowsError(try workstations.updateBatch(project: project, workstations: all)) { error in
            XCTAssertTrue(error.localizedDescription.contains("最多启用 3 个工位"))
        }
    }

    func testDuplicateWorkstationNameRejected() throws {
        let project = try createProject()
        _ = try workstations.createDefaults(for: project)
        var items = try workstations.list(projectId: project.id)
        items[1].displayName = items[0].displayName
        XCTAssertThrowsError(try workstations.updateBatch(project: project, workstations: items)) { error in
            XCTAssertTrue(error.localizedDescription.contains("名称不能重复"))
        }
    }

    func testProjectRepoPathIsImmutableAfterLanesCreated() throws {
        let project = try createProject()
        _ = try workstations.createDefaults(for: project)
        XCTAssertThrowsError(
            try projects.update(
                id: project.id,
                displayName: project.displayName,
                repoPath: tempRoot.appendingPathComponent("another-repo").path,
                baselineBranch: project.baselineBranch,
                orchestrationMode: project.orchestrationMode,
                buildCommand: nil,
                testCommand: nil,
                setupHint: nil,
                worktreeRoot: project.worktreeRoot,
                projectMemory: nil,
                note: nil
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("已有工位"))
        }
    }

    func testV7MigrationIsIdempotentAndPreservesAccounts() throws {
        let account = try createTraeAccount("保留账号")

        try db.db.execute("DROP TABLE workstations")
        try db.db.execute("DROP TABLE projects")
        try db.db.execute("PRAGMA user_version = 6")
        db.close()

        db = try DatabaseService(databaseURL: dbURL)
        rebuildServices()

        XCTAssertEqual(try db.db.scalar("PRAGMA user_version"), 7)
        XCTAssertEqual(try accounts.listAll().count, 1)
        XCTAssertEqual(try accounts.listAll().first?.id, account.id)
        XCTAssertEqual(
            try db.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='projects'"),
            1
        )
        XCTAssertEqual(
            try db.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='workstations'"),
            1
        )
    }
}

// MARK: - Git

final class WorkbenchGitTests: WorkbenchTestCase {
    func testGitAndWorktreeLifecycle() throws {
        let repo = try makeGitRepo()
        let service = GitWorktreeService(gitPath: "/usr/bin/git")

        XCTAssertTrue(service.isRepository(at: repo))
        XCTAssertEqual(service.currentBranch(at: repo), "main")
        XCTAssertTrue(service.localBranches(at: repo).contains("main"))

        let target = tempRoot.appendingPathComponent("wt-lane1", isDirectory: true)
        let branch = "workbench/test/lane1"
        try service.addWorktree(repoURL: repo, path: target, branch: branch, baseline: "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        let records = try service.existingWorktrees(at: repo)
        XCTAssertTrue(records.contains {
            $0.path == target.standardizedFileURL.path && $0.branch == branch
        })
        XCTAssertTrue(try service.statusSummary(at: target).isClean)

        XCTAssertThrowsError(try service.removeWorktree(repoURL: repo, path: target, confirm: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("二次确认"))
        }

        let dirty = target.appendingPathComponent("dirty.txt")
        try "x".write(to: dirty, atomically: true, encoding: .utf8)
        XCTAssertFalse(try service.statusSummary(at: target).isClean)
        XCTAssertThrowsError(try service.removeWorktree(repoURL: repo, path: target, confirm: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("未提交变更"))
        }

        try FileManager.default.removeItem(at: dirty)
        try service.removeWorktree(repoURL: repo, path: target, confirm: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testAddWorktreeRejectsExistingPath() throws {
        let repo = try makeGitRepo()
        let service = GitWorktreeService(gitPath: "/usr/bin/git")
        let target = tempRoot.appendingPathComponent("existing-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try service.addWorktree(
                repoURL: repo,
                path: target,
                branch: "workbench/test/existing",
                baseline: "main"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("已存在"))
        }
    }
}

// MARK: - 生命周期对账（真实 Git 集成）

final class WorkbenchReconciliationTests: WorkbenchTestCase {
    func testReconcileProjectLifecycle() throws {
        let repo = try makeGitRepo()
        let project = try createProject(repo: repo)
        _ = try workstations.createDefaults(for: project)
        let lanes = try workstations.list(projectId: project.id)
        let lane1 = try XCTUnwrap(lanes.first { $0.displayName == "工位 1" })
        let lane2 = try XCTUnwrap(lanes.first { $0.displayName == "工位 2" })

        let service = WorkbenchService(
            projects: projects,
            workstations: workstations,
            accounts: accounts,
            git: GitWorktreeService(gitPath: "/usr/bin/git")
        )

        // 尚未开工：全部 notStarted，无需留意
        var report = try service.reconcile(project: project)
        XCTAssertTrue(report.workstations.allSatisfy { $0.health == .notStarted })
        XCTAssertFalse(report.needsAttention)
        XCTAssertTrue(report.unmanaged.isEmpty, "仓库主工作区不应计入未纳管")

        // 开工后：登记与目录一致 → healthy
        let git = GitWorktreeService(gitPath: "/usr/bin/git")
        try git.addWorktree(
            repoURL: repo,
            path: XCTUnwrap(lane1.worktreeURL),
            branch: XCTUnwrap(lane1.branchName),
            baseline: "main"
        )
        try workstations.touchLastActivated(id: lane1.id)
        report = try service.reconcile(project: project)
        var lane1Report = try XCTUnwrap(report.workstations.first { $0.workstationId == lane1.id })
        XCTAssertEqual(lane1Report.health, .healthy)
        XCTAssertEqual(lane1Report.status?.branch, lane1.branchName)
        XCTAssertFalse(lane1Report.isBranchMismatch)

        // 有未提交变更仍属 healthy，但状态可见
        try "wip".write(
            to: XCTUnwrap(lane1.worktreeURL).appendingPathComponent("wip.txt"),
            atomically: true,
            encoding: .utf8
        )
        report = try service.reconcile(project: project)
        lane1Report = try XCTUnwrap(report.workstations.first { $0.workstationId == lane1.id })
        XCTAssertEqual(lane1Report.status?.isClean, false)
        XCTAssertFalse(lane1Report.needsAttention)

        // 目录丢失（异常退出/外部删除）→ directoryMissing
        try FileManager.default.removeItem(at: XCTUnwrap(lane1.worktreeURL))
        report = try service.reconcile(project: project)
        lane1Report = try XCTUnwrap(report.workstations.first { $0.workstationId == lane1.id })
        XCTAssertEqual(lane1Report.health, .directoryMissing)
        XCTAssertTrue(lane1Report.needsAttention)

        // prune 掉登记后：激活记录还在、痕迹全无 → vanished
        try runGit(["-C", repo.path, "worktree", "prune"])
        report = try service.reconcile(project: project)
        lane1Report = try XCTUnwrap(report.workstations.first { $0.workstationId == lane1.id })
        XCTAssertEqual(lane1Report.health, .vanished)
        XCTAssertTrue(lane1Report.needsAttention)

        // 手工创建的 worktree 报告为未纳管；lane2 未开工仍是 notStarted
        try runGit([
            "-C", repo.path, "worktree", "add", "-b", "extra/manual",
            tempRoot.appendingPathComponent("manual-wt").path, "main"
        ])
        report = try service.reconcile(project: project)
        XCTAssertEqual(report.unmanaged.map(\.branch), ["extra/manual"])
        let lane2Report = try XCTUnwrap(report.workstations.first { $0.workstationId == lane2.id })
        XCTAssertEqual(lane2Report.health, .notStarted)
        XCTAssertTrue(report.needsAttention, "存在 vanished 工位时整体需要留意")
    }
}

// MARK: - 预检

final class StartupPreflightTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(platform: Platform = .trae) -> Account {
        Account(platform: platform, displayName: "账号", phoneMasked: "")
    }

    private func input(
        mode: Project.OrchestrationMode = .freeLane,
        account: Account? = nil,
        nilAccount: Bool = false,
        workstationAccountId: UUID? = nil,
        workstationEnabled: Bool = true,
        duplicateAccount: Bool = false,
        gitInstalled: Bool = true,
        repoExists: Bool = true,
        repoIsGit: Bool = true,
        baselineExists: Bool = true,
        pathState: StartupPreflight.WorktreePathState = .missing,
        branchOccupied: Bool = false,
        status: GitWorktreeService.WorktreeStatus? = nil,
        runtime: StartupPreflight.RuntimeContext = StartupPreflight.RuntimeContext(
            isAccountRunning: false,
            openWorkspaces: [],
            targetWorktree: URL(fileURLWithPath: "/tmp/workbench-target")
        ),
        setupHint: String? = nil
    ) -> StartupPreflight.Input {
        let project = Project(
            displayName: "P",
            repoPath: "/tmp/repo",
            baselineBranch: "main",
            orchestrationMode: mode,
            setupHint: setupHint
        )
        let workstation = Workstation(
            projectId: project.id,
            accountId: workstationAccountId,
            displayName: "工位",
            worktreePath: "/tmp/workbench-target",
            branchName: "workbench/test/lane1",
            isEnabled: workstationEnabled
        )
        return StartupPreflight.Input(
            project: project,
            workstation: workstation,
            account: nilAccount ? nil : (account ?? self.account()),
            accountAlreadyBoundToOtherLane: duplicateAccount,
            gitInstalled: gitInstalled,
            repoExists: repoExists,
            repoIsGit: repoIsGit,
            baselineBranchExists: baselineExists,
            pathState: pathState,
            targetBranchOccupied: branchOccupied,
            worktreeStatus: status,
            runtime: runtime
        )
    }

    private func status(_ result: StartupPreflight.Result, id: String) -> StartupPreflight.Status? {
        result.checks.first(where: { $0.id == id })?.status
    }

    func testAllChecksPass() {
        let result = StartupPreflight.evaluate(input())
        XCTAssertTrue(result.canProceed)
        XCTAssertTrue(result.blockingChecks.isEmpty)
        XCTAssertTrue(result.warningChecks.isEmpty)
    }

    func testBlocksGitRepoAndBaselineFailures() {
        XCTAssertEqual(status(StartupPreflight.evaluate(input(gitInstalled: false)), id: "git"), .blocked)
        XCTAssertEqual(status(StartupPreflight.evaluate(input(repoExists: false)), id: "repo"), .blocked)
        XCTAssertEqual(status(StartupPreflight.evaluate(input(repoIsGit: false)), id: "repo"), .blocked)
        XCTAssertEqual(status(StartupPreflight.evaluate(input(baselineExists: false)), id: "baseline"), .blocked)
    }

    func testBlocksPathBranchAndAccountConflicts() {
        XCTAssertEqual(
            status(StartupPreflight.evaluate(input(pathState: .existingOtherRepo)), id: "worktreePath"),
            .blocked
        )
        XCTAssertEqual(
            status(StartupPreflight.evaluate(input(branchOccupied: true)), id: "branch"),
            .blocked
        )
        XCTAssertEqual(
            status(StartupPreflight.evaluate(input(nilAccount: true)), id: "account"),
            .blocked
        )
        XCTAssertEqual(
            status(StartupPreflight.evaluate(input(account: account(platform: .workbuddy))), id: "accountPlatform"),
            .blocked
        )
        XCTAssertEqual(
            status(StartupPreflight.evaluate(input(duplicateAccount: true)), id: "accountDuplicate"),
            .blocked
        )
        XCTAssertEqual(
            status(StartupPreflight.evaluate(input(workstationEnabled: false)), id: "enabled"),
            .blocked
        )
    }

    func testRoleModeRequiresMatchingAccount() {
        let bound = UUID()
        let result = StartupPreflight.evaluate(input(
            mode: .rolePlay,
            workstationAccountId: bound
        ))
        XCTAssertEqual(status(result, id: "roleBinding"), .blocked)
        XCTAssertFalse(result.canProceed)
    }

    func testWarnsForDirtyWorktreeAndOtherRunningDirectory() {
        let dirty = GitWorktreeService.WorktreeStatus(
            branch: "workbench/test/lane1",
            isClean: false,
            changedFileCount: 2
        )
        let runtime = StartupPreflight.RuntimeContext(
            isAccountRunning: true,
            openWorkspaces: [URL(fileURLWithPath: "/tmp/another-project")],
            targetWorktree: URL(fileURLWithPath: "/tmp/workbench-target"),
            runningLaneLabel: "「其他项目 / 工位」"
        )
        let result = StartupPreflight.evaluate(input(status: dirty, runtime: runtime))
        XCTAssertTrue(result.canProceed)
        XCTAssertEqual(status(result, id: "dirty"), .warning)
        XCTAssertEqual(status(result, id: "runtime"), .warning)
        XCTAssertTrue(result.warningChecks.count >= 2)
    }

    func testTargetWorktreeAlreadyOpenIsPass() {
        let target = URL(fileURLWithPath: "/tmp/workbench-target")
        let runtime = StartupPreflight.RuntimeContext(
            isAccountRunning: true,
            openWorkspaces: [target],
            targetWorktree: target
        )
        XCTAssertEqual(
            status(StartupPreflight.evaluate(input(runtime: runtime)), id: "runtime"),
            .pass
        )
    }

    func testPreflightContainsNoCreditChecks() {
        let result = StartupPreflight.evaluate(input(setupHint: "npm install"))
        XCTAssertEqual(status(result, id: "setup"), .info)
        let combined = result.checks.map { $0.title + ($0.detail ?? "") }.joined()
        XCTAssertFalse(combined.contains("积分"))
        XCTAssertFalse(combined.contains("保留线"))
        XCTAssertFalse(combined.contains("余额"))
    }
}

// MARK: - WorkbenchService

final class WorkbenchServiceTests: WorkbenchTestCase {
    func testPrepareExecuteAndReuse() throws {
        let repo = try makeGitRepo()
        let project = try createProject(repo: repo)
        let lanes = try workstations.createDefaults(for: project)
        let lane = try XCTUnwrap(lanes.first)
        let account = try createTraeAccount()
        try workstations.assignAccount(workstationId: lane.id, accountId: account.id)
        let refreshedLane = try XCTUnwrap(try workstations.get(id: lane.id))
        let target = try XCTUnwrap(refreshedLane.worktreeURL)

        let service = WorkbenchService(
            projects: projects,
            workstations: workstations,
            accounts: accounts,
            git: GitWorktreeService(gitPath: "/usr/bin/git")
        )
        let runtime = StartupPreflight.RuntimeContext(
            isAccountRunning: false,
            openWorkspaces: [],
            targetWorktree: target
        )

        let preparation = try service.prepareStart(
            project: project,
            workstation: refreshedLane,
            account: account,
            runtime: runtime
        )
        XCTAssertTrue(preparation.preflight.canProceed)
        XCTAssertTrue(preparation.willCreateWorktree)

        let plan = try service.executeStart(preparation: preparation, task: "实现登录")
        XCTAssertTrue(plan.createdWorktree)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(plan.contextPack.contains(project.displayName))
        XCTAssertTrue(plan.contextPack.contains(refreshedLane.displayName))
        XCTAssertTrue(plan.contextPack.contains("实现登录"))
        XCTAssertFalse(plan.contextPack.contains("积分"))

        let second = try service.prepareStart(
            project: project,
            workstation: refreshedLane,
            account: account,
            runtime: runtime
        )
        if case .existingSameRepo = second.pathState {
            // 预期复用
        } else {
            XCTFail("第二次预检应识别为已有 worktree")
        }
        let reused = try service.executeStart(preparation: second)
        XCTAssertFalse(reused.createdWorktree)

        let dirty = target.appendingPathComponent("dirty.txt")
        try "x".write(to: dirty, atomically: true, encoding: .utf8)
        let dirtyPreparation = try service.prepareStart(
            project: project,
            workstation: refreshedLane,
            account: account,
            runtime: runtime
        )
        XCTAssertTrue(dirtyPreparation.preflight.canProceed)
        XCTAssertTrue(dirtyPreparation.preflight.warningChecks.contains { $0.id == "dirty" })
    }

    func testRejectsWorkBuddyAccount() throws {
        let repo = try makeGitRepo()
        let project = try createProject(repo: repo)
        let lane = try XCTUnwrap(try workstations.createDefaults(for: project).first)
        let workBuddy = try createWorkBuddyAccount()
        let service = WorkbenchService(
            projects: projects,
            workstations: workstations,
            accounts: accounts,
            git: GitWorktreeService(gitPath: "/usr/bin/git")
        )
        let runtime = StartupPreflight.RuntimeContext(
            isAccountRunning: false,
            openWorkspaces: [],
            targetWorktree: lane.worktreeURL ?? URL(fileURLWithPath: "/tmp/none")
        )

        XCTAssertThrowsError(
            try service.prepareStart(
                project: project,
                workstation: lane,
                account: workBuddy,
                runtime: runtime
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("TRAE"))
        }
    }
}
