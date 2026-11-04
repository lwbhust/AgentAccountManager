import Foundation

/// 一次采集的结果概况（按账号）。
public struct TraeTaskScanDiagnostics: Sendable, Equatable {
    /// 本次扫描完成的时间
    public let lastScanAt: Date
    /// 最近一次完整读取日志成功的时间（跨应用重启保留）
    public let lastSuccessfulParseAt: Date?
    /// 本次实际读取的日志文件数
    public let scannedFiles: Int
    /// 本次读取的日志轮次数
    public let roundsScanned: Int
    /// 本次新增解析出的事件数（已写入数据库前）
    public let newEventCount: Int
    /// 出现已识别标记但内容无法解析的行数（日志格式可能已变化）
    public let suspectedFormatIssues: Int
    /// 读取文件失败次数
    public let readErrorCount: Int

    public init(
        lastScanAt: Date,
        lastSuccessfulParseAt: Date?,
        scannedFiles: Int,
        roundsScanned: Int,
        newEventCount: Int,
        suspectedFormatIssues: Int,
        readErrorCount: Int
    ) {
        self.lastScanAt = lastScanAt
        self.lastSuccessfulParseAt = lastSuccessfulParseAt
        self.scannedFiles = scannedFiles
        self.roundsScanned = roundsScanned
        self.newEventCount = newEventCount
        self.suspectedFormatIssues = suspectedFormatIssues
        self.readErrorCount = readErrorCount
    }

    /// 是否出现需要用户留意的采集异常。
    public var hasIssue: Bool {
        suspectedFormatIssues > 0 || readErrorCount > 0
    }
}

/// 一次采集的完整结果。
public struct TraeTaskScanReport: Sendable {
    public let events: [TraeTaskEvent]
    public let diagnostics: [UUID: TraeTaskScanDiagnostics]

    public init(events: [TraeTaskEvent], diagnostics: [UUID: TraeTaskScanDiagnostics]) {
        self.events = events
        self.diagnostics = diagnostics
    }
}

/// 一次任务采集的完整统计（发现/解析/新增/更新/跳过/失败 六元组）。
///
/// 用于区分「没有新任务」（discovered/parsed 正常、skipped 占多数、
/// inserted/updated 为 0）与「采集出现问题」（failed > 0，或格式异常行多，
/// 后者见 `TraeTaskScanDiagnostics.hasIssue`）。
public struct TraeTaskCollectionStats: Sendable, Equatable {
    /// 扫描发现的候选行数（带已知事件标记的日志行，含格式异常行）
    public var discovered: Int
    /// 成功解析为任务事件的行数
    public var parsed: Int
    /// 新写入数据库的任务数
    public var inserted: Int
    /// 实际发生更新的已有任务数
    public var updated: Int
    /// 内容无变化、无需写入的重复事件数
    public var skipped: Int
    /// 未能落库的事件数
    public var failed: Int

    /// 由扫描结果与落库结果汇总；`write` 传入空报告表示尚未落库。
    public init(scan: TraeTaskScanReport, write: TraeTaskUpsertReport) {
        let formatIssues = scan.diagnostics.values.reduce(0) { $0 + $1.suspectedFormatIssues }
        self.discovered = scan.events.count + formatIssues
        self.parsed = scan.events.count
        self.inserted = write.inserted
        self.updated = write.updated
        self.skipped = write.skipped
        self.failed = write.failed
    }

    public init(
        discovered: Int = 0,
        parsed: Int = 0,
        inserted: Int = 0,
        updated: Int = 0,
        skipped: Int = 0,
        failed: Int = 0
    ) {
        self.discovered = discovered
        self.parsed = parsed
        self.inserted = inserted
        self.updated = updated
        self.skipped = skipped
        self.failed = failed
    }

    /// 累加落库结果（扫描完成后的写入阶段调用）。
    public mutating func merge(_ write: TraeTaskUpsertReport) {
        inserted += write.inserted
        updated += write.updated
        skipped += write.skipped
        failed += write.failed
    }

    /// 实际写入（新增+更新）的任务数。
    public var changedCount: Int { inserted + updated }

    /// 是否出现落库异常。
    public var hasIssue: Bool { failed > 0 }
}

/// 增量读取 TRAE 各账号实例的运行日志，解析出任务事件。
///
/// 只读取本应用创建的 `user-data-dir/<账号>/logs`，不读取登录态等敏感数据。
/// 每个日志文件按偏移量增量读取，避免每次刷新都重新解析整份日志；
/// 偏移只推进到最后一个完整换行，半行不会被丢弃也不会写入 UserDefaults。
public actor TraeTaskScanner {
    private let root: URL
    private let defaults: UserDefaults
    /// 首次读取一个日志文件时最多回看多少字节（只取最近的日志）。
    private let initialTailBytes: UInt64 = 16 * 1_048_576
    /// 每次最多补采几轮日志（最新优先），避免首次启动扫描全部历史。
    private let maxRoundsPerScan = 2
    /// 单轮日志里最多读取多少个窗口文件。
    private let maxFilesPerRound = 8
    /// 补采的时间范围上限。
    private let backfillDays = 7

    private var offsets: [String: UInt64] = [:]
    private var skipFirstLine: Set<String> = []
    private var lastSuccessfulParse: [String: Date] = [:]

    private static let offsetsKey = "traeTaskScanner.offsets.v1"
    private static let lastParseKey = "traeTaskScanner.lastSuccessfulParseAt.v1"

    /// - Parameters:
    ///   - root: 所有账号隔离目录的根目录（`.../TraeUserData`）。
    ///   - defaults: 偏移持久化使用的 UserDefaults（测试可注入独立 suite）。
    public init(root: URL, defaults: UserDefaults = .standard) {
        self.root = root
        self.defaults = defaults
        // 直接在 init 中恢复状态，避免从非隔离上下文调用 actor 方法
        if let stored = defaults.dictionary(forKey: Self.offsetsKey) {
            for (key, value) in stored {
                if let number = value as? NSNumber {
                    offsets[key] = number.uint64Value
                }
            }
        }
        if let stored = defaults.dictionary(forKey: Self.lastParseKey) {
            for (key, value) in stored {
                if let number = value as? NSNumber {
                    lastSuccessfulParse[key] = Date(timeIntervalSince1970: number.doubleValue)
                }
            }
        }
    }

    /// 采集指定账号当前日志里的新增任务事件。
    public func scan(accountIds: [UUID]) -> [TraeTaskEvent] {
        scanDetailed(accountIds: accountIds).events
    }

    /// 采集并返回诊断信息。
    public func scanDetailed(accountIds: [UUID]) -> TraeTaskScanReport {
        var events: [TraeTaskEvent] = []
        var diagnostics: [UUID: TraeTaskScanDiagnostics] = [:]
        let now = Date()

        for accountId in accountIds {
            let logsDir = root
                .appendingPathComponent(accountId.uuidString, isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
            let rounds = recentRounds(in: logsDir, now: now)

            var scannedFiles = 0
            var readErrors = 0
            var formatIssues = 0
            var eventCount = 0

            for round in rounds {
                for file in round.files {
                    scannedFiles += 1
                    switch drain(file: file, accountId: accountId, now: now) {
                    case .success(let result):
                        eventCount += result.events.count
                        formatIssues += result.malformedLines
                        events.append(contentsOf: result.events)
                    case .failure:
                        readErrors += 1
                    }
                }
            }

            let key = accountId.uuidString
            if readErrors == 0 {
                lastSuccessfulParse[key] = now
            }
            diagnostics[accountId] = TraeTaskScanDiagnostics(
                lastScanAt: now,
                lastSuccessfulParseAt: lastSuccessfulParse[key],
                scannedFiles: scannedFiles,
                roundsScanned: rounds.count,
                newEventCount: eventCount,
                suspectedFormatIssues: formatIssues,
                readErrorCount: readErrors
            )
        }

        persistState()
        return TraeTaskScanReport(events: events, diagnostics: diagnostics)
    }

    /// 清除已持久化的偏移（仅用于诊断/测试，不会删除任何日志）。
    public func resetPersistedState() {
        offsets.removeAll()
        skipFirstLine.removeAll()
        lastSuccessfulParse.removeAll()
        defaults.removeObject(forKey: Self.offsetsKey)
        defaults.removeObject(forKey: Self.lastParseKey)
    }

    // MARK: - 日志定位

    private struct RoundLogs {
        let name: String
        let files: [URL]
    }

    /// 取最近若干轮日志目录下所有窗口的 `renderer.log`。
    ///
    /// TRAE 每次启动会新建 `logs/<yyyyMMddTHHmmss>` 目录；这里只补采最近
    /// `maxRoundsPerScan` 轮、且不早于 `backfillDays`，避免一次扫描全部历史。
    private func recentRounds(in logsDir: URL, now: Date) -> [RoundLogs] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = now.addingTimeInterval(-Double(backfillDays) * 24 * 3600)
        var rounds: [RoundLogs] = []
        for round in entries.filter({ isRoundDirectory($0) }) {
            if let date = roundDate(round), date < cutoff { continue }
            guard let windows = try? fm.contentsOfDirectory(
                at: round,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            let files = windows
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { window -> URL? in
                    guard window.lastPathComponent.hasPrefix("window") else { return nil }
                    let file = window.appendingPathComponent("renderer.log")
                    return fm.fileExists(atPath: file.path) ? file : nil
                }
                .prefix(maxFilesPerRound)
            guard !files.isEmpty else { continue }
            rounds.append(RoundLogs(name: round.lastPathComponent, files: Array(files)))
        }
        return rounds
            .sorted { $0.name > $1.name }
            .prefix(maxRoundsPerScan)
            .map { $0 }
    }

    private func isRoundDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.count == 15 else { return false }
        guard name.allSatisfy({ $0.isNumber || $0 == "T" }) else { return false }
        return name[name.index(name.startIndex, offsetBy: 8)] == "T"
    }

    private func roundDate(_ url: URL) -> Date? {
        Self.roundFormatter.date(from: url.lastPathComponent)
    }

    private static let roundFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()

    // MARK: - 增量读取

    private struct DrainResult {
        let events: [TraeTaskEvent]
        let malformedLines: Int
    }

    private enum DrainOutcome {
        case success(DrainResult)
        case failure
    }

    private func drain(file: URL, accountId: UUID, now: Date) -> DrainOutcome {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return .failure }

        let path = file.path
        var offset: UInt64
        if let stored = offsets[path] {
            offset = stored
            if size < stored {
                // 文件被截断或轮转：清空状态从头读
                offset = 0
                skipFirstLine.remove(path)
            }
        } else if size > initialTailBytes {
            offset = size - initialTailBytes
            // 起点可能落在一行中间，丢弃首个不完整行
            skipFirstLine.insert(path)
        } else {
            offset = 0
        }

        guard size > offset,
              let handle = try? FileHandle(forReadingFrom: file) else {
            offsets[path] = offset
            return .success(DrainResult(events: [], malformedLines: 0))
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: Int(size - offset)), !data.isEmpty else {
                offsets[path] = offset
                return .success(DrainResult(events: [], malformedLines: 0))
            }
            // 只消费到最后一个完整换行；半行留到下次重新读取，避免重启后丢数据
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                offsets[path] = offset
                return .success(DrainResult(events: [], malformedLines: 0))
            }
            let complete = data[..<lastNewline]
            offsets[path] = offset + UInt64(lastNewline + 1)
            let result = parse(data: Data(complete), path: path, accountId: accountId, now: now)
            return .success(result)
        } catch {
            return .failure
        }
    }

    /// 按行解析；起点落在行中间时丢弃首个不完整行。
    private func parse(data: Data, path: String, accountId: UUID, now: Date) -> DrainResult {
        var events: [TraeTaskEvent] = []
        var malformed = 0
        var dropsFirst = skipFirstLine.remove(path) != nil
        for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if dropsFirst {
                dropsFirst = false
                continue
            }
            guard let line = String(data: Data(lineData), encoding: .utf8) else {
                malformed += 1
                continue
            }
            switch TraeTaskParser.parseOutcome(line: line[...], accountId: accountId, now: now) {
            case .event(let event):
                events.append(event)
            case .malformed:
                malformed += 1
            case .ignored:
                break
            }
        }
        return DrainResult(events: events, malformedLines: malformed)
    }

    // MARK: - 状态持久化

    /// 只保留仍然存在的日志文件偏移，避免 UserDefaults 无限增长。
    private func persistState() {
        let trimmedOffsets = offsets
            .filter { FileManager.default.fileExists(atPath: $0.key) }
            .sorted { $0.key < $1.key }
            .suffix(300)
        defaults.set(
            Dictionary(uniqueKeysWithValues: trimmedOffsets.map { ($0.key, NSNumber(value: $0.value)) }),
            forKey: Self.offsetsKey
        )
        let trimmedParse = lastSuccessfulParse
            .sorted { $0.key < $1.key }
            .suffix(100)
        defaults.set(
            Dictionary(uniqueKeysWithValues: trimmedParse.map {
                ($0.key, NSNumber(value: $0.value.timeIntervalSince1970))
            }),
            forKey: Self.lastParseKey
        )
    }
}
