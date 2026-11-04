import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Core

/// 导出任务/积分历史为 CSV：可选择账号、数据类型与时间范围。
///
/// 导出的字段只有任务摘要、状态、消耗与积分记录；不包含手机号、
/// Token、Cookie 或本地认证数据。
struct ExportSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var type: CSVExportType = .tasks
    @State private var accountId: UUID?
    @State private var range: RangeOption = .all
    @State private var status: String?
    @State private var statusKind: InlineBanner.Kind = .info

    enum RangeOption: String, CaseIterable, Identifiable {
        case all, week, month

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部时间"
            case .week: return "最近 7 天"
            case .month: return "最近 30 天"
            }
        }

        var since: Date? {
            switch self {
            case .all: return nil
            case .week: return Date(timeIntervalSinceNow: -7 * 24 * 3600)
            case .month: return Date(timeIntervalSinceNow: -30 * 24 * 3600)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出 CSV")
                .font(.title3)
                .fontWeight(.semibold)

            Form {
                Picker("数据类型", selection: $type) {
                    ForEach(CSVExportType.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                Picker("账号", selection: $accountId) {
                    Text("全部账号").tag(UUID?.none)
                    ForEach(appState.accounts) { account in
                        Text(account.displayName).tag(UUID?.some(account.id))
                    }
                }
                Picker("时间范围", selection: $range) {
                    ForEach(RangeOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }
            .formStyle(.grouped)

            if let status {
                InlineBanner(kind: statusKind, text: status)
            }

            Text("导出内容只包含任务摘要、状态、积分消耗与积分记录，不含手机号或登录凭据。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导出…", action: export)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func export() {
        do {
            let content = try appState.exportCSV(
                type: type,
                accountId: accountId,
                since: range.since
            )
            guard content.contains("\r\n"), content.split(separator: "\r\n").count > 1 else {
                statusKind = .warning
                status = "所选范围内没有可导出的记录"
                return
            }

            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            if let csv = UTType(filenameExtension: "csv") {
                panel.allowedContentTypes = [csv]
            }
            let accountName = accountId.flatMap { appState.account(id: $0)?.displayName }
            panel.nameFieldStringValue = CSVExport.fileName(type: type, accountName: accountName)
            panel.prompt = "导出"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            try content.write(to: url, atomically: true, encoding: .utf8)
            statusKind = .success
            status = "已导出到 \(url.lastPathComponent)"
        } catch {
            statusKind = .error
            status = "导出失败：\(error.localizedDescription)"
        }
    }
}
