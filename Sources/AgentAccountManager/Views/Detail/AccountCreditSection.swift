import SwiftUI
import Core

/// 账号详情页「积分与任务」分区：额度指标、采集面板与任务消耗列表。
///
/// 纯展示层：余额估算由 AppState 预先计算后传入（视图内禁止额度计算），
/// 录入/采集动作通过回调上抛，这里不做任何 IO。
///
/// 信息层级（P0 重构）：
/// 1. 核心指标：预计剩余额度 + 是否可作实时余额使用 + 录入入口；
/// 2. 辅助指标：最近实际录入 / 已计入消耗 / 待核算任务（三者口径互相独立）；
/// 3. 计算依据：总额度、积分类型、数据来源、基准时间（去掉与基准时间重复的观测时间）。
struct AccountCreditSection: View {
    let account: Account
    let estimate: CreditBalanceEstimate?
    let staleInterval: TimeInterval
    let diagnostics: TraeTaskScanDiagnostics?
    let lastCollectionAt: Date?
    let isCollecting: Bool
    let tasks: [TraeTask]
    let taskTotal: Int
    let taskTodayCredits: Double?
    let hasBalanceBaseline: Bool
    let taskPreviewCount: Int
    @Binding var showingAllTasks: Bool
    let onLoadMoreTasks: () -> Void
    let onRecordCredit: () -> Void
    let onCollect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            CreditBalanceCard(
                account: account,
                estimate: estimate,
                staleInterval: staleInterval,
                onRecordCredit: onRecordCredit
            )
            TaskCollectionPanel(
                diagnostics: diagnostics,
                lastCollectionAt: lastCollectionAt,
                isCollecting: isCollecting,
                onCollect: onCollect
            )
            TaskHistoryCard(
                tasks: tasks,
                total: taskTotal,
                todayCredits: taskTodayCredits,
                hasBalanceBaseline: hasBalanceBaseline,
                previewCount: taskPreviewCount,
                showingAll: $showingAllTasks,
                onLoadMore: onLoadMoreTasks
            )
        }
    }
}

// MARK: - 积分余额

/// 余额概况：核心指标 + 辅助指标 + 计算依据三段式。
struct CreditBalanceCard: View {
    let account: Account
    let estimate: CreditBalanceEstimate?
    let staleInterval: TimeInterval
    let onRecordCredit: () -> Void

    var body: some View {
        SectionCard(title: "积分余额", accessory: { statusChips }) {
            if !account.hasCreditRecord {
                noRecordContent
            } else {
                coreMetrics
                Divider()
                auxiliaryMetrics
                Divider()
                basisDetails
            }
        }
    }

    // MARK: 状态标签

    /// 状态标签全部"颜色 + 文字 + 图标"，并且只在真正需要处理时使用警示色。
    @ViewBuilder
    private var statusChips: some View {
        if account.dataStatus == .queryFailed {
            TagChip(text: "需要检查日志", color: DS.Status.failure, systemImage: "exclamationmark.triangle")
                .help("最近一次查询失败，当前显示的是上一次成功的记录值，不代表现在的余额")
        } else if !account.hasCreditRecord {
            TagChip(text: "数据不足", color: .secondary, systemImage: "questionmark.circle")
                .help("还没有录入过额度，无法给出预计余额")
        } else if isStale {
            TagChip(text: "数据待更新", color: .secondary, systemImage: "clock.arrow.circlepath")
                .help("最近一次录入已超过 \(Int(staleInterval / 3600)) 小时，期间的任务消耗可能没有被完整采集")
        } else {
            TagChip(text: "已更新", color: DS.Status.running, systemImage: "checkmark.circle")
                .help("最近一次录入在有效期内")
        }

        if let estimate, estimate.pendingTaskCount > 0 {
            TagChip(text: "另有 \(estimate.pendingTaskCount) 个任务未计入", color: .secondary, systemImage: "questionmark.circle")
                .help("这些任务已执行，但日志里没有可靠的积分数据，因此没有从预计余额中扣减")
        }
    }

    // MARK: A. 核心指标

    private var coreMetrics: some View {
        HStack(alignment: .top, spacing: DS.Space.xl) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.s) {
                    Text("预计剩余积分")
                        .font(DS.Font.secondary)
                        .foregroundStyle(.secondary)
                    TagChip(text: "估算", color: .secondary)
                        .help("由本地录入值与日志消耗推算，不是官方实时余额")
                }
                Text(Format.credits(displayedCredits))
                    .font(DS.Font.metric(34))
                    .foregroundStyle(negativeBalance ? DS.Status.needsAttention : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(coreFootnote)
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if negativeBalance {
                    Text("已计入的消耗超过了记录的余额，请到官方界面查看后重新录入。")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Status.needsAttention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: DS.Space.m)

            VStack(alignment: .trailing, spacing: DS.Space.s) {
                Text("录入于 \(observedText)")
                    .font(DS.Font.caption)
                    .foregroundStyle(.tertiary)
                Button("录入实际余额", action: onRecordCredit)
                    .buttonStyle(TranslucentCapsuleButtonStyle())
                    .help("把当前官方界面显示的积分记为新的基准，之后的消耗在此基础上扣减")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// 核心说明：把"预计 = 录入 − 已计入"的口径直接写出来，并提示未计入部分。
    private var coreFootnote: String {
        guard let estimate else {
            return "只有最近一次录入值，基准之后的任务消耗暂未计入。"
        }
        var text = "基准 \(Format.credits(estimate.baselineCredits))（\(Format.shortTime(estimate.baselineAt)) 录入）"
        if estimate.hasDeduction {
            text += " − 已计入 \(Format.credits(estimate.consumedCredits))"
        } else {
            text += "，基准后暂无已采集消耗"
        }
        if estimate.pendingTaskCount > 0 {
            text += "；\(estimate.pendingTaskCount) 个任务的消耗尚未采集，未计入。"
        } else {
            text += "。"
        }
        return text
    }

    // MARK: B. 辅助指标

    private var auxiliaryMetrics: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            MetricTile(
                label: "最近实际录入",
                value: Format.credits(account.currentCredits),
                caption: account.lastCreditQueryAt.map { "观测于 \(Format.shortTime($0))" } ?? "无观测时间",
                footnote: "最近一次手动录入的数值，后续消耗以此为准"
            )
            MetricTile(
                label: "已计入消耗",
                value: estimate?.hasDeduction == true
                    ? "−\(Format.credits(estimate?.consumedCredits))"
                    : "—",
                caption: "\(estimate?.consumedTaskCount ?? 0) 个任务已计入",
                footnote: "基准之后、日志里带可靠积分数据的任务"
            )
            MetricTile(
                label: "待核算任务",
                value: "\(estimate?.pendingTaskCount ?? 0) 个",
                caption: "消耗未知，未计入估算",
                valueColor: (estimate?.pendingTaskCount ?? 0) > 0 ? DS.Status.needsAttention : .primary,
                footnote: "任务已执行但日志缺少积分记录，不按 0 处理"
            )
        }
    }

    // MARK: C. 计算依据

    private var basisDetails: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            DetailGrid {
                DetailItem(label: "总额度", value: Format.credits(account.totalCredits))
                DetailItem(label: "积分类型", value: account.creditType ?? "未记录")
                DetailItem(label: "数据来源", value: account.dataSource.displayName)
                DetailItem(
                    label: "余额基准时间",
                    value: estimate.map { Format.dateTime($0.baselineAt) }
                        ?? account.lastCreditQueryAt.map(Format.dateTime)
                        ?? "未记录"
                )
                if showsSeparateQueryTime, let queryAt = account.lastCreditQueryAt {
                    DetailItem(label: "最近查询", value: Format.dateTime(queryAt))
                }
                if account.dataStatus == .queryFailed {
                    DetailItem(label: "上次查询", value: "失败（保留原值）", valueColor: DS.Status.failure)
                }
            }
            Text("预计余额 = 最近实际录入 − 基准后已采集消耗；待核算任务的消耗未知，既不计入也不按 0 处理。")
                .font(DS.Font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var noRecordContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("还没有录入过额度，无法估算剩余积分")
                .font(DS.Font.body)
            Text("去 TRAE 官方界面查看当前积分后录入一次；之后的任务消耗会以这次录入为基准自动扣减。")
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("录入当前积分", action: onRecordCredit)
                .buttonStyle(TranslucentCapsuleButtonStyle(isProminent: true))
                .padding(.top, DS.Space.xs)
        }
    }

    // MARK: 计算属性

    private var displayedCredits: Double? {
        estimate?.estimatedCredits ?? account.currentCredits.map(Double.init)
    }

    private var negativeBalance: Bool {
        (estimate?.estimatedCredits ?? 0) < 0
    }

    private var isStale: Bool {
        account.hasCreditRecord && account.isCreditStale(within: staleInterval)
    }

    private var observedText: String {
        account.lastCreditQueryAt.map(Format.relative) ?? "未知时间"
    }

    /// 基准时间与最近查询时间实质相同（手动录入即一次查询观测），只在明显不同时才重复展示。
    private var showsSeparateQueryTime: Bool {
        guard let estimate, let queryAt = account.lastCreditQueryAt else { return false }
        return abs(queryAt.timeIntervalSince(estimate.baselineAt)) > 60
    }
}

// MARK: - 任务采集面板

/// 紧凑采集面板：标题行（状态 + 立即采集）、一行关键统计、可折叠的诊断详情。
///
/// 统计只使用真实扫描结果，采集进行中禁用按钮并显示进度，
/// 「上次扫描」使用相对时间，不会出现「0 秒后」这类误导文案。
struct TaskCollectionPanel: View {
    let diagnostics: TraeTaskScanDiagnostics?
    let lastCollectionAt: Date?
    let isCollecting: Bool
    let onCollect: () -> Void

    @State private var showDetails = false

    var body: some View {
        SectionCard(
            title: "任务采集",
            subtitle: statusText,
            subtitleColor: statusColor,
            accessory: { collectButton }
        ) {
            statsRow

            // 真实异常始终可见，不收进折叠组。
            if let diagnostics, diagnostics.suspectedFormatIssues > 0 {
                InlineBanner(
                    kind: .warning,
                    text: "\(diagnostics.suspectedFormatIssues) 行日志带有已知事件标记但无法解析，TRAE 日志格式可能已变化。"
                )
            }
            if let diagnostics, diagnostics.readErrorCount > 0 {
                InlineBanner(
                    kind: .error,
                    text: "\(diagnostics.readErrorCount) 个日志文件读取失败，本次采集结果可能不完整。"
                )
            }

            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    DetailGrid {
                        DetailItem(label: "最近成功解析", value: parsedAtText)
                        DetailItem(label: "读取范围", value: "\(diagnostics?.scannedFiles ?? 0) 个文件 · \(diagnostics?.roundsScanned ?? 0) 轮")
                        DetailItem(label: "本次新增事件", value: "\(diagnostics?.newEventCount ?? 0) 条")
                        DetailItem(label: "格式异常行", value: "\(diagnostics?.suspectedFormatIssues ?? 0) 行")
                    }
                    Text("只读取本应用创建的 TRAE 独立配置目录日志，只保存任务首行摘要与消耗，不保存完整对话。")
                        .font(DS.Font.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, DS.Space.s)
            } label: {
                Text("采集详情")
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var collectButton: some View {
        HStack(spacing: DS.Space.s) {
            if isCollecting {
                ProgressView()
                    .controlSize(.small)
                Text("采集中…")
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
            }
            Button("立即采集", action: onCollect)
                .controlSize(.small)
                .disabled(isCollecting)
                .help("立即读取 TRAE 本地日志（⌘R）")
        }
    }

    /// 一行关键统计：上次扫描、本次新增、读取范围、异常数量。
    private var statsRow: some View {
        HStack(alignment: .top, spacing: DS.Space.xl) {
            statItem(
                label: "上次扫描",
                value: lastScanText,
                caption: lastCollectionAt.map { "采集完成于 \(Format.relative($0))" }
            )
            statItem(
                label: "本次新增",
                value: "\(diagnostics?.newEventCount ?? 0) 条",
                caption: "任务事件"
            )
            statItem(
                label: "上次成功解析",
                value: parsedAtText,
                caption: "跨重启保留"
            )
            statItem(
                label: "异常",
                value: issueText,
                caption: diagnostics == nil ? "还没有扫描数据" : "格式异常 / 读取失败",
                valueColor: (diagnostics?.hasIssue == true) ? DS.Status.failure : .primary
            )
            Spacer(minLength: 0)
        }
    }

    private func statItem(
        label: String,
        value: String,
        caption: String? = nil,
        valueColor: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DS.Font.metricSmall)
                .foregroundStyle(valueColor)
                .lineLimit(1)
            if let caption {
                Text(caption)
                    .font(DS.Font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lastScanText: String {
        guard let date = diagnostics?.lastScanAt else { return "尚无记录" }
        return Format.relative(date)
    }

    private var parsedAtText: String {
        guard let date = diagnostics?.lastSuccessfulParseAt else { return "尚无记录" }
        return Format.relative(date)
    }

    private var issueText: String {
        guard let diagnostics else { return "—" }
        let issues = diagnostics.suspectedFormatIssues + diagnostics.readErrorCount
        return issues == 0 ? "无" : "\(issues) 处"
    }

    private var statusText: String {
        guard let diagnostics else { return "还没有可判断的数据" }
        if diagnostics.hasIssue { return "需要检查日志" }
        if diagnostics.newEventCount == 0 { return "最近扫描没有新任务（正常）" }
        return "最近采集正常"
    }

    private var statusColor: Color {
        guard let diagnostics, diagnostics.hasIssue else { return .secondary }
        return DS.Status.failure
    }
}

// MARK: - 任务消耗

/// 任务消耗列表：列对齐的数据表 + 搜索/排序 + 行详情浮层。
///
/// 数据语义：状态（执行结果）与消耗（日志采集结果）是两个维度，
/// 任务中断但已产生消耗时照常显示消耗；采集不到消耗时显示「未采集」，绝不显示 0。
struct TaskHistoryCard: View {
    let tasks: [TraeTask]
    let total: Int
    let todayCredits: Double?
    let hasBalanceBaseline: Bool
    let previewCount: Int
    @Binding var showingAll: Bool
    let onLoadMore: () -> Void

    @State private var query = ""
    @State private var sort: SortMode = .recent
    @State private var selectedTask: TraeTask?

    enum SortMode: String, CaseIterable, Identifiable {
        case recent, credits

        var id: String { rawValue }
        var title: String { self == .recent ? "最近任务" : "消耗最高" }
    }

    // 列宽统一定义：保证表头与各行严格对齐。
    private static let modelWidth: CGFloat = 118
    private static let timeWidth: CGFloat = 72
    private static let statusWidth: CGFloat = 62
    private static let creditsWidth: CGFloat = 84

    var body: some View {
        SectionCard(
            title: "任务消耗",
            subtitle: subtitle,
            accessory: { toolbar }
        ) {
            if tasks.isEmpty {
                emptyState
            } else {
                tableHeader
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(visibleTasks.enumerated()), id: \.element.id) { index, task in
                        taskRow(task)
                        if index < visibleTasks.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
                if visibleTasks.isEmpty {
                    searchEmptyState
                }
                footer
            }
        }
        .popover(item: $selectedTask) { task in
            TaskDetailPopover(task: task)
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: DS.Space.s) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("搜索任务或模型", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Font.caption)
                    .frame(width: 150)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .stroke(DS.Color.cardStroke, lineWidth: 0.8)
            )

            Menu {
                Picker("排序", selection: $sort) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("排序：\(sort.title)")
        }
    }

    // MARK: 表格

    private var tableHeader: some View {
        HStack(spacing: DS.Space.m) {
            Text("任务")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("模型")
                .frame(width: Self.modelWidth, alignment: .leading)
            Text("时间")
                .frame(width: Self.timeWidth, alignment: .trailing)
            Text("状态")
                .frame(width: Self.statusWidth, alignment: .leading)
            Text("积分")
                .frame(width: Self.creditsWidth, alignment: .trailing)
        }
        .font(DS.Font.caption)
        .foregroundStyle(.tertiary)
        .padding(.leading, 2)
    }

    private func taskRow(_ task: TraeTask) -> some View {
        Button {
            selectedTask = task
        } label: {
            HStack(spacing: DS.Space.m) {
                Text(task.titleDisplay)
                    .font(DS.Font.secondary)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(modelText(task))
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: Self.modelWidth, alignment: .leading)
                    .help(task.modelName ?? "日志里没有模型信息")

                Text(Format.relative(task.createdAt))
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Self.timeWidth, alignment: .trailing)
                    .help(Format.dateTime(task.createdAt))

                TagChip(text: task.status.displayName, color: statusColor(task.status))
                    .frame(width: Self.statusWidth, alignment: .leading)

                Text(task.credits == nil ? "未采集" : task.creditsDisplay)
                    .font(DS.Font.metricSmall)
                    .foregroundStyle(task.credits == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .frame(width: Self.creditsWidth, alignment: .trailing)
                    .help(task.credits == nil ? "该任务的日志里没有积分记录，未按 0 计算" : "该轮任务消耗的积分")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看任务详情")
    }

    private var footer: some View {
        HStack(spacing: DS.Space.m) {
            if tasks.count > previewCount {
                Button(showingAll ? "收起" : "显示全部已加载 \(tasks.count) 条") {
                    showingAll.toggle()
                }
                .buttonStyle(.link)
                .font(DS.Font.caption)
            }
            if tasks.count < total {
                Button("加载更早的任务（还有 \(total - tasks.count) 条）", action: onLoadMore)
                    .buttonStyle(.link)
                    .font(DS.Font.caption)
            }
            Spacer()
            Text(hasBalanceBaseline
                 ? "基准之后的任务消耗已从预计余额中扣减"
                 : "还没有余额基准，任务消耗暂未扣减")
                .font(DS.Font.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, DS.Space.xs)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("还没有采集到任务")
                .font(DS.Font.secondary)
            Text("打开该账号的 TRAE 实例并执行任务后，这里会按任务列出每轮消耗的积分。")
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchEmptyState: some View {
        Text("没有匹配的已加载任务；可以清空搜索，或加载更早的记录再试。")
            .font(DS.Font.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, DS.Space.s)
    }

    // MARK: 数据

    /// 搜索只作用于已加载的记录，避免让人误以为搜索能覆盖全部历史。
    private var filteredTasks: [TraeTask] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return tasks }
        return tasks.filter {
            $0.titleDisplay.localizedCaseInsensitiveContains(keyword)
                || ($0.modelName?.localizedCaseInsensitiveContains(keyword) ?? false)
                || ($0.agentName?.localizedCaseInsensitiveContains(keyword) ?? false)
        }
    }

    private var visibleTasks: [TraeTask] {
        let base = filteredTasks
        let sorted: [TraeTask]
        switch sort {
        case .recent:
            sorted = base.sorted { $0.createdAt > $1.createdAt }
        case .credits:
            sorted = base.sorted {
                ($0.credits ?? -1) > ($1.credits ?? -1)
            }
        }
        return showingAll ? sorted : Array(sorted.prefix(previewCount))
    }

    private var subtitle: String {
        guard total > 0 else { return "暂无任务" }
        var parts = ["共 \(total) 个任务"]
        if tasks.count < total { parts.append("已加载 \(tasks.count) 条") }
        if let todayCredits {
            parts.append("今日日志消耗 \(TraeTask.creditsDisplay(todayCredits))")
        }
        return parts.joined(separator: " · ")
    }

    private func modelText(_ task: TraeTask) -> String {
        if let model = task.modelName, !model.isEmpty { return model }
        if let agent = task.agentName, !agent.isEmpty { return agent }
        return "—"
    }

    private func statusColor(_ status: TraeTaskStatus) -> Color {
        switch status {
        case .inProgress: return .accentColor
        case .completed: return DS.Status.running
        case .failed: return DS.Status.failure
        case .interrupted: return DS.Status.needsAttention
        case .unknown: return .secondary
        }
    }
}

// MARK: - 任务详情浮层

/// 单条任务的完整信息；列表只展示摘要，完整字段放在这里。
struct TaskDetailPopover: View {
    let task: TraeTask

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(task.titleDisplay)
                .font(DS.Font.sectionHeader)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                DetailItem(label: "执行状态", value: task.status.displayName)
                DetailItem(label: "模型", value: task.modelName ?? "日志未记录")
                DetailItem(label: "执行代理", value: task.agentName ?? "日志未记录")
                DetailItem(label: "执行时间", value: Format.dateTime(task.createdAt))
                DetailItem(
                    label: "积分消耗",
                    value: task.credits == nil ? "未采集（不按 0 计算）" : task.creditsDisplay,
                    valueColor: task.credits == nil ? .secondary : .primary
                )
            }

            Divider()

            Text("任务与消耗来自 TRAE 本地日志。状态是执行结果，消耗是日志里该轮的 usage 记录，两者相互独立。")
                .font(DS.Font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.l)
        .frame(width: 320, alignment: .leading)
    }
}
