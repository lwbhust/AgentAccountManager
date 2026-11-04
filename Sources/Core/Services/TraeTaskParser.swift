import Foundation

/// 从 TRAE 日志中解析出的一条任务增量。
///
/// 同一条任务的元数据、积分消耗、结束状态来自不同的日志行，
/// 通过 `messageId` 关联后由 `TraeTaskService` 合并成一行记录。
public struct TraeTaskEvent: Sendable {
    public let accountId: UUID
    public let messageId: String
    public let sessionId: String?
    public let title: String?
    public let status: String?
    public let agentName: String?
    public let modelName: String?
    public let credits: Double?
    public let date: Date

    public init(
        accountId: UUID,
        messageId: String,
        sessionId: String? = nil,
        title: String? = nil,
        status: String? = nil,
        agentName: String? = nil,
        modelName: String? = nil,
        credits: Double? = nil,
        date: Date
    ) {
        self.accountId = accountId
        self.messageId = messageId
        self.sessionId = sessionId
        self.title = title
        self.status = status
        self.agentName = agentName
        self.modelName = modelName
        self.credits = credits
        self.date = date
    }
}

/// 单行日志的解析结果。
///
/// `malformed` 专门表示「出现了已识别的事件标记，但内容不再符合预期格式」，
/// 用于在诊断里暴露日志格式变化，而不是把所有解析不到的日志都算成异常。
public enum TraeTaskParseOutcome: Sendable {
    case event(TraeTaskEvent)
    case ignored
    case malformed(marker: String)
}

/// TRAE 本地日志解析器。
///
/// 解析的是 TRAE 桌面端写在自己 `user-data-dir/logs` 下的运行日志，
/// 属于非公开格式：字段缺失时返回 nil 或降级值，不猜测、不补零。
public enum TraeTaskParser {
    /// 任务名（用户输入首行）最大长度。
    public static let titleMaxLength = 60

    static let metadataMarker = "[MetadataHandler] received metadata "
    static let doneMarker = "[DoneHandler] Stream done event received "
    static let streamDoneMarker = "[stream-diagnostics][done] done received "
    static let usageMarker = "cn_session_usage_tail"
    static let usageParamsMarker = "params:  "

    /// 解析单行日志。只有包含已识别事件的行才会返回结果。
    public static func parse(line: Substring, accountId: UUID, now: Date = Date()) -> TraeTaskEvent? {
        guard case .event(let event) = parseOutcome(line: line, accountId: accountId, now: now) else {
            return nil
        }
        return event
    }

    /// 解析单行日志并保留「格式异常」信息，供采集诊断使用。
    public static func parseOutcome(
        line: Substring,
        accountId: UUID,
        now: Date = Date()
    ) -> TraeTaskParseOutcome {
        let text = String(line)
        guard !text.isEmpty else { return .ignored }
        let date = timestamp(in: text) ?? now

        // 任务元数据：session / message / 用户输入首行 / 模型 / 状态
        if let range = text.range(of: metadataMarker) {
            guard let object = jsonObject(in: text, after: range) else {
                return .malformed(marker: "metadata")
            }
            if let event = metadataEvent(object, accountId: accountId, date: date) {
                return .event(event)
            }
            // 明确不是任务的 message 类型属于正常忽略；其余情况视为格式变化
            if let type = object["message_type"] as? String, type != "task" {
                return .ignored
            }
            return .malformed(marker: "metadata")
        }

        // 单轮积分消耗
        if text.contains(usageMarker) {
            guard let range = text.range(of: usageParamsMarker),
                  let object = jsonObject(in: text, after: range),
                  let messageId = object["agent_message_id"] as? String else {
                return .malformed(marker: "usage")
            }
            let credits = (object["usage_summary"] as? String)
                .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .flatMap { $0 >= 0 ? $0 : nil }
            return .event(TraeTaskEvent(
                accountId: accountId,
                messageId: messageId,
                sessionId: object["session_id"] as? String,
                credits: credits,
                date: date
            ))
        }

        // 任务结束状态
        if let range = text.range(of: doneMarker) {
            guard let object = jsonObject(in: text, after: range),
                  let messageId = object["agentMessageId"] as? String else {
                return .malformed(marker: "done")
            }
            return .event(TraeTaskEvent(
                accountId: accountId,
                messageId: messageId,
                sessionId: object["sessionId"] as? String,
                status: object["status"] as? String ?? object["payloadStatus"] as? String,
                date: date
            ))
        }
        if let range = text.range(of: streamDoneMarker) {
            guard let object = jsonObject(in: text, after: range),
                  let messageId = object["agentMessageId"] as? String else {
                return .malformed(marker: "stream-done")
            }
            return .event(TraeTaskEvent(
                accountId: accountId,
                messageId: messageId,
                sessionId: object["sessionId"] as? String,
                status: object["payloadStatus"] as? String ?? object["status"] as? String,
                date: date
            ))
        }

        return .ignored
    }

    // MARK: - 元数据

    private static func metadataEvent(
        _ object: [String: Any],
        accountId: UUID,
        date: Date
    ) -> TraeTaskEvent? {
        guard let messageId = object["message_id"] as? String,
              let sessionId = object["session_id"] as? String else { return nil }
        // 只记录 AI 任务轮次，欢迎页等其它 message 类型不纳入统计
        if let type = object["message_type"] as? String, type != "task" {
            return nil
        }
        let context = object["user_message_context"] as? [String: Any]
        let modelInfo = context?["model_info"] as? [String: Any]
        let createdAt = (object["created_at"] as? Double)
            .map { Date(timeIntervalSince1970: $0) } ?? date

        return TraeTaskEvent(
            accountId: accountId,
            messageId: messageId,
            sessionId: sessionId,
            title: title(from: context?["query"]),
            status: object["status"] as? String,
            agentName: object["agent_name"] as? String,
            modelName: modelInfo?["display_model_name"] as? String,
            date: createdAt
        )
    }

    /// 从用户输入里取首行摘要；只保留一行，避免把完整对话写入数据库。
    ///
    /// 日志里的 `query` 有时是数组，有时是被序列化成字符串的数组，
    /// 两种形式都要能取出第一条 text 内容；纯斜杠命令则退回命令名。
    static func title(from query: Any?) -> String? {
        title(from: query, allowEmbeddedJSON: true)
    }

    private static func title(from query: Any?, allowEmbeddedJSON: Bool) -> String? {
        let items: [[String: Any]]
        if let array = query as? [[String: Any]] {
            items = array
        } else if let array = query as? [Any] {
            items = array.compactMap { $0 as? [String: Any] }
        } else if let text = query as? String {
            if allowEmbeddedJSON,
               let data = text.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data),
               let title = title(from: decoded, allowEmbeddedJSON: false) {
                return title
            }
            return firstLine(text)
        } else {
            return nil
        }

        for item in items where item["type"] as? String == "text" {
            let content = (item["data"] as? [String: Any])?["content"] as? String
            if let content, let line = firstLine(content) {
                return line
            }
        }
        // 选中对话片段继续提问：优先用用户补充的评论当摘要
        for item in items where item["type"] as? String == "conversation_selection" {
            let data = item["data"] as? [String: Any]
            if let comment = data?["comment"] as? String, let line = firstLine(comment) {
                return line
            }
            if let text = data?["text"] as? String, let line = firstLine(text) {
                return line
            }
        }
        for item in items where item["type"] as? String == "slash_command" {
            let data = item["data"] as? [String: Any]
            if let name = (data?["display_name"] as? String) ?? (data?["command"] as? String),
               !name.isEmpty {
                return name
            }
        }
        return nil
    }

    /// 取文本首行并截断到上限。
    private static func firstLine(_ text: String) -> String? {
        guard let rawLine = text.split(whereSeparator: \.isNewline).first else { return nil }
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        if line.count <= titleMaxLength { return line }
        return String(line.prefix(titleMaxLength - 1)) + "…"
    }

    // MARK: - 通用解析

    /// 取日志行前缀的时间戳（形如 `2026-10-25T15:44:27.252+08:00`）。
    static func timestamp(in text: String) -> Date? {
        let prefix = text.prefix { $0 != " " }
        guard prefix.count >= 20 else { return nil }
        let raw = String(prefix)
        if let date = fractionalTimestampFormatter.date(from: raw) {
            return date
        }
        return plainTimestampFormatter.date(from: raw)
    }

    /// 从标记之后截取第一个 JSON 对象。
    static func jsonObject(in text: String, after range: Range<String.Index>) -> [String: Any]? {
        let rest = text[range.upperBound...]
        guard let start = rest.firstIndex(of: "{") else { return nil }
        let json = rest[start...]
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    private static let fractionalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
