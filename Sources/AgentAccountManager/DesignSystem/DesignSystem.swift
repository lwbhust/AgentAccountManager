import SwiftUI
import Core

/// 全局设计系统（Design System）。
///
/// 规范文档见 docs/ui-audit/DESIGN_SYSTEM.md。
/// 只统一"取值"，不重造控件：颜色走系统语义色，字体走系统字阶，
/// 业务页面禁止直接引用具体字号/间距数值。
enum DS {
    // MARK: - 间距（4pt 网格）

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    // MARK: - 圆角

    enum Radius {
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 14
    }

    // MARK: - 字体层级

    enum Font {
        /// L1 页面主标题
        static let pageTitle = SwiftUI.Font.title2.weight(.semibold)
        /// L2 区块标题
        static let sectionHeader = SwiftUI.Font.headline
        /// L3 正文
        static let body = SwiftUI.Font.body
        /// L4 辅助说明
        static let secondary = SwiftUI.Font.subheadline
        /// L5 标注（时间、脚注）
        static let caption = SwiftUI.Font.caption

        /// 强调数字层级（积分、统计）：rounded + 等宽数字，减少变化抖动。
        static func metric(_ size: CGFloat = 20) -> SwiftUI.Font {
            .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
        }

        /// 小号数字（列表行右侧）
        static let metricSmall = SwiftUI.Font.subheadline.weight(.semibold).monospacedDigit()
    }

    // MARK: - 颜色

    /// 全部基于系统语义色，自动适配深浅模式。
    enum Color {
        static let contentBackground = SwiftUI.Color(nsColor: .windowBackgroundColor)
        static let cardBackground = SwiftUI.Color(nsColor: .controlBackgroundColor)
        static let separator = SwiftUI.Color(nsColor: .separatorColor)

        /// 卡片描边：深浅模式下都保持可见但不刺眼。
        static let cardStroke = SwiftUI.Color(nsColor: .separatorColor).opacity(0.55)
    }

    // MARK: - 业务状态语义

    /// 状态永远 = 颜色 + 文字（必要时加图标），不允许仅用颜色传递语义。
    enum Status {
        /// 正常运行
        static let running = SwiftUI.Color.green
        /// 需要用户处理（待核对、确认冲突）
        static let needsAttention = SwiftUI.Color.orange
        /// 异常 / 失败（查询失败、采集异常、危险操作）
        static let failure = SwiftUI.Color.red
        /// 中性信息（数据较旧、仅供参考）
        static let neutral = SwiftUI.Color.secondary
    }

    // MARK: - 数据新鲜度语义

    /// 数据新鲜度是"常态信息"而非"警告"：
    /// audit P0 修正——超期数据不允许整页橙色渲染，只在数据旁边放一枚中性/浅色小标记。
    enum DataFreshness {
        case fresh      // 12h 内
        case aging      // 超过 12h，可理解的变化
        case unknown    // 无记录

        var tint: SwiftUI.Color {
            switch self {
            case .fresh: return .secondary
            case .aging: return .secondary
            case .unknown: return .secondary
            }
        }

        var icon: String {
            switch self {
            case .fresh: return "checkmark.circle"
            case .aging: return "clock.arrow.circlepath"
            case .unknown: return "questionmark.circle"
            }
        }

        var label: String {
            switch self {
            case .fresh: return "数据较新"
            case .aging: return "数据较早"
            case .unknown: return "暂无数据"
            }
        }

        /// 由"距今秒数 + 阈值"推导新鲜度。
        static func make(secondsSince: TimeInterval?, staleAfter: TimeInterval) -> DS.DataFreshness {
            guard let secondsSince else { return .unknown }
            return secondsSince <= staleAfter ? .fresh : .aging
        }
    }
}

// MARK: - 大号指标数字（积分页专用）

/// 大号数字 + 单位说明 + 右侧来源标签，建立"数字为主角"的展示层级。
struct MetricValue: View {
    let value: String
    var unit: String? = nil
    var footnote: String? = nil
    var sourceBadge: String? = nil
    var tint: SwiftUI.Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(value)
                .font(DS.Font.metric(28))
                .foregroundStyle(tint)
            if let unit {
                Text(unit)
                    .font(DS.Font.secondary)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.m)
            if let sourceBadge {
                TagChip(text: sourceBadge, color: .secondary)
            }
        }
        if let footnote {
            Text(footnote)
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 数据新鲜度标记

/// 数据新鲜度小标记：图标 + 文案，中性色，附带完整说明（hover 可见）。
struct DataFreshnessBadge: View {
    let freshness: DS.DataFreshness
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: freshness.icon)
                .font(.system(size: 10))
            Text(freshness.label)
                .font(DS.Font.caption)
        }
        .foregroundStyle(freshness.tint)
        .help(detail ?? freshness.label)
    }
}

// MARK: - 统一空状态

/// 空态三要素：发生了什么、意味着什么、下一步做什么。
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: DS.Space.s) {
                Text(title)
                    .font(DS.Font.sectionHeader)
                Text(message)
                    .font(DS.Font.secondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
