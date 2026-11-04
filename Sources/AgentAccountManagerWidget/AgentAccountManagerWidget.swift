import WidgetKit
import SwiftUI
import Core

@main
struct AgentAccountManagerWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickSwitchWidget()
    }
}

struct QuickSwitchWidget: Widget {
    static let kind = "QuickSwitchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            QuickSwitchWidgetView(entry: entry)
        }
        .configurationDisplayName("快速切换")
        .description("从桌面直接打开账号或最近项目。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.load())
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

extension WidgetSnapshot {
    /// 小组件画廊和首次加载时使用的占位数据。
    static let placeholder = WidgetSnapshot(
        runningCount: 2,
        accounts: [
            WidgetAccountSnapshot(
                id: UUID(),
                name: "TRAE 主账号",
                platform: .trae,
                isRunning: true,
                isFavorite: true,
                subtitle: "Pro · 运行中"
            ),
            WidgetAccountSnapshot(
                id: UUID(),
                name: "TRAE 备用",
                platform: .trae,
                isRunning: true,
                isFavorite: false,
                subtitle: "运行中"
            ),
            WidgetAccountSnapshot(
                id: UUID(),
                name: "WorkBuddy",
                platform: .workbuddy,
                isRunning: false,
                isFavorite: false,
                subtitle: "客户端未打开"
            )
        ],
        projects: [
            WidgetProjectSnapshot(
                accountId: UUID(),
                accountName: "TRAE 主账号",
                name: "AgentAccountManager",
                path: "/Users/placeholder/AgentAccountManager",
                lastVisitedAt: Date().addingTimeInterval(-1800)
            ),
            WidgetProjectSnapshot(
                accountId: UUID(),
                accountName: "TRAE 备用",
                name: "抖音运营管理",
                path: "/Users/placeholder/抖音运营管理",
                lastVisitedAt: Date().addingTimeInterval(-7200)
            )
        ]
    )
}
