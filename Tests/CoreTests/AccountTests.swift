import XCTest
import Core

final class AccountTests: XCTestCase {
    var database: DatabaseService!
    var accountService: AccountService!
    var creditService: CreditService!

    override func setUpWithError() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        database = try DatabaseService(databaseURL: tmp)
        accountService = AccountService(database: database)
        creditService = CreditService(database: database)
    }

    override func tearDownWithError() throws {
        let url = database.databaseURL
        database.close()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 手机号脱敏

    func testMaskPhone() {
        XCTAssertEqual(Masking.maskPhone("13812341234"), "138****1234")
        XCTAssertEqual(Masking.maskPhone("123"), "***")
        XCTAssertEqual(Masking.maskPhone(""), "*")
    }

    func testPhoneHash() {
        let h1 = Masking.phoneHash("13812341234")
        let h2 = Masking.phoneHash("13812341234")
        XCTAssertEqual(h1, h2, "相同手机号摘要一致")
        XCTAssertEqual(h1.count, 64)
        XCTAssertNotEqual(h1, Masking.phoneHash("13900000000"))
    }

    func testRedactPhoneInLog() {
        XCTAssertEqual(
            Masking.redactPhone(in: "用户13812341234登录失败"),
            "用户1**********登录失败"
        )
    }

    // MARK: - 账号 CRUD

    func testCreateAndList() throws {
        XCTAssertEqual(try accountService.count(), 0)
        let a = try accountService.create(
            platform: .workbuddy, displayName: "测试", phoneMasked: "138****1234"
        )
        XCTAssertEqual(try accountService.count(), 1)
        let list = try accountService.listAll()
        XCTAssertEqual(list.first?.id, a.id)
    }

    func testPlatformFilter() throws {
        _ = try accountService.create(platform: .workbuddy, displayName: "W", phoneMasked: "1")
        _ = try accountService.create(platform: .trae, displayName: "T", phoneMasked: "2")
        XCTAssertEqual(try accountService.list(platform: .workbuddy).count, 1)
        XCTAssertEqual(try accountService.list(platform: .trae).count, 1)
    }

    func testUpdate() throws {
        let a = try accountService.create(
            platform: .trae, displayName: "原名", phoneMasked: "1"
        )
        let updated = try accountService.update(id: a.id, displayName: "新名", note: "备注")
        XCTAssertEqual(updated?.displayName, "新名")
        XCTAssertEqual(updated?.note, "备注")
    }

    func testDeleteCascadesSnapshots() throws {
        let a = try accountService.create(platform: .trae, displayName: "D", phoneMasked: "1")
        try creditService.recordManualEntry(accountId: a.id, credits: 100)
        XCTAssertEqual(try creditService.history(for: a.id).count, 1)
        XCTAssertTrue(try accountService.delete(id: a.id))
        XCTAssertEqual(try accountService.count(), 0)
        XCTAssertEqual(try creditService.history(for: a.id).count, 0, "级联删除快照")
    }

    // MARK: - 积分

    func testManualCreditEntry() throws {
        let a = try accountService.create(platform: .trae, displayName: "C", phoneMasked: "1")
        try creditService.recordManualEntry(accountId: a.id, credits: 1500, totalCredits: 2000, creditType: "会员积分")
        let refreshed = try accountService.get(id: a.id)
        XCTAssertEqual(refreshed?.currentCredits, 1500)
        XCTAssertEqual(refreshed?.totalCredits, 2000)
        XCTAssertEqual(refreshed?.dataStatus, .manual)
        XCTAssertEqual(refreshed?.dataSource, .manualEntry)
    }

    func testQueryFailureNeverWritesZero() throws {
        let a = try accountService.create(platform: .workbuddy, displayName: "F", phoneMasked: "1")
        try creditService.recordManualEntry(accountId: a.id, credits: 500)
        try creditService.recordQueryFailure(accountId: a.id, errorMessage: "timeout")
        let refreshed = try accountService.get(id: a.id)
        XCTAssertEqual(refreshed?.currentCredits, 500, "查询失败不覆盖已有积分")
        XCTAssertEqual(refreshed?.dataStatus, .queryFailed)
    }

    func testCreditHistoryPersists() throws {
        let a = try accountService.create(platform: .trae, displayName: "H", phoneMasked: "1")
        try creditService.recordManualEntry(accountId: a.id, credits: 100)
        try creditService.recordManualEntry(accountId: a.id, credits: 200)
        let history = try creditService.history(for: a.id)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?.credits, 200, "按时间倒序，最新在前")
    }

    // MARK: - 持久化

    func testPersistenceAcrossReopen() throws {
        let tmp = database.databaseURL
        _ = try accountService.create(platform: .trae, displayName: "持久", phoneMasked: "1")
        database.close()

        let reopened = try DatabaseService(databaseURL: tmp)
        let service = AccountService(database: reopened)
        XCTAssertEqual(try service.count(), 1)
        reopened.close()
        // 重新打开原 database 变量以免 tearDown 出错
        database = try DatabaseService(databaseURL: tmp)
        accountService = AccountService(database: database)
    }

    // MARK: - TRAE 会话推断

    func testTraeHasPersistedSession() throws {
        let trae = TraeService()
        let accountId = UUID()
        let dir = trae.traeDataRoot.appendingPathComponent(accountId.uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 目录不存在 → 无会话
        XCTAssertFalse(trae.hasPersistedSession(accountId: accountId))

        // 空目录（仅启动过但未写入数据）→ 无会话
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(trae.hasPersistedSession(accountId: accountId))

        // 目录非空 → 会话已持久化
        FileManager.default.createFile(atPath: dir.appendingPathComponent("state.json").path, contents: Data("{}" .utf8))
        XCTAssertTrue(trae.hasPersistedSession(accountId: accountId))
    }

    // MARK: - 状态语义

    func testLoginStatusLegacyValueMapping() {
        XCTAssertEqual(LoginStatus(storedValue: "logged_in"), .userConfirmed)
        XCTAssertEqual(LoginStatus(storedValue: "user_confirmed"), .userConfirmed)
        XCTAssertEqual(LoginStatus(storedValue: "verified"), .verified)
        XCTAssertEqual(LoginStatus(storedValue: "switch_unconfirmed"), .pendingConfirmation)
        XCTAssertEqual(LoginStatus(storedValue: "logged_out"), .loggedOut)
        XCTAssertEqual(LoginStatus(storedValue: "unexpected"), .unknown)
        XCTAssertFalse(LoginStatus.pendingConfirmation.isConfirmed)
        XCTAssertTrue(LoginStatus.verified.isConfirmed)
    }

    func testLegacyStatusPersistedInDatabaseIsReadable() throws {
        let a = try accountService.create(platform: .workbuddy, displayName: "旧数据", phoneMasked: "1")
        try database.db.execute(
            "UPDATE accounts SET lastLoginStatus = 'logged_in' WHERE id = ?",
            [.string(a.id.uuidString)]
        )
        XCTAssertEqual(try accountService.get(id: a.id)?.lastLoginStatus, .userConfirmed)
    }

    // MARK: - 积分观测时间

    func testManualEntryHonoursObservedAt() throws {
        let a = try accountService.create(platform: .trae, displayName: "观测", phoneMasked: "1")
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try creditService.recordManualEntry(
            accountId: a.id,
            credits: 300,
            observedAt: observed
        )
        XCTAssertEqual(snapshot.queryAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        let refreshed = try accountService.get(id: a.id)
        XCTAssertEqual(
            refreshed?.lastCreditQueryAt?.timeIntervalSince1970 ?? 0,
            1_700_000_000,
            accuracy: 0.001
        )
        XCTAssertEqual(try creditService.history(for: a.id).first?.queryAt, observed)
    }

    func testCreditFreshnessUsesObservationTime() {
        var account = Account(
            platform: .trae,
            displayName: "新鲜度",
            phoneMasked: "1",
            lastCreditQueryAt: Date(timeIntervalSinceNow: -3600),
            currentCredits: 100
        )
        XCTAssertFalse(account.isCreditStale(within: 12 * 3600))
        XCTAssertTrue(account.isCreditStale(within: 1800))

        account.lastCreditQueryAt = nil
        XCTAssertTrue(account.isCreditStale(within: 12 * 3600), "未记录过视为过期")
    }

    func testRecordCounts() throws {
        let a = try accountService.create(platform: .trae, displayName: "计数", phoneMasked: "1")
        let b = try accountService.create(platform: .workbuddy, displayName: "计数2", phoneMasked: "2")
        try creditService.recordManualEntry(accountId: a.id, credits: 100)
        try creditService.recordManualEntry(accountId: a.id, credits: 200)
        try creditService.recordManualEntry(accountId: b.id, credits: 50)

        XCTAssertEqual(try creditService.count(for: a.id), 2)
        XCTAssertEqual(try creditService.countAll(), 3)

        let logService = SwitchLogService(database: database)
        try logService.log(
            accountId: a.id,
            fromStatus: LoginStatus.unknown.rawValue,
            toStatus: LoginStatus.pendingConfirmation.rawValue,
            result: .unconfirmed
        )
        XCTAssertEqual(try logService.count(for: a.id), 1)
        XCTAssertEqual(try logService.countAll(), 1)
        XCTAssertEqual(try logService.count(for: b.id), 0)
    }

    // MARK: - 上次打开的项目

    func testTraeLastWorkspaceParsing() throws {
        let trae = TraeService()
        let accountId = UUID()
        let dir = trae.dataDirPath(for: accountId)
        let globalStorage = dir
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
        let storage = globalStorage.appendingPathComponent("storage.json")
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: workspace)
        }

        // 没有 storage.json → 无记录
        XCTAssertNil(trae.lastWorkspace(for: accountId))

        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)

        // 记录的项目已不存在 → 视为无记录
        try #"{"windowsState":{"lastActiveWindow":{"folder":"file:///tmp/not-exists-aam"}}}"#
            .write(to: storage, atomically: true, encoding: .utf8)
        XCTAssertNil(trae.lastWorkspace(for: accountId))

        // 优先使用 lastActiveWindow 的工作区
        try """
        {"windowsState":{"lastActiveWindow":{"folder":"\(workspace.absoluteString)"}}}
        """.write(to: storage, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            trae.lastWorkspace(for: accountId)?.standardizedFileURL.path,
            workspace.standardizedFileURL.path
        )

        // 缺少 windowsState 时回退到 profileAssociations
        try """
        {"profileAssociations":{"workspaces":{"\(workspace.absoluteString)":"__default__profile__"}}}
        """.write(to: storage, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            trae.lastWorkspace(for: accountId)?.standardizedFileURL.path,
            workspace.standardizedFileURL.path
        )

        // 损坏的 JSON 不应崩溃
        try "{ not json".write(to: storage, atomically: true, encoding: .utf8)
        XCTAssertNil(trae.lastWorkspace(for: accountId))
    }

    // MARK: - 数据一致性

    /// 重新打开数据库后外键仍然生效（旧实现只在建库时开启，导致删除不级联）。
    func testForeignKeysEnabledAfterReopen() throws {
        let url = database.databaseURL
        let a = try accountService.create(platform: .trae, displayName: "级联", phoneMasked: "1")
        try creditService.recordManualEntry(accountId: a.id, credits: 100)
        let logService = SwitchLogService(database: database)
        try logService.log(
            accountId: a.id,
            fromStatus: LoginStatus.unknown.rawValue,
            toStatus: LoginStatus.pendingConfirmation.rawValue,
            result: .unconfirmed
        )

        database.close()

        let reopened = try DatabaseService(databaseURL: url)
        let accounts = AccountService(database: reopened)
        XCTAssertTrue(try accounts.delete(id: a.id))
        XCTAssertEqual(try CreditService(database: reopened).countAll(), 0, "重开后删除仍应级联积分快照")
        XCTAssertEqual(try SwitchLogService(database: reopened).countAll(), 0, "重开后删除仍应级联切换日志")
        reopened.close()

        // 还原 setUp 中的数据库对象，避免 tearDown 出错
        database = try DatabaseService(databaseURL: url)
        accountService = AccountService(database: database)
        creditService = CreditService(database: database)
    }

    /// v2 迁移会清理旧版本遗留的孤儿行。
    func testMigrationCleansOrphanRows() throws {
        let url = database.databaseURL
        let a = try accountService.create(platform: .trae, displayName: "孤儿", phoneMasked: "1")
        let logService = SwitchLogService(database: database)
        try logService.log(
            accountId: a.id,
            fromStatus: LoginStatus.unknown.rawValue,
            toStatus: LoginStatus.pendingConfirmation.rawValue,
            result: .unconfirmed
        )

        // 模拟旧版本行为：关闭外键后直接删账号，留下孤儿日志，并把版本退回 v1
        try database.db.execute("PRAGMA foreign_keys = OFF")
        try database.db.execute("DELETE FROM accounts WHERE id = ?", [.string(a.id.uuidString)])
        XCTAssertEqual(try logService.countAll(), 1)
        try database.db.execute("PRAGMA user_version = 1")
        database.close()

        let migrated = try DatabaseService(databaseURL: url)
        XCTAssertEqual(try SwitchLogService(database: migrated).countAll(), 0, "迁移应清理孤儿行")
        XCTAssertEqual(try migrated.db.scalar("PRAGMA user_version"), DatabaseService.supportedSchemaVersion)
        migrated.close()

        database = try DatabaseService(databaseURL: url)
        accountService = AccountService(database: database)
        creditService = CreditService(database: database)
    }

    /// 录入时留空总额度/类型，不应抹掉账号已有的值。
    func testManualEntryPreservesTotalAndType() throws {
        let a = try accountService.create(platform: .trae, displayName: "保留", phoneMasked: "1")
        try creditService.recordManualEntry(
            accountId: a.id,
            credits: 1500,
            totalCredits: 2000,
            creditType: "会员积分"
        )
        let snapshot = try creditService.recordManualEntry(accountId: a.id, credits: 1200)

        XCTAssertNil(snapshot.totalCredits, "快照只记录本次实际观测到的值")
        let refreshed = try accountService.get(id: a.id)
        XCTAssertEqual(refreshed?.currentCredits, 1200)
        XCTAssertEqual(refreshed?.totalCredits, 2000, "留空不应清空总额度")
        XCTAssertEqual(refreshed?.creditType, "会员积分", "留空不应清空积分类型")
    }

    /// 事务失败必须整体回滚，不能只写一半。
    func testTransactionRollsBackOnError() throws {
        struct Boom: Error {}
        XCTAssertThrowsError(
            try database.db.transaction { tx in
                try tx.execute("""
                INSERT INTO accounts (id, platform, displayName, phoneMasked, createdAt, updatedAt)
                VALUES ('tmp-id', 'trae', '临时', '', 0, 0)
                """)
                throw Boom()
            }
        )
        XCTAssertEqual(try accountService.count(), 0)
    }

    /// 恢复备份前会校验文件，非法文件不得覆盖现有数据。
    func testRestoreRejectsInvalidBackup() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("main.sqlite")
        let db = try DatabaseService(databaseURL: dbURL)
        _ = try AccountService(database: db).create(platform: .trae, displayName: "保留", phoneMasked: "1")

        let bogus = dir.appendingPathComponent("bogus.sqlite")
        try "not a database".write(to: bogus, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try BackupRestore(database: db).restore(from: bogus)) { error in
            guard case BackupRestore.RestoreError.invalidBackup = error else {
                return XCTFail("应拒绝非数据库文件，实际错误：\(error)")
            }
        }
        // 现有数据未被破坏
        XCTAssertEqual(try AccountService(database: db).count(), 1)
        db.close()
    }

    /// 恢复成功时会先自动备份当前数据，并替换为备份内容。
    func testRestoreCreatesSafetyBackupAndRestores() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("main.sqlite")
        var db = try DatabaseService(databaseURL: dbURL)
        let service = AccountService(database: db)
        _ = try service.create(platform: .trae, displayName: "A", phoneMasked: "1")
        let backupURL = try BackupRestore(database: db).backup(to: dir.appendingPathComponent("backups"))

        _ = try service.create(platform: .workbuddy, displayName: "B", phoneMasked: "2")
        XCTAssertEqual(try service.count(), 2)

        let safety = try BackupRestore(database: db).restore(from: backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: safety.path), "应生成恢复前的安全备份")
        XCTAssertTrue(safety.lastPathComponent.hasPrefix("AgentAccountManager-pre-restore-"))

        db = try DatabaseService(databaseURL: dbURL)
        let restored = AccountService(database: db)
        XCTAssertEqual(try restored.count(), 1, "应恢复到备份时的 1 个账号")
        XCTAssertEqual(try restored.listAll().first?.displayName, "A")
        db.close()
    }

    /// 清空数据同时清掉钥匙串中的完整手机号。
    func testWipeClearsDatabaseAndKeychain() throws {
        let service = "com.agentaccountmanager.tests.\(UUID().uuidString)"
        let keychain = KeychainService(service: service)
        defer { keychain.deleteAll() }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("main.sqlite")
        let db = try DatabaseService(databaseURL: dbURL)
        let account = try AccountService(database: db).create(
            platform: .trae, displayName: "清空", phoneMasked: "138****1234"
        )
        guard keychain.setPhone("13812341234", for: account.id) else {
            throw XCTSkip("当前环境无法访问钥匙串，跳过该用例")
        }

        try BackupRestore(database: db, keychain: keychain).deleteAllData()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path), "数据库文件应被删除")
        XCTAssertNil(keychain.phone(for: account.id), "钥匙串中的手机号应被清除")
    }

    // MARK: - 第二批：状态语义与编辑语义

    /// 表单提交完整快照：留空即清空备注与套餐。
    func testUpdateClearsNoteAndPlanType() throws {
        let a = try accountService.create(
            platform: .workbuddy,
            displayName: "清空字段",
            phoneMasked: "1",
            planType: "标准版",
            note: "旧备注"
        )
        XCTAssertEqual(try accountService.get(id: a.id)?.note, "旧备注")

        let updated = try accountService.update(id: a.id, displayName: "清空字段", note: nil, planType: nil)
        XCTAssertNil(updated?.note, "留空应清空备注")
        XCTAssertNil(updated?.planType, "留空应清空套餐")
        XCTAssertEqual(updated?.displayName, "清空字段", "名称仍会保存")
    }

    /// 切换后的状态必须与证据一致。
    func testResolveStatusMatrix() {
        // 失败或未启动：保持原状态
        XCTAssertEqual(
            SwitchService.resolveStatus(
                current: .userConfirmed, platform: .workbuddy,
                launched: false, failed: true, identityVerified: false, hasPersistedSession: false
            ),
            .userConfirmed
        )

        // 本次通过官方手段验证：写已验证
        XCTAssertEqual(
            SwitchService.resolveStatus(
                current: .pendingConfirmation, platform: .trae,
                launched: true, failed: false, identityVerified: true, hasPersistedSession: true
            ),
            .verified
        )

        // 上次已验证、本次没验证：降级为人工确认，避免沿用旧证据
        XCTAssertEqual(
            SwitchService.resolveStatus(
                current: .verified, platform: .trae,
                launched: true, failed: false, identityVerified: false, hasPersistedSession: true
            ),
            .userConfirmed
        )

        // WorkBuddy 已人工确认：保留确认结果（本次未核对会记入切换日志）
        XCTAssertEqual(
            SwitchService.resolveStatus(
                current: .userConfirmed, platform: .workbuddy,
                launched: true, failed: false, identityVerified: false, hasPersistedSession: false
            ),
            .userConfirmed
        )

        // TRAE 已确认但隔离目录没有会话：需要重新核对
        XCTAssertEqual(
            SwitchService.resolveStatus(
                current: .userConfirmed, platform: .trae,
                launched: true, failed: false, identityVerified: false, hasPersistedSession: false
            ),
            .pendingConfirmation
        )

        // TRAE 已确认且有持久化会话：保留确认结果
        XCTAssertEqual(
            SwitchService.resolveStatus(
                current: .userConfirmed, platform: .trae,
                launched: true, failed: false, identityVerified: false, hasPersistedSession: true
            ),
            .userConfirmed
        )

        // 从未确认过：等待核对
        XCTAssertEqual(
            SwitchService.resolveStatus(
                current: .unknown, platform: .trae,
                launched: true, failed: false, identityVerified: false, hasPersistedSession: true
            ),
            .pendingConfirmation
        )
    }

    /// 命令超时会被终止，不会把切换流程卡死。
    func testProcessRunTimesOut() {
        let process = ProcessService()
        let started = Date()
        let (code, _, stderr) = process.run(launchPath: "/bin/sleep", arguments: ["3"], timeout: 0.3)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(code, -2, "超时应返回 -2")
        XCTAssertLessThan(elapsed, 2.5, "应在超时后立即返回")
        XCTAssertTrue(stderr.contains("超时") || stderr.contains("已终止"), "stderr 应说明超时原因：\(stderr)")
    }

    /// 输出超过管道缓冲区时仍能完整读取，不会因先 wait 后 read 而互相阻塞。
    func testProcessRunHandlesLargeOutput() {
        let process = ProcessService()
        let (code, stdout, _) = process.run(
            launchPath: "/bin/sh",
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' x"],
            timeout: 5
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(stdout.count, 200_000)
    }

    /// 已安装应用时，路径解析应能找到实际位置（未安装则跳过）。
    func testInstalledApplicationResolution() throws {
        guard let url = Platform.trae.installedApplicationURL else {
            throw XCTSkip("本机未安装 TRAE，跳过路径解析用例")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(Platform.trae.isInstalled)
        // 默认初始化的命令行路径应位于该应用包内
        let service = TraeService()
        XCTAssertTrue(
            service.cliPath.contains(url.lastPathComponent) || FileManager.default.isExecutableFile(atPath: service.cliPath)
        )
    }

    /// 按 `--user-data-dir` 解析出正在运行的账号实例，默认配置目录与无关进程不误判。
    func testParseRunningIsolatedInstances() {
        let id1 = UUID()
        let id2 = UUID()
        let root = "/Users/example/Library/Application Support/AgentAccountManager/TraeUserData"
        let output = """
        /Applications/Trae CN.app/Contents/MacOS/Electron --user-data-dir \(root)/\(id1.uuidString)
        /Applications/Trae CN.app/Contents/Frameworks/Trae CN Helper (Renderer).app/Contents/MacOS/Trae CN Helper (Renderer) --type=renderer --user-data-dir=\(root)/\(id1.uuidString) --lang=zh-CN
        /Applications/Trae CN.app/Contents/MacOS/Electron --user-data-dir \(root)/\(id2.uuidString) /Users/example/some-project
        /Applications/Trae CN.app/Contents/Frameworks/Trae CN Helper.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler --user-data-dir=/Users/example/Library/Application Support/Trae CN
        /Applications/Trae CN.app/Contents/MacOS/Electron
        /Applications/Other.app/Contents/MacOS/Other --user-data-dir \(root)XX/\(UUID().uuidString)
        """

        let ids = TraeService.parseIsolatedAccountIds(fromProcessList: output, root: root)
        XCTAssertEqual(ids, [id1, id2], "只应识别本应用隔离目录下的账号实例")

        // 根路径带结尾斜杠时也应正常工作
        XCTAssertEqual(
            TraeService.parseIsolatedAccountIds(fromProcessList: output, root: root + "/"),
            [id1, id2]
        )
        // 没有 TRAE 进程时返回空集合
        XCTAssertTrue(
            TraeService.parseIsolatedAccountIds(fromProcessList: "", root: root).isEmpty
        )
    }

    /// 运行中实例的当前工作区：取 workspaceStorage 里最近更新的有效记录。
    func testTraeCurrentWorkspaceParsing() throws {
        let trae = TraeService()
        let accountId = UUID()
        let dir = trae.dataDirPath(for: accountId)
        let storageRoot = dir
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("workspaceStorage", isDirectory: true)

        let wsA = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-A-\(UUID().uuidString)", isDirectory: true)
        let wsB = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-B-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: wsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: wsA)
            try? FileManager.default.removeItem(at: wsB)
        }

        // 没有任何 workspaceStorage 记录
        XCTAssertNil(trae.currentWorkspace(for: accountId))

        func writeEntry(_ name: String, workspace: URL, modified: Date) throws {
            let entry = storageRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            let file = entry.appendingPathComponent("workspace.json")
            try #"{"folder":"\#(workspace.absoluteString)"}"#
                .write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }

        let older = Date(timeIntervalSince1970: 1_700_000_000)
        try writeEntry("aaa", workspace: wsA, modified: older)
        try writeEntry("bbb", workspace: wsB, modified: older.addingTimeInterval(600))

        XCTAssertEqual(
            trae.currentWorkspace(for: accountId)?.standardizedFileURL.path,
            wsB.standardizedFileURL.path,
            "应取最近更新的工作区记录"
        )

        // 最新记录指向的目录已被删除 → 回退到仍存在的那条
        try FileManager.default.removeItem(at: wsB)
        XCTAssertEqual(
            trae.currentWorkspace(for: accountId)?.standardizedFileURL.path,
            wsA.standardizedFileURL.path
        )

        // 记录损坏不应崩溃
        let broken = storageRoot.appendingPathComponent("ccc", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "{ not json".write(
            to: broken.appendingPathComponent("workspace.json"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            trae.currentWorkspace(for: accountId)?.standardizedFileURL.path,
            wsA.standardizedFileURL.path
        )
    }

    /// 同一账号打开多个窗口时，应列出全部项目（最近活跃在前、去重、过滤失效路径）。
    func testTraeOpenWorkspacesListsAllWindows() throws {
        let trae = TraeService()
        let accountId = UUID()
        let dir = trae.dataDirPath(for: accountId)
        let globalStorage = dir
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
        let storage = globalStorage.appendingPathComponent("storage.json")

        let wsA = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-open-A-\(UUID().uuidString)", isDirectory: true)
        let wsB = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-open-B-\(UUID().uuidString)", isDirectory: true)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-open-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: wsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: wsA)
            try? FileManager.default.removeItem(at: wsB)
        }

        // 没有 storage.json，也没有 workspaceStorage → 空
        XCTAssertTrue(trae.openWorkspaces(for: accountId).isEmpty)

        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)
        try """
        {"windowsState":{
          "lastActiveWindow":{"folder":"\(wsB.absoluteString)"},
          "openedWindows":[
            {"folder":"\(wsA.absoluteString)"},
            {"folder":"\(wsB.absoluteString)"},
            {"folder":"\(missing.absoluteString)"}
          ]
        }}
        """.write(to: storage, atomically: true, encoding: .utf8)

        let open = trae.openWorkspaces(for: accountId).map(\.standardizedFileURL.path)
        XCTAssertEqual(
            open,
            [wsB.standardizedFileURL.path, wsA.standardizedFileURL.path],
            "应列出全部仍存在的窗口，最近活跃的排最前，且不重复"
        )

        // storage.json 缺失时回退到 workspaceStorage 的最新一条
        try FileManager.default.removeItem(at: storage)
        let entry = dir
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("workspaceStorage", isDirectory: true)
            .appendingPathComponent("hash-a", isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try #"{"folder":"\#(wsA.absoluteString)"}"#
            .write(to: entry.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            trae.openWorkspaces(for: accountId).map(\.standardizedFileURL.path),
            [wsA.standardizedFileURL.path],
            "没有窗口列表时应回退到最近的 workspaceStorage 记录"
        )
    }

    // MARK: - 手机号更新

    func testUpdatePhoneKeepsOnlyMaskedValue() throws {
        let a = try accountService.create(platform: .workbuddy, displayName: "换号", phoneMasked: "")
        XCTAssertEqual(a.phoneMasked, "")

        let updated = try accountService.updatePhone(
            id: a.id,
            phoneMasked: Masking.maskPhone("13900001111"),
            phoneHash: Masking.phoneHash("13900001111")
        )
        XCTAssertEqual(updated?.phoneMasked, "139****1111")
        XCTAssertEqual(updated?.phoneHash, Masking.phoneHash("13900001111"))
        XCTAssertEqual(updated?.phoneDisplay, "139****1111")
    }

    // MARK: - 切换事务

    func testSwitchFailsFastWhenClientMissingAndKeepsStatus() throws {
        let logService = SwitchLogService(database: database)
        let service = SwitchService(
            accountService: accountService,
            switchLogService: logService,
            workbuddy: WorkBuddyService(appPath: "/tmp/missing-WorkBuddy.app"),
            trae: TraeService(cliPath: "/tmp/missing-trae-cn", appBundlePath: "/tmp/missing-Trae.app")
        )

        let workbuddyAccount = try accountService.create(
            platform: .workbuddy, displayName: "缺失W", phoneMasked: "1"
        )
        let traeAccount = try accountService.create(
            platform: .trae, displayName: "缺失T", phoneMasked: "2"
        )

        XCTAssertNotNil(service.installProblem(for: .workbuddy))
        XCTAssertNotNil(service.installProblem(for: .trae))

        let outcome = service.switchTo(account: workbuddyAccount)
        XCTAssertEqual(outcome.result, .failed)
        XCTAssertFalse(outcome.launched, "未启动客户端时不得声称已启动")
        XCTAssertFalse(outcome.identityVerified)
        XCTAssertNotNil(outcome.failureAdvice)

        let traeOutcome = service.switchTo(account: traeAccount)
        XCTAssertEqual(traeOutcome.result, .failed)
        XCTAssertFalse(traeOutcome.identityVerified)

        // 失败不得把账号标记为已登录
        XCTAssertEqual(try accountService.get(id: workbuddyAccount.id)?.lastLoginStatus, .unknown)
        XCTAssertEqual(try accountService.get(id: traeAccount.id)?.lastLoginStatus, .unknown)

        // 每次尝试都留下切换日志
        XCTAssertEqual(try logService.count(for: workbuddyAccount.id), 1)
        XCTAssertEqual(try logService.count(for: traeAccount.id), 1)
    }

    func testUserConfirmationMarksAccountConfirmed() throws {
        let logService = SwitchLogService(database: database)
        let service = SwitchService(
            accountService: accountService,
            switchLogService: logService,
            workbuddy: WorkBuddyService(appPath: "/tmp/missing-WorkBuddy.app"),
            trae: TraeService(cliPath: "/tmp/missing-trae-cn", appBundlePath: "/tmp/missing-Trae.app")
        )
        let account = try accountService.create(
            platform: .workbuddy, displayName: "确认", phoneMasked: "1"
        )
        service.confirmLogin(account: account)
        let refreshed = try accountService.get(id: account.id)
        XCTAssertEqual(refreshed?.lastLoginStatus, .userConfirmed)
        XCTAssertFalse(refreshed?.lastLoginStatus == .verified, "用户确认不等于技术验证")
    }

    // MARK: - 第三批：最近使用、分页、查重、v3 迁移

    /// 切换成功后记录最近使用时间，列表按最近使用排序。
    func testMarkUsedAndListOrdering() throws {
        let older = try accountService.create(platform: .workbuddy, displayName: "旧", phoneMasked: "1")
        // 保证创建时间有先后
        Thread.sleep(forTimeInterval: 0.01)
        let newer = try accountService.create(platform: .trae, displayName: "新", phoneMasked: "2")

        // 都未使用：按平台+创建时间
        var list = try accountService.listAll()
        XCTAssertEqual(list.map(\.id), [newer.id, older.id], "未使用时 trae 排在 workbuddy 前")

        // 标记 older 最近使用后排最前
        _ = try accountService.markUsed(id: older.id)
        list = try accountService.listAll()
        XCTAssertEqual(list.first?.id, older.id, "最近使用的账号排最前")
        XCTAssertNotNil(try accountService.get(id: older.id)?.lastUsedAt)
        XCTAssertNil(try accountService.get(id: newer.id)?.lastUsedAt)

        // newer 更新更近后反超
        Thread.sleep(forTimeInterval: 0.01)
        _ = try accountService.markUsed(id: newer.id)
        list = try accountService.listAll()
        XCTAssertEqual(list.first?.id, newer.id)
    }

    /// 历史查询分页：LIMIT/OFFSET 返回正确切片。
    func testHistoryPagination() throws {
        let a = try accountService.create(platform: .trae, displayName: "分页", phoneMasked: "1")
        for i in 1...5 {
            try creditService.recordManualEntry(
                accountId: a.id,
                credits: i * 100,
                observedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            )
        }
        let page1 = try creditService.history(for: a.id, limit: 2, offset: 0)
        XCTAssertEqual(page1.map(\.credits), [500, 400], "第一页是最新两条")
        let page2 = try creditService.history(for: a.id, limit: 2, offset: 2)
        XCTAssertEqual(page2.map(\.credits), [300, 200])
        let page3 = try creditService.history(for: a.id, limit: 2, offset: 4)
        XCTAssertEqual(page3.map(\.credits), [100])
        XCTAssertEqual(try creditService.count(for: a.id), 5)

        let logService = SwitchLogService(database: database)
        for i in 1...3 {
            try logService.log(
                accountId: a.id,
                fromStatus: "s\(i)", toStatus: "t\(i)", result: .unconfirmed
            )
        }
        XCTAssertEqual(try logService.history(for: a.id, limit: 2, offset: 0).count, 2)
        XCTAssertEqual(try logService.history(for: a.id, limit: 2, offset: 2).count, 1)
        XCTAssertEqual(try logService.count(for: a.id), 3)
    }

    /// 手机号摘要查重。
    func testFindByPhoneHash() throws {
        let phone = "13812341234"
        let a = try accountService.create(
            platform: .workbuddy,
            displayName: "查重",
            phoneMasked: Masking.maskPhone(phone),
            phoneHash: Masking.phoneHash(phone)
        )
        _ = try accountService.create(platform: .trae, displayName: "无关", phoneMasked: "139****0000")

        let matches = try accountService.find(byPhoneHash: Masking.phoneHash(phone))
        XCTAssertEqual(matches.map(\.id), [a.id])
        XCTAssertEqual(try accountService.find(byPhoneHash: Masking.phoneHash("13700000000")).count, 0)
    }

    /// v2 → v3 迁移：creditResetAt 列被移除、lastUsedAt 出现、旧数据完整保留。
    func testMigrationToV3DropsCreditResetAtAndKeepsData() throws {
        let url = database.databaseURL
        database.close()
        // setUp 已用当前代码在该路径建过 v3 库，删掉后手工构造 v2 时代的库
        try FileManager.default.removeItem(at: url)

        // 手工构造一个 v2 时代的数据库（accounts 含 creditResetAt、无 lastUsedAt）
        let raw = try SQLiteDatabase(path: url.path)
        try raw.execute("""
        CREATE TABLE accounts (
            id TEXT PRIMARY KEY NOT NULL,
            platform TEXT NOT NULL,
            displayName TEXT NOT NULL,
            phoneMasked TEXT NOT NULL,
            phoneHash TEXT,
            planType TEXT,
            note TEXT,
            lastLoginStatus TEXT NOT NULL DEFAULT 'unknown',
            lastCreditQueryAt REAL,
            currentCredits INTEGER,
            totalCredits INTEGER,
            creditType TEXT,
            creditResetAt REAL,
            dataSource TEXT NOT NULL DEFAULT 'manual_entry',
            dataStatus TEXT NOT NULL DEFAULT 'manual',
            traeUserDataDir TEXT,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        )
        """)
        try raw.execute("""
        CREATE TABLE credit_snapshots (
            id TEXT PRIMARY KEY NOT NULL,
            accountId TEXT NOT NULL,
            credits INTEGER,
            totalCredits INTEGER,
            queryAt REAL NOT NULL,
            source TEXT NOT NULL,
            status TEXT NOT NULL,
            errorMessage TEXT,
            FOREIGN KEY (accountId) REFERENCES accounts(id) ON DELETE CASCADE
        )
        """)
        try raw.execute("""
        CREATE TABLE switch_logs (
            id TEXT PRIMARY KEY NOT NULL,
            accountId TEXT NOT NULL,
            fromStatus TEXT NOT NULL,
            toStatus TEXT NOT NULL,
            result TEXT NOT NULL,
            errorMessage TEXT,
            createdAt REAL NOT NULL,
            FOREIGN KEY (accountId) REFERENCES accounts(id) ON DELETE CASCADE
        )
        """)
        let accountId = UUID().uuidString
        try raw.execute(
            """
            INSERT INTO accounts (id, platform, displayName, phoneMasked, creditResetAt, createdAt, updatedAt)
            VALUES (?, 'trae', '旧账号', '138****1234', 1700000000, 1699999000, 1699999000)
            """,
            [.string(accountId)]
        )
        try raw.execute("PRAGMA user_version = 2")
        raw.close()

        // 打开即触发迁移
        let migrated = try DatabaseService(databaseURL: url)
        XCTAssertEqual(try migrated.db.scalar("PRAGMA user_version"), DatabaseService.supportedSchemaVersion)

        let columns = try migrated.db.query("PRAGMA table_info(accounts)") { row in
            row.string(at: 1) ?? ""
        }
        XCTAssertFalse(columns.contains("creditResetAt"), "死字段列应被移除")
        XCTAssertTrue(columns.contains("lastUsedAt"), "应新增 lastUsedAt 列")

        // 旧数据完整保留
        let service = AccountService(database: migrated)
        let kept = try service.get(id: UUID(uuidString: accountId)!)
        XCTAssertEqual(kept?.displayName, "旧账号")
        XCTAssertEqual(kept?.platform, .trae)
        XCTAssertNil(kept?.lastUsedAt)
        migrated.close()

        // 还原 setUp 中的数据库对象，避免 tearDown 出错
        database = try DatabaseService(databaseURL: url)
        accountService = AccountService(database: database)
        creditService = CreditService(database: database)
    }

    /// v4：用历史切换日志回填 lastUsedAt（旧版本不记录该字段）。
    func testMigrationV4BackfillsLastUsedAt() throws {
        let url = database.databaseURL
        let a = try accountService.create(platform: .trae, displayName: "有记录", phoneMasked: "1")
        let b = try accountService.create(platform: .trae, displayName: "仅失败", phoneMasked: "2")

        func insertLog(account: UUID, result: String, at seconds: Double) throws {
            try database.db.execute(
                """
                INSERT INTO switch_logs
                (id, accountId, fromStatus, toStatus, result, errorMessage, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .string(UUID().uuidString),
                    .string(account.uuidString),
                    .string(LoginStatus.unknown.rawValue),
                    .string(LoginStatus.pendingConfirmation.rawValue),
                    .string(result),
                    .null,
                    .double(seconds)
                ]
            )
        }
        try insertLog(account: a.id, result: "success", at: 1_700_000_100)
        try insertLog(account: a.id, result: "unconfirmed", at: 1_700_000_200)
        try insertLog(account: a.id, result: "failed", at: 1_700_000_500)
        try insertLog(account: b.id, result: "failed", at: 1_700_000_300)

        // 模拟 v3 状态：字段存在但没有值
        try database.db.execute("UPDATE accounts SET lastUsedAt = NULL")
        try database.db.execute("PRAGMA user_version = 3")
        database.close()

        let migrated = try DatabaseService(databaseURL: url)
        XCTAssertEqual(
            try migrated.db.scalar("PRAGMA user_version"),
            DatabaseService.supportedSchemaVersion
        )
        let service = AccountService(database: migrated)
        XCTAssertEqual(
            try service.get(id: a.id)?.lastUsedAt?.timeIntervalSince1970 ?? 0,
            1_700_000_200,
            accuracy: 0.001,
            "应回填最近一次成功启动的时间，失败记录不参与"
        )
        XCTAssertNil(try service.get(id: b.id)?.lastUsedAt, "只有失败记录不应回填")
        migrated.close()

        database = try DatabaseService(databaseURL: url)
        accountService = AccountService(database: database)
        creditService = CreditService(database: database)
    }

    /// 备份/恢复后 lastUsedAt 不丢失。
    func testBackupRestorePreservesLastUsedAt() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("main.sqlite")
        var db = try DatabaseService(databaseURL: dbURL)
        let service = AccountService(database: db)
        let a = try service.create(platform: .trae, displayName: "回环", phoneMasked: "1")
        let usedAt = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try service.markUsed(id: a.id, at: usedAt)
        let backupURL = try BackupRestore(database: db).backup(to: dir.appendingPathComponent("backups"))
        _ = try service.create(platform: .workbuddy, displayName: "多余", phoneMasked: "2")

        _ = try BackupRestore(database: db).restore(from: backupURL)
        db = try DatabaseService(databaseURL: dbURL)
        let restored = try AccountService(database: db).get(id: a.id)
        XCTAssertEqual(
            restored?.lastUsedAt?.timeIntervalSince1970 ?? 0,
            usedAt.timeIntervalSince1970,
            accuracy: 0.001,
            "恢复后最近使用时间应保留"
        )
        db.close()
    }
}
