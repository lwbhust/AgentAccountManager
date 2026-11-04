import SwiftUI
import Core

/// 账号详情页「历史记录」分区：积分变化与切换留痕。
///
/// 纯展示层：数据由容器（AccountDetailView）分页加载后传入，
/// 这里不做任何 IO。
struct AccountHistorySection: View {
    let creditHistory: [CreditSnapshot]
    let creditTotal: Int
    let creditPreviewCount: Int
    @Binding var showingAllCreditHistory: Bool
    let onLoadMoreCredits: () -> Void
    let switchHistory: [SwitchLog]
    let switchTotal: Int
    let switchPreviewCount: Int
    @Binding var showingAllSwitches: Bool
    let onSwitch: () -> Void
    let onLoadMoreSwitches: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CreditHistoryCard(
                history: creditHistory,
                total: creditTotal,
                previewCount: creditPreviewCount,
                showingAll: $showingAllCreditHistory,
                onLoadMore: onLoadMoreCredits
            )
            SwitchHistoryCard(
                history: switchHistory,
                total: switchTotal,
                previewCount: switchPreviewCount,
                showingAll: $showingAllSwitches,
                onSwitch: onSwitch,
                onLoadMore: onLoadMoreSwitches
            )
        }
    }
}

// MARK: - 积分变化

/// 积分变化历史与趋势，放在独立分区避免挤占最常用的余额与操作区域。
struct CreditHistoryCard: View {
    let history: [CreditSnapshot]
    let total: Int
    let previewCount: Int
    @Binding var showingAll: Bool
    let onLoadMore: () -> Void

    var body: some View {
        SectionCard(title: "积分变化", subtitle: total > 0 ? "共 \(total) 条" : "暂无记录") {
            if history.isEmpty {
                Text("还没有积分记录。在「积分与任务」里录入当前余额后，这里会记录每次观测值与变化趋势。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // 少于 4 个点不画趋势线：点太少时连线会呈现误导性"趋势"。
                if trendPoints.count >= 4 {
                    VStack(alignment: .leading, spacing: 4) {
                        CreditSparkline(points: trendPoints)
                            .frame(height: 42)
                        HStack {
                            Text("较早")
                            Spacer()
                            Text("最近 · 最高 \(Format.credits(trendPoints.max())) · 最低 \(Format.credits(trendPoints.min())) · 仅供回溯")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)
                }

                let visible = showingAll ? history : Array(history.prefix(previewCount))
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { offset, snapshot in
                        row(snapshot, index: offset)
                            .padding(.vertical, 5)
                    }
                }
                footerButtons
                Text("这里只记录你手动录入的实际余额，以及每次录入之间的差值；不是官方账户的实时余额。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        if history.count > previewCount {
            Button(showingAll ? "收起历史" : "显示全部 \(history.count) 条") {
                showingAll.toggle()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        if history.count < total {
            Button("加载更早的记录（还有 \(total - history.count) 条）", action: onLoadMore)
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private func row(_ snapshot: CreditSnapshot, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.dateTime(snapshot.queryAt))
                    .font(.caption)
                // 目前只有手动录入；出现其它来源时才额外标注，避免重复「手动录入」
                if snapshot.source != .manualEntry {
                    Text(snapshot.source.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if snapshot.status == .failed {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("查询失败")
                        .font(.caption)
                        .foregroundStyle(.red)
                    if let reason = snapshot.errorMessage {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.credits(snapshot.credits))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if let delta = deltaText(at: index) {
                        Text(delta.text)
                            .font(.caption2)
                            .foregroundStyle(delta.color)
                    }
                }
            }
            if index == 0 {
                TagChip(text: "最新", color: .accentColor)
            }
        }
    }

    /// 与更早一条成功记录的变化量。
    private func deltaText(at index: Int) -> (text: String, color: Color)? {
        guard let current = history[index].credits else { return nil }
        guard index + 1 < history.count,
              let previous = history[index + 1].credits else { return nil }
        let delta = current - previous
        if delta == 0 { return ("与上次持平", .secondary) }
        // 消耗增减是常态事实，用中性色；只有负余额场景才用警示色（余额卡内已处理）。
        let sign = delta > 0 ? "+" : "−"
        return ("较上次 \(sign)\(abs(delta))", .secondary)
    }

    /// 趋势线使用按时间正序的成功记录。
    private var trendPoints: [Int] {
        history
            .compactMap { $0.status == .failed ? nil : $0.credits }
            .reversed()
            .suffix(12)
            .map { $0 }
    }
}

// MARK: - 切换历史

struct SwitchHistoryCard: View {
    let history: [SwitchLog]
    let total: Int
    let previewCount: Int
    @Binding var showingAll: Bool
    let onSwitch: () -> Void
    let onLoadMore: () -> Void

    var body: some View {
        SectionCard(title: "切换记录", subtitle: history.isEmpty ? "暂无记录" : "共 \(total) 条") {
            if history.isEmpty {
                HistoryEmptyHint(
                    text: "还没有切换记录。每次切换都会在这里留痕，便于回溯。",
                    actionTitle: "启动并核对登录",
                    action: onSwitch
                )
            } else {
                let visible = showingAll ? history : Array(history.prefix(previewCount))
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, log in
                        row(log)
                            .padding(.vertical, 5)
                            if index < visible.count - 1 {
                                Divider().opacity(0.4)
                            }
                    }
                }
                footerButtons
            }
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        if history.count > previewCount {
            Button(showingAll ? "收起记录" : "显示全部 \(history.count) 条") {
                showingAll.toggle()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        if history.count < total {
            Button("加载更早的记录（还有 \(total - history.count) 条）", action: onLoadMore)
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private func row(_ log: SwitchLog) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.dateTime(log.createdAt))
                    .font(.caption)
                Text("\(LoginStatus(storedValue: log.fromStatus).displayName) → \(LoginStatus(storedValue: log.toStatus).displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                TagChip(text: log.result.displayName, color: resultColor(log.result))
                if let error = log.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func resultColor(_ result: SwitchResult) -> Color {
        switch result {
        case .success: return DS.Status.running
        // "待核对"是切换后的常态中间态，避免每行橙色造成视觉噪音。
        case .unconfirmed: return .secondary
        case .failed: return DS.Status.failure
        }
    }
}

// MARK: - 空状态

struct HistoryEmptyHint: View {
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
