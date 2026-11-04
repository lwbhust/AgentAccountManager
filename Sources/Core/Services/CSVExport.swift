import Foundation

/// CSV 导出类型。
public enum CSVExportType: String, CaseIterable, Sendable {
    case tasks
    case credits

    public var displayName: String {
        switch self {
        case .tasks: return "任务记录"
        case .credits: return "积分记录"
        }
    }
}

/// 把本地历史记录导出为 CSV。
///
/// 只导出任务摘要、状态、消耗与积分记录，不包含手机号、Token、
/// Cookie 或任何本地认证数据；字段按 RFC 4180 转义。
public enum CSVExport {
    /// 带 UTF-8 BOM，便于 Excel 正确识别中文。
    static let bom = "\u{FEFF}"

    public static func content(type: CSVExportType, tasks: [TraeTask], credits: [CreditSnapshot]) -> String {
        switch type {
        case .tasks: return taskCSV(tasks)
        case .credits: return creditCSV(credits)
        }
    }

    public static func taskCSV(_ tasks: [TraeTask]) -> String {
        var rows = [["时间", "任务", "状态", "积分消耗", "模型", "Agent"]]
        for task in tasks {
            rows.append([
                isoDate(task.createdAt),
                task.title ?? "（未获取到任务描述）",
                task.status.displayName,
                task.credits.map { TraeTask.creditsDisplay($0) } ?? "未采集",
                task.modelName ?? "",
                task.agentName ?? ""
            ])
        }
        return bom + render(rows)
    }

    public static func creditCSV(_ snapshots: [CreditSnapshot]) -> String {
        var rows = [["时间", "积分", "总额度", "来源", "状态", "说明"]]
        for snapshot in snapshots {
            rows.append([
                isoDate(snapshot.queryAt),
                snapshot.credits.map(String.init) ?? "未记录",
                snapshot.totalCredits.map(String.init) ?? "",
                snapshot.source.displayName,
                statusName(snapshot.status),
                snapshot.errorMessage ?? ""
            ])
        }
        return bom + render(rows)
    }

    /// 建议的文件名（不含路径，自动去掉文件名里的非法字符）。
    public static func fileName(type: CSVExportType, accountName: String?, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let prefix = type == .tasks ? "TRAE任务" : "积分记录"
        let namePart = accountName.map { "-" + sanitize($0) } ?? "-全部账号"
        return "\(prefix)\(namePart)-\(formatter.string(from: date)).csv"
    }

    // MARK: - 内部

    private static func render(_ rows: [[String]]) -> String {
        rows.map { row in row.map(escape).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
    }

    /// 按 CSV 规则转义单个字段（含逗号、引号、换行时加引号）。
    public static func escape(_ field: String) -> String {
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "账号" : String(cleaned.prefix(40))
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func statusName(_ status: SnapshotStatus) -> String {
        switch status {
        case .success: return "成功"
        case .failed: return "失败"
        case .stale: return "过期"
        }
    }
}
