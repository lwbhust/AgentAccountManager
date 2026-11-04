import XCTest
import Core

final class TraeTaskTests: XCTestCase {
    var database: DatabaseService!
    var accountService: AccountService!
    var taskService: TraeTaskService!

    /// 采集器只回看最近 7 天的日志轮次。测试目录名必须相对当前时间生成，
    /// 否则固定日期会随真实时间推移滑出采集窗口，导致用例失效。
    private static let roundFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()

    private func roundName(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return Self.roundFormatter.string(from: date)
    }

    override func setUpWithError() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trae-task-test-\(UUID().uuidString).sqlite")
        database = try DatabaseService(databaseURL: tmp)
        accountService = AccountService(database: database)
        taskService = TraeTaskService(database: database)
    }

    override func tearDownWithError() throws {
        let url = database.databaseURL
        database.close()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 日志解析

    func testParseMetadataUsesFirstLineOnly() throws {
        let accountId = UUID()
        let line = """
        2026-10-25T15:44:27.252+08:00 [info] [ai-chat/v2] [MetadataHandler] received metadata {"session_id":"s1","message_id":"m1","message_type":"task","status":"in_progress","agent_name":"SOLO Agent","created_at":1792915776,"user_message_context":{"model_info":{"display_model_name":"DeepSeek-V4.1-Flash"},"query":[{"type":"text","data":{"content":"第一行任务\\n第二行不应保存"}}]}}
        """

        let event = TraeTaskParser.parse(line: line[...], accountId: accountId)
        XCTAssertEqual(event?.accountId, accountId)
        XCTAssertEqual(event?.messageId, "m1")
        XCTAssertEqual(event?.sessionId, "s1")
        XCTAssertEqual(event?.title, "第一行任务")
        XCTAssertEqual(event?.status, "in_progress")
        XCTAssertEqual(event?.agentName, "SOLO Agent")
        XCTAssertEqual(event?.modelName, "DeepSeek-V4.1-Flash")
        XCTAssertEqual(event?.date, Date(timeIntervalSince1970: 1792915776))
    }

    func testParseUsageCredits() throws {
        let line = """
        2026-10-25T15:44:30.000+08:00 [info] [ai-chat][ai-chat][☕] event:  cn_session_usage_tail ; params:  {"action":"show","session_id":"s1","user_message_id":"u1","agent_message_id":"m1","usage_summary":"4.06"}
        """

        let event = TraeTaskParser.parse(line: line[...], accountId: UUID())
        XCTAssertEqual(event?.messageId, "m1")
        XCTAssertEqual(event?.credits ?? 0, 4.06, accuracy: 0.0001)
        XCTAssertNil(event?.title, "用量日志里不应有用户输入内容")
    }

    func testParseDoneStatus() throws {
        let line = """
        2026-10-25T15:44:35.000+08:00 [info] [ai-chat/v2] [DoneHandler] Stream done event received {"sessionId":"s1","status":"completed","agentMessageId":"m1"}
        """

        let event = TraeTaskParser.parse(line: line[...], accountId: UUID())
        XCTAssertEqual(event?.messageId, "m1")
        XCTAssertEqual(event?.status, "completed")
    }

    func testParseTitleFromSerializedQueryString() {
        let line = #"""
        2026-10-25T15:44:27.252+08:00 [info] [ai-chat/v2] [MetadataHandler] received metadata {"session_id":"s1","message_id":"m3","message_type":"task","status":"completed","user_message_context":{"query":"[{\"type\":\"text\",\"data\":{\"content\":\"请生成一份测试报告\"}}]"}}
        """#

        let event = TraeTaskParser.parse(line: line[...], accountId: UUID())
        XCTAssertEqual(event?.title, "请生成一份测试报告")
    }

    func testParseSlashCommandFallsBackToCommandName() {
        let line = #"""
        2026-10-25T15:44:27.252+08:00 [info] [ai-chat/v2] [MetadataHandler] received metadata {"session_id":"s1","message_id":"m4","message_type":"task","status":"completed","user_message_context":{"query":"[{\"type\":\"slash_command\",\"data\":{\"display_name\":\"电脑控制\",\"command\":\"computer-use\"}}]"}}
        """#

        let event = TraeTaskParser.parse(line: line[...], accountId: UUID())
        XCTAssertEqual(event?.title, "电脑控制")
    }

    func testParseConversationSelectionUsesComment() {
        let line = #"""
        2026-10-25T15:44:27.252+08:00 [info] [ai-chat/v2] [MetadataHandler] received metadata {"session_id":"s1","message_id":"m5","message_type":"task","status":"completed","user_message_context":{"query":"[{\"type\":\"conversation_selection\",\"data\":{\"text\":\"按钮说明\",\"comment\":\"能不能优化合并一下这三个按钮\"}}]"}}
        """#

        let event = TraeTaskParser.parse(line: line[...], accountId: UUID())
        XCTAssertEqual(event?.title, "能不能优化合并一下这三个按钮")
    }

    func testParseIgnoresUnrelatedLines() {
        XCTAssertNil(TraeTaskParser.parse(line: "2026-10-25T15:44:35.000+08:00 [info] 普通日志"[...], accountId: UUID()))
        XCTAssertNil(TraeTaskParser.parse(
            line: #"2026-10-25T15:44:35.000+08:00 [info] [MetadataHandler] received metadata {"message_type":"welcome"}"#[...],
            accountId: UUID()
        ))
    }

    // MARK: - 合并写入

    func testUpsertMergesEventsAndSkipsDuplicates() throws {
        let account = try accountService.create(
            platform: .trae, displayName: "TRAE 账号", phoneMasked: "138****0000"
        )
        let metadata = TraeTaskEvent(
            accountId: account.id,
            messageId: "m1",
            sessionId: "s1",
            title: "把空白窗口改为仅激活",
            status: "in_progress",
            agentName: "SOLO Agent",
            modelName: "DeepSeek-V4.1-Flash",
            date: Date(timeIntervalSince1970: 1792915776)
        )
        let usage = TraeTaskEvent(
            accountId: account.id,
            messageId: "m1",
            sessionId: "s1",
            credits: 4.06,
            date: Date(timeIntervalSince1970: 1792915790)
        )

        XCTAssertEqual(try taskService.upsert([metadata]), 1)
        XCTAssertEqual(try taskService.upsert([usage]), 1)
        XCTAssertEqual(try taskService.upsert([usage]), 0, "重复日志不应产生写入")

        let tasks = try taskService.history(for: account.id)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "把空白窗口改为仅激活")
        XCTAssertEqual(tasks.first?.credits ?? 0, 4.06, accuracy: 0.0001)
        XCTAssertEqual(tasks.first?.status, .inProgress)

        let done = TraeTaskEvent(
            accountId: account.id,
            messageId: "m1",
            sessionId: "s1",
            status: "completed",
            date: Date(timeIntervalSince1970: 1792915856)
        )
        XCTAssertEqual(try taskService.upsert([done]), 1)
        XCTAssertEqual(try taskService.history(for: account.id).first?.status, .completed)
        XCTAssertEqual(try taskService.creditsConsumed(for: account.id, since: .distantPast) ?? 0, 4.06, accuracy: 0.0001)
    }

    func testCanceledStatusIsNormalized() throws {
        let account = try accountService.create(
            platform: .trae, displayName: "TRAE 账号", phoneMasked: "138****0000"
        )
        let event = TraeTaskEvent(
            accountId: account.id,
            messageId: "m6",
            sessionId: "s1",
            status: "canceled",
            date: Date()
        )
        _ = try taskService.upsert([event])
        XCTAssertEqual(try taskService.history(for: account.id).first?.status, .interrupted)
    }

    func testDeletingAccountCascadesTasks() throws {
        let account = try accountService.create(
            platform: .trae, displayName: "TRAE 账号", phoneMasked: "138****0000"
        )
        let event = TraeTaskEvent(
            accountId: account.id,
            messageId: "m2",
            sessionId: "s1",
            title: "任务",
            credits: 1.5,
            date: Date()
        )
        _ = try taskService.upsert([event])
        XCTAssertEqual(try taskService.countAll(), 1)

        try accountService.delete(id: account.id)
        XCTAssertEqual(try taskService.countAll(), 0)
    }

    // MARK: - 增量读取

    func testScannerReadsOnlyAppendedLines() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trae-scan-\(UUID().uuidString)", isDirectory: true)
        let accountId = UUID()
        let windowDir = root
            .appendingPathComponent(accountId.uuidString, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(roundName(daysAgo: 0), isDirectory: true)
            .appendingPathComponent("window1", isDirectory: true)
        try FileManager.default.createDirectory(at: windowDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = windowDir.appendingPathComponent("renderer.log")
        let metadata = """
        2026-10-25T15:44:27.252+08:00 [info] [ai-chat/v2] [MetadataHandler] received metadata {"session_id":"s1","message_id":"m1","message_type":"task","status":"in_progress","created_at":1792915776,"user_message_context":{"query":[{"type":"text","data":{"content":"任务一"}}]}}

        """
        try metadata.write(to: logURL, atomically: true, encoding: .utf8)

        let scanner = TraeTaskScanner(root: root)
        let first = await scanner.scan(accountIds: [accountId])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.title, "任务一")

        let usage = """
        2026-10-25T15:44:30.000+08:00 [info] [ai-chat][ai-chat][☕] event:  cn_session_usage_tail ; params:  {"action":"show","session_id":"s1","user_message_id":"u1","agent_message_id":"m1","usage_summary":"2.5"}

        """
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(usage.utf8))
        try handle.close()

        let second = await scanner.scan(accountIds: [accountId])
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.credits ?? 0, 2.5, accuracy: 0.0001)

        let third = await scanner.scan(accountIds: [accountId])
        XCTAssertTrue(third.isEmpty, "没有新日志时不重复解析")
    }

    func testScannerPersistsOffsetsAcrossRestart() async throws {
        let suite = "trae-scan-state-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trae-scan-\(UUID().uuidString)", isDirectory: true)
        let accountId = UUID()
        let windowDir = root
            .appendingPathComponent(accountId.uuidString, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(roundName(daysAgo: 0), isDirectory: true)
            .appendingPathComponent("window1", isDirectory: true)
        try FileManager.default.createDirectory(at: windowDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = windowDir.appendingPathComponent("renderer.log")
        let metadata = """
        2026-10-25T15:44:27.252+08:00 [info] [ai-chat/v2] [MetadataHandler] received metadata {"session_id":"s1","message_id":"m1","message_type":"task","status":"in_progress","created_at":1792915776,"user_message_context":{"query":[{"type":"text","data":{"content":"任务一"}}]}}

        """
        try metadata.write(to: logURL, atomically: true, encoding: .utf8)

        let firstScanner = TraeTaskScanner(root: root, defaults: defaults)
        let first = await firstScanner.scan(accountIds: [accountId])
        XCTAssertEqual(first.count, 1)

        // 模拟应用重启：新的 scanner 必须从上次偏移继续，而不是重读整个日志
        let restarted = TraeTaskScanner(root: root, defaults: defaults)
        let afterRestart = await restarted.scanDetailed(accountIds: [accountId])
        XCTAssertTrue(afterRestart.events.isEmpty, "重启后不应重复解析已读日志")
        XCTAssertEqual(afterRestart.diagnostics[accountId]?.newEventCount, 0)

        let usage = """
        2026-10-25T15:44:30.000+08:00 [info] [ai-chat][ai-chat][☕] event:  cn_session_usage_tail ; params:  {"action":"show","session_id":"s1","user_message_id":"u1","agent_message_id":"m1","usage_summary":"2.5"}

        """
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(usage.utf8))
        try handle.close()

        let appended = await restarted.scan(accountIds: [accountId])
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended.first?.credits ?? 0, 2.5, accuracy: 0.0001)
    }

    func testScannerBackfillsPreviousRound() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trae-scan-\(UUID().uuidString)", isDirectory: true)
        let accountId = UUID()
        defer { try? FileManager.default.removeItem(at: root) }

        let logsDir = root
            .appendingPathComponent(accountId.uuidString, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)

        // 较旧一轮有新任务，最新一轮没有：只扫最新轮会漏掉旧任务
        let olderWindow = logsDir
            .appendingPathComponent(roundName(daysAgo: 2), isDirectory: true)
            .appendingPathComponent("window1", isDirectory: true)
        let newerWindow = logsDir
            .appendingPathComponent(roundName(daysAgo: 0), isDirectory: true)
            .appendingPathComponent("window1", isDirectory: true)
        try FileManager.default.createDirectory(at: olderWindow, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newerWindow, withIntermediateDirectories: true)

        let olderLine = """
        2026-10-25T09:00:10.000+08:00 [info] [ai-chat/v2] [MetadataHandler] received metadata {"session_id":"s1","message_id":"m-old","message_type":"task","status":"completed","created_at":1792890010,"user_message_context":{"query":[{"type":"text","data":{"content":"旧一轮任务"}}]}}

        """
        try olderLine.write(
            to: olderWindow.appendingPathComponent("renderer.log"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: newerWindow.appendingPathComponent("renderer.log"),
            atomically: true,
            encoding: .utf8
        )

        let report = await TraeTaskScanner(root: root).scanDetailed(accountIds: [accountId])
        XCTAssertEqual(report.events.map(\.messageId), ["m-old"])
        XCTAssertEqual(report.diagnostics[accountId]?.roundsScanned, 2)
    }

    func testScannerReportsSuspectedFormatIssues() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trae-scan-\(UUID().uuidString)", isDirectory: true)
        let accountId = UUID()
        let windowDir = root
            .appendingPathComponent(accountId.uuidString, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(roundName(daysAgo: 0), isDirectory: true)
            .appendingPathComponent("window1", isDirectory: true)
        try FileManager.default.createDirectory(at: windowDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 有已识别标记但字段缺失：应计入「疑似格式变化」而不是静默忽略
        let broken = """
        2026-10-25T15:44:27.252+08:00 [info] [ai-chat/v2] [MetadataHandler] received metadata {"message_type":"task"}

        """
        try broken.write(
            to: windowDir.appendingPathComponent("renderer.log"),
            atomically: true,
            encoding: .utf8
        )

        let report = await TraeTaskScanner(root: root).scanDetailed(accountIds: [accountId])
        XCTAssertTrue(report.events.isEmpty)
        XCTAssertEqual(report.diagnostics[accountId]?.suspectedFormatIssues, 1)
        XCTAssertEqual(report.diagnostics[accountId]?.hasIssue, true)
    }

    func testScannerWaitsForCompleteLine() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trae-scan-\(UUID().uuidString)", isDirectory: true)
        let accountId = UUID()
        let windowDir = root
            .appendingPathComponent(accountId.uuidString, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(roundName(daysAgo: 0), isDirectory: true)
            .appendingPathComponent("window1", isDirectory: true)
        try FileManager.default.createDirectory(at: windowDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = windowDir.appendingPathComponent("renderer.log")
        // 没有换行的半行：本次不应解析，也不能推进偏移丢掉它
        let half = """
        2026-10-25T15:44:27.252+08:00 [info] [ai-chat/v2] [MetadataHandler] received metadata {"session_id":"s1","message_id":"m-half","message_type":"task","status":"completed"}
        """
        try half.write(to: logURL, atomically: true, encoding: .utf8)

        let scanner = TraeTaskScanner(root: root)
        let first = await scanner.scan(accountIds: [accountId])
        XCTAssertTrue(first.isEmpty)

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        let second = await scanner.scan(accountIds: [accountId])
        XCTAssertEqual(second.map(\.messageId), ["m-half"])
    }

    // MARK: - 落库报告（六元组的写入侧）

    func testUpsertWithReportClassifiesInsertedUpdatedSkipped() throws {
        let account = try accountService.create(
            platform: .trae, displayName: "TRAE 账号", phoneMasked: "138****0000"
        )
        let metadata = TraeTaskEvent(
            accountId: account.id,
            messageId: "m1",
            sessionId: "s1",
            title: "任务一",
            status: "in_progress",
            date: Date(timeIntervalSince1970: 1792915776)
        )
        // 同一事件再次出现：内容无变化 → skipped
        var report = try taskService.upsertWithReport([metadata])
        XCTAssertEqual(report.inserted, 1)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(report.failed, 0)

        report = try taskService.upsertWithReport([metadata])
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.changedCount, 0)

        // 补充消耗字段：行存在且内容变化 → updated
        let usage = TraeTaskEvent(
            accountId: account.id,
            messageId: "m1",
            sessionId: "s1",
            credits: 2.5,
            date: Date(timeIntervalSince1970: 1792915790)
        )
        report = try taskService.upsertWithReport([usage])
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.changedCount, 1)
        XCTAssertEqual(try taskService.count(for: account.id), 1, "更新不应产生新行")
    }

    func testUpsertWithReportMergesIntraBatchDuplicates() throws {
        let account = try accountService.create(
            platform: .trae, displayName: "TRAE 账号", phoneMasked: "138****0000"
        )
        let metadata = TraeTaskEvent(
            accountId: account.id,
            messageId: "m1",
            sessionId: "s1",
            title: "任务一",
            date: Date(timeIntervalSince1970: 1792915776)
        )
        let usage = TraeTaskEvent(
            accountId: account.id,
            messageId: "m1",
            sessionId: "s1",
            credits: 4.06,
            date: Date(timeIntervalSince1970: 1792915790)
        )
        // 同一批内的重复 messageId：第一条新增，第二条更新
        let report = try taskService.upsertWithReport([metadata, usage])
        XCTAssertEqual(report.inserted, 1)
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(try taskService.count(for: account.id), 1)
    }

    /// 单个事件写失败（外键冲突）只计入 failed，不阻塞其余事件落库。
    func testUpsertWithReportFailedEventDoesNotBlockOthers() throws {
        let account = try accountService.create(
            platform: .trae, displayName: "TRAE 账号", phoneMasked: "138****0000"
        )
        let orphan = TraeTaskEvent(
            accountId: UUID(), // 未在 accounts 表登记，触发外键冲突
            messageId: "m-orphan",
            sessionId: "s1",
            title: "孤儿事件",
            date: Date(timeIntervalSince1970: 1792915776)
        )
        let valid = TraeTaskEvent(
            accountId: account.id,
            messageId: "m-valid",
            sessionId: "s1",
            title: "正常事件",
            date: Date(timeIntervalSince1970: 1792915776)
        )
        let report = try taskService.upsertWithReport([orphan, valid])
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.inserted, 1)
        XCTAssertEqual(try taskService.history(for: account.id).map(\.id), ["m-valid"])
        XCTAssertEqual(try taskService.countAll(), 1)
    }

    func testUpsertWithReportEmptyEventsReturnsEmptyReport() throws {
        let report = try taskService.upsertWithReport([])
        XCTAssertEqual(report, TraeTaskUpsertReport())
    }

    // MARK: - 六元组汇总

    func testCollectionStatsAssemblesSixTuple() {
        let accountId = UUID()
        let events = [
            TraeTaskEvent(accountId: accountId, messageId: "m1", date: Date()),
            TraeTaskEvent(accountId: accountId, messageId: "m2", date: Date())
        ]
        let diagnostics = TraeTaskScanDiagnostics(
            lastScanAt: Date(),
            lastSuccessfulParseAt: nil,
            scannedFiles: 2,
            roundsScanned: 1,
            newEventCount: 2,
            suspectedFormatIssues: 3,
            readErrorCount: 0
        )
        let scan = TraeTaskScanReport(events: events, diagnostics: [accountId: diagnostics])
        let write = TraeTaskUpsertReport(inserted: 1, updated: 0, skipped: 1, failed: 0)

        let stats = TraeTaskCollectionStats(scan: scan, write: write)
        XCTAssertEqual(stats.discovered, 5, "发现数 = 成功解析 + 格式异常行")
        XCTAssertEqual(stats.parsed, 2)
        XCTAssertEqual(stats.inserted, 1)
        XCTAssertEqual(stats.skipped, 1)
        XCTAssertEqual(stats.failed, 0)
        XCTAssertEqual(stats.changedCount, 1)
        XCTAssertEqual(stats.hasIssue, false)
    }
}
