import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Core

/// 设置窗口：把低频的数据管理、诊断与安全说明从核心操作区移出。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var statusMessage: StatusMessage?
    @State private var pendingRestoreURL: URL?
    @State private var showingRestoreConfirm = false
    @State private var showingWipeConfirm = false
    @State private var showingExport = false
    @AppStorage(AppearanceSetting.backgroundKey) private var immersiveBackgroundEnabled = true

    struct StatusMessage: Identifiable {
        let id = UUID()
        let text: String
        let kind: InlineBanner.Kind
    }

    var body: some View {
        Form {
            appearanceSection
            dataLocationSection
            backupSection
            diagnosticsSection
            securitySection
            dangerSection
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 620)
        .sheet(isPresented: $showingExport) {
            ExportSheet()
                .environmentObject(appState)
        }
        .confirmationDialog(
            "从备份恢复会覆盖当前数据",
            isPresented: $showingRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("覆盖并恢复", role: .destructive) { performRestore() }
            Button("取消", role: .cancel) { pendingRestoreURL = nil }
        } message: {
            Text("当前账号档案、积分历史与切换记录将被备份文件中的内容替换（钥匙串中的完整手机号不会被恢复）。建议先备份当前数据。")
        }
        .confirmationDialog(
            "清空所有本地数据？",
            isPresented: $showingWipeConfirm,
            titleVisibility: .visible
        ) {
            Button("清空并重置", role: .destructive) { performWipe() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "将删除本机的账号档案、积分记录、任务记录、切换记录、项目与工位记录，以及钥匙串中保存的完整手机号。"
                    + "不会删除 \(appState.traeUserDataDirCount) 个 TRAE 独立配置目录（含本地登录会话），"
                    + "也不会删除 worktree 目录或你已经备份的 .sqlite 文件。官方平台上的账号不受影响，但此操作不可恢复。"
            )
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section {
            Toggle(isOn: $immersiveBackgroundEnabled) {
                Label("沉浸式背景", systemImage: "photo.artframe")
            }
        } header: {
            Text("外观")
        } footer: {
            Text("星空山脉背景图，带极慢的漂移效果，照片上覆盖一层系统磨砂以保证文字可读。关闭开关、窗口失焦或系统开启「减少动态效果」时停止动画，以减少耗电。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 数据位置

    private var dataLocationSection: some View {
        Section {
            LabeledContent("数据库文件") {
                Text(appState.databasePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appState.databasePath)])
                }
                Button("打开数据目录") {
                    let url = URL(fileURLWithPath: appState.databasePath).deletingLastPathComponent()
                    NSWorkspace.shared.open(url)
                }
                Spacer()
            }
        } header: {
            Text("数据位置")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text("账号档案与积分为本机 SQLite 文件；完整手机号保存在 macOS 钥匙串。")
                Text("TRAE 独立配置目录：\(appState.traeService.traeDataRoot.path)")
                    .textSelection(.enabled)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 备份与恢复

    private var backupSection: some View {
        Section {
            HStack {
                Button("备份到文件夹…") { chooseBackupDirectory() }
                Button("从备份恢复…") { chooseBackupFile() }
                Button("导出 CSV…") { showingExport = true }
            }
            if let statusMessage {
                InlineBanner(kind: statusMessage.kind, text: statusMessage.text)
            }
        } header: {
            Text("备份与恢复")
        } footer: {
            Text("备份为带时间戳的 .sqlite 文件（写入后会做完整性校验），只包含本机账号档案与历史记录，不含钥匙串凭据和 TRAE 登录会话。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 危险操作

    /// 危险操作与常规操作分区隔离：物理上远离备份按钮，视觉上用 destructive 样式标记，
    /// 并保留独立确认流程（点击后弹出 confirmationDialog）。
    private var dangerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Button("清空所有本地数据…", role: .destructive) {
                    showingWipeConfirm = true
                }
                Text("删除本机全部账号档案、积分与任务记录、切换记录、项目与工位，以及钥匙串中的完整手机号。TRAE 独立配置目录和 worktree 目录不会被删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        } header: {
            Text("危险操作")
        }
    }

    // MARK: - 诊断

    private var diagnosticsSection: some View {
        Section {
            let counts = appState.dataCounts
            LabeledContent("本机数据") {
                Text("\(counts.accounts) 个账号 · \(counts.credits) 条积分记录 · \(counts.switches) 条切换记录 · \(counts.tasks) 条任务记录")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("应用版本") {
                Text(appState.appVersion)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("WorkBuddy") {
                installStatus(for: .workbuddy)
            }
            LabeledContent("TRAE") {
                installStatus(for: .trae)
            }
            if !appState.isDatabaseReady {
                InlineBanner(kind: .error, text: "数据库不可用：\(appState.errorMessage ?? "未知原因")")
            }
        } header: {
            Text("诊断信息")
        }
    }

    private func installStatus(for platform: Platform) -> some View {
        Group {
            if !platform.isInstalled {
                TagChip(text: "未安装", color: .orange, systemImage: "exclamationmark.triangle")
            } else if let problem = appState.installProblem(for: platform) {
                TagChip(text: problem, color: .orange)
            } else {
                TagChip(text: "已安装，可切换", color: .green, systemImage: "checkmark.circle")
            }
        }
    }

    // MARK: - 安全说明

    private var securitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                bullet("不保存密码、Token 或 Cookie")
                bullet("数据库只存脱敏手机号，完整号码仅在钥匙串")
                bullet("只使用官方支持的切换方式：TRAE 独立配置目录、WorkBuddy 手动登录")
                bullet("不复制或修改官方应用的私有认证文件")
                bullet("积分查询失败时保留原值，不写 0、不伪造数据")
                bullet("「已启动客户端」不等于「已登录」，需你核对确认")
            }
            .padding(.vertical, 2)
        } header: {
            Text("安全与诚实约束")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("·")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 动作

    private func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "备份到此文件夹"
        panel.message = "选择一个用于保存备份文件的文件夹"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let url = try appState.backupDatabase(to: directory)
            statusMessage = StatusMessage(text: "备份已保存：\(url.lastPathComponent)", kind: .success)
        } catch {
            statusMessage = StatusMessage(text: "备份失败：\(error.localizedDescription)", kind: .error)
        }
    }

    private func chooseBackupFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let sqlite = UTType(filenameExtension: "sqlite") {
            panel.allowedContentTypes = [sqlite]
        }
        panel.prompt = "选择备份文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingRestoreURL = url
        showingRestoreConfirm = true
    }

    private func performRestore() {
        guard let url = pendingRestoreURL else { return }
        do {
            let safety = try appState.restoreDatabase(from: url)
            statusMessage = StatusMessage(
                text: "已从 \(url.lastPathComponent) 恢复；恢复前的数据已备份为 \(safety.lastPathComponent)",
                kind: .success
            )
        } catch {
            statusMessage = StatusMessage(text: "恢复失败：\(error.localizedDescription)", kind: .error)
        }
        pendingRestoreURL = nil
    }

    private func performWipe() {
        do {
            try appState.wipeAllLocalData()
            statusMessage = StatusMessage(text: "本地数据已清空，可从备份恢复", kind: .success)
        } catch {
            statusMessage = StatusMessage(text: "清空失败：\(error.localizedDescription)", kind: .error)
        }
    }
}
