import WidgetKit
import SwiftUI
import Core

struct QuickSwitchWidgetView: View {
    let entry: SnapshotEntry

    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot? {
        entry.snapshot
    }

    private var appURL: URL {
        URL(string: "agentaccountmanager://open")!
    }

    var body: some View {
        Group {
            if let snapshot, !snapshot.accounts.isEmpty {
                switch family {
                case .systemMedium:
                    mediumContent(snapshot)
                case .systemLarge:
                    largeContent(snapshot)
                default:
                    smallContent(snapshot)
                }
            } else {
                emptyContent
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.16),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .widgetURL(appURL)
    }

    // MARK: - 小尺寸

    private func smallContent(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            header(snapshot)
            VStack(spacing: 4) {
                ForEach(Array(snapshot.accounts.prefix(3))) { account in
                    accountRow(account, compact: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 中尺寸

    private func mediumContent(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(snapshot)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                spacing: 4
            ) {
                ForEach(Array(snapshot.accounts.prefix(6))) { account in
                    accountRow(account, compact: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 大尺寸

    private func largeContent(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(snapshot)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                spacing: 4
            ) {
                ForEach(Array(snapshot.accounts.prefix(6))) { account in
                    accountRow(account, compact: false)
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("最近项目")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(snapshot.projects.count)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 1)

            if snapshot.projects.isEmpty {
                Text("在 TRAE 或工作台中打开项目后，会出现在这里。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(snapshot.projects.prefix(5))) { project in
                        projectRow(project)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 公共组件

    private func header(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)

            Text("快速切换")
                .font(.system(size: 12.5, weight: .semibold))

            Spacer(minLength: 2)

            if snapshot.isStale() {
                // 主应用长时间未运行时数据可能失真，只做提示，不影响深链打开。
                HStack(spacing: 3) {
                    Image(systemName: "clock.exclamationmark")
                        .font(.system(size: 8))
                    Text("数据已过期")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.secondary)
            } else if snapshot.runningCount > 0 {
                HStack(spacing: 3) {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                    Text("\(snapshot.runningCount) 运行中")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func accountRow(_ account: WidgetAccountSnapshot, compact: Bool) -> some View {
        Link(destination: WidgetDeepLink.account(account.id).url) {
            HStack(spacing: 5) {
                Text(account.platform == .trae ? "T" : "W")
                    .font(.system(size: compact ? 8.5 : 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(platformColor(account.platform))
                    .frame(width: compact ? 19 : 22, height: compact ? 19 : 22)
                    .background(
                        platformColor(account.platform).opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 5)
                    )

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        Text(account.name)
                            .font(.system(size: compact ? 10.5 : 11.5, weight: .medium))
                            .lineLimit(1)
                        if account.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 6.5))
                                .foregroundStyle(.yellow)
                        }
                    }
                    if !account.subtitle.isEmpty {
                        Text(account.subtitle)
                            .font(.system(size: compact ? 8.5 : 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 2)

                if account.isRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, compact ? 4 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.primary)
            .background(
                Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
    }

    private func projectRow(_ project: WidgetProjectSnapshot) -> some View {
        Link(destination: WidgetDeepLink.project(accountId: project.accountId, path: project.path).url) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 5)
                    )

                VStack(alignment: .leading, spacing: 0) {
                    Text(project.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 3) {
                        Text(project.accountName)
                            .lineLimit(1)
                        Text("·")
                        Text(project.lastVisitedAt, style: .relative)
                    }
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 2)

                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.primary)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
    }

    private var emptyContent: some View {
        VStack(spacing: 7) {
            Spacer()
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("打开 App 同步账号")
                .font(.system(size: 12, weight: .semibold))
            Text("启动 Agent 账号管理器后，这里会显示账号与最近项目。")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 6)
    }

    private func platformColor(_ platform: Platform) -> Color {
        platform == .workbuddy ? .blue : .purple
    }
}
