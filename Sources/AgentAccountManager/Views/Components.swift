import SwiftUI
import Core

// MARK: - 格式化

enum Format {
    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// 相对时间：明确区分过去与未来，避免出现「0 秒后」这类误导文案。
    ///
    /// 采集时间可能因时钟抖动比当前时间略早（几毫秒到几秒），这段时间一律当作「刚刚」；
    /// 真正的未来时间（例如用户填写的观测时间）不伪装成过去，直接给出绝对时间。
    static func relative(_ date: Date) -> String {
        let delta = Date().timeIntervalSince(date)
        if delta < 0 {
            return delta >= -60 ? "刚刚" : dateTime(date)
        }
        if delta < 60 { return "刚刚" }
        if delta < 3600 { return "\(Int(delta / 60)) 分钟前" }
        if delta < 86_400 { return "\(Int(delta / 3600)) 小时前" }
        if delta < 86_400 * 7 { return "\(Int(delta / 86_400)) 天前" }
        return dateTime(date)
    }

    /// 绝对时间（不含年份，用于同一年内的细节展示）。
    static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    /// 积分数值展示：未知时显示「未知」，不伪装成 0。
    static func credits(_ value: Int?) -> String {
        guard let value else { return "未知" }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    /// 预计余额可能带小数（任务消耗来自日志里的 usage），最多保留两位。
    static func credits(_ value: Double?) -> String {
        guard let value else { return "未知" }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

// MARK: - 轻量状态指示器（列表行专用）

/// 列表行内的轻量状态指示：一个彩色小圆点 + 文字。
/// 相比 TagChip 的胶囊背景更原生、更低视觉权重，适用于侧边栏高密度扫描。
struct StatusDot: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 通用标签（详情页 / 工具栏）

/// 小号状态标签，带胶囊背景，用于详情页头部和卡片内的状态提示。
struct TagChip: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }
}

extension LoginStatus {
    var tint: Color {
        switch self {
        case .pendingConfirmation: return .orange
        case .userConfirmed: return .green
        case .verified: return .green
        case .loggedOut, .unknown: return .secondary
        }
    }

    var icon: String? {
        switch self {
        case .pendingConfirmation: return "clock"
        case .userConfirmed: return "checkmark.circle"
        case .verified: return "checkmark.seal.fill"
        case .loggedOut: return "person.crop.circle.badge.xmark"
        case .unknown: return nil
        }
    }

    /// 列表中的精简文案（未记录状态不占用视觉空间）。
    var listLabel: String? {
        switch self {
        case .unknown: return nil
        case .pendingConfirmation: return "待核对"
        case .userConfirmed: return "已确认"
        case .verified: return "已验证"
        case .loggedOut: return "已退出"
        }
    }

    /// 悬停说明，避免用户把"之前确认过"当成"现在已登录"。
    var explanation: String {
        switch self {
        case .unknown:
            return "还没有记录过登录状态"
        case .loggedOut:
            return "上次记录为已退出登录"
        case .pendingConfirmation:
            return "已发起切换，但还没有在官方界面核对结果"
        case .userConfirmed:
            return "这是你此前在官方界面核对后的确认结果；切换后仍需重新核对"
        case .verified:
            return "通过官方 CLI 验证到的身份，仅代表最近一次验证当时的状态"
        }
    }
}

extension DataStatus {
    var tint: Color {
        switch self {
        case .stale: return .orange
        case .queryFailed: return .red
        case .latest: return .green
        case .manual: return .secondary
        }
    }
}

// MARK: - 卡片容器

/// 详情页的信息区块，统一视觉结构。
///
/// `accessory` 用于把卡片级的操作（立即采集、搜索等）放到标题行右侧，
/// 避免为了一个按钮多占一整行纵向空间。
struct SectionCard<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    var subtitleColor: Color = .secondary
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    /// 信息卡片的玻璃底色：低透明度自定义填充，让窗口背景图的颜色与光影
    /// 自然透出；再厚就会变成一块灰白板。
    private var glassFill: Color {
        colorScheme == .light
            ? Color.white.opacity(0.18)
            : Color.white.opacity(0.05)
    }

    init(
        title: String,
        subtitle: String? = nil,
        subtitleColor: Color = .secondary,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleColor = subtitleColor
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .center, spacing: DS.Space.s) {
                Text(title)
                    .font(DS.Font.sectionHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.caption)
                        .foregroundStyle(subtitleColor)
                }
                Spacer(minLength: DS.Space.m)
                accessory
            }
            content
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m)
                .fill(glassFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.m)
                .stroke(DS.Color.cardStroke, lineWidth: 1)
        )
    }
}

extension SectionCard where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        subtitleColor: Color = .secondary,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            subtitleColor: subtitleColor,
            accessory: { EmptyView() },
            content: content
        )
    }
}

/// 通透的分段选择器：替代不透明的 NSSegmentedControl，
/// 未选中的段完全透明，选中的段用磨砂胶囊标出。
struct TranslucentSegment<T: Hashable>: View {
    let items: [TranslucentSegmentItem<T>]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let isSelected = item.value == selection
                Button {
                    guard !isSelected else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        selection = item.value
                    }
                } label: {
                    Text(item.label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(isSelected ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(DS.Color.cardStroke, lineWidth: 1))
    }
}

struct TranslucentSegmentItem<T: Hashable> {
    let value: T
    let label: String
}

/// 通透的胶囊按钮外观：磨砂底 + 细描边，悬停时加深，用于替代不透明的系统按钮边框。
struct TranslucentCapsuleButtonStyle: ButtonStyle {
    var isProminent: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isProminent ? .medium : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    isProminent ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial)
                )
            )
            .overlay(Capsule().stroke(DS.Color.cardStroke, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1.0) : 0.4)
    }
}

/// 侧边栏列表行的背景：普通行完全透明，悬停时轻微提亮，
/// 选中时用低透明度的强调色高亮，替代系统不透明的选中底色。
struct SelectableRowBackground: View {
    let isSelected: Bool
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(rowFill)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var rowFill: Color {
        if isSelected {
            return colorScheme == .light
                ? Color.accentColor.opacity(0.20)
                : Color.accentColor.opacity(0.30)
        }
        return Color.primary.opacity(isHovering ? 0.06 : 0)
    }
}

/// 键值行。
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

// MARK: - 指标小卡 / 明细栅格

/// 辅助指标：数值 + 一行说明。用于横向并排的二三项关键数据。
struct MetricTile: View {
    let label: String
    let value: String
    var caption: String? = nil
    var valueColor: Color = .primary
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DS.Font.metric(15))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let caption {
                Text(caption)
                    .font(DS.Font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s)
                .fill(Color.primary.opacity(0.035))
        )
        .help(footnote ?? "\(label)：\(value)")
    }
}

/// 紧凑明细项：标签在左、数值在右，字号比正文低一级。
struct DetailItem: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.s)
            Text(value)
                .font(DS.Font.caption)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// 明细栅格：宽窗口两列、窄窗口自动退化为单列。
struct DetailGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: DS.Space.xl),
                          GridItem(.flexible(), spacing: DS.Space.xl)],
                alignment: .leading,
                spacing: DS.Space.s
            ) {
                content
            }
            LazyVGrid(
                columns: [GridItem(.flexible())],
                alignment: .leading,
                spacing: DS.Space.s
            ) {
                content
            }
        }
    }
}

// MARK: - 提示条

struct InlineBanner: View {
    enum Kind {
        case info, success, warning, error
    }

    let kind: Kind
    let text: String

    private var color: Color {
        switch kind {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var icon: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 趋势线

/// 轻量积分趋势线（仅在有足够历史时展示）。
struct CreditSparkline: View {
    /// 按时间正序排列的积分数值
    let points: [Int]

    var body: some View {
        GeometryReader { geo in
            let maxValue = points.max() ?? 1
            let minValue = points.min() ?? 0
            let span = max(maxValue - minValue, 1)
            let stepX = points.count > 1 ? geo.size.width / CGFloat(points.count - 1) : 0
            Path { path in
                for (index, value) in points.enumerated() {
                    let x = CGFloat(index) * stepX
                    let ratio = CGFloat(value - minValue) / CGFloat(span)
                    let y = geo.size.height - 3 - ratio * (geo.size.height - 6)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}
